//! Linux global input listener (Functional Spec §6, §7.3).
//!
//! Picks a backend at startup, per spec:
//! - X11 with the `RECORD` extension present: `XRecordEnableContext`,
//!   listen-only, needs no special group membership.
//! - X11 without `RECORD`, or Wayland: read `/dev/input/event*` (evdev)
//!   directly — needs the user in the `input` group.
//!
//! NOTE: written against the documented X11/evdev ABIs but not compiled
//! or run on Linux — this dev machine is macOS-only. The evdev path uses
//! only long-stable Linux uAPI structs (no header dependency beyond
//! `std.os.linux`); the X11/RECORD path goes through `@cImport` against
//! the real system headers (`libx11-dev`/`libxtst-dev` or distro
//! equivalent) rather than hand-rolled struct layouts, specifically
//! because a wrong guess there would be silent memory corruption instead
//! of a build error. Treat both as unverified until built and exercised
//! on a real Linux host.
const std = @import("std");
const io_context = @import("../io_context.zig");

pub const PermissionState = enum(u8) { unknown, granted, needed };

var keystrokes = std.atomic.Value(u64).init(0);
var clicks = std.atomic.Value(u64).init(0);
var paused = std.atomic.Value(bool).init(false);
var permission_state = std.atomic.Value(u8).init(@intFromEnum(PermissionState.unknown));

pub const DrainedCounts = struct { keystrokes: u64, clicks: u64 };

pub fn drainCounts() DrainedCounts {
    return .{
        .keystrokes = keystrokes.swap(0, .monotonic),
        .clicks = clicks.swap(0, .monotonic),
    };
}

pub fn setPaused(p: bool) void {
    paused.store(p, .monotonic);
}

pub fn permissionState() PermissionState {
    return @enumFromInt(permission_state.load(.monotonic));
}

pub fn start() void {
    const thread = std.Thread.spawn(.{}, run, .{}) catch {
        permission_state.store(@intFromEnum(PermissionState.needed), .monotonic);
        return;
    };
    thread.detach();
}

fn run() void {
    const is_x11 = if (io_context.env.get("XDG_SESSION_TYPE")) |session_type|
        std.mem.eql(u8, session_type, "x11")
    else
        false;

    // §6: "detect and pick this path automatically — no separate build or
    // manual config" — try XRecord first on X11, evdev for everything
    // else (Wayland, or X11 whose server lacks the RECORD extension).
    if (is_x11 and tryXRecord()) return; // never returns on success — blocks forever
    runEvdev();
}

// ------------------------------------------------------------ X11/RECORD

const x11 = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/extensions/record.h");
});

/// Sets up the RECORD context on a control connection and hands off to a
/// dedicated data connection that blocks in `XRecordEnableContext`
/// forever (§6: "own background thread"). Returns `false` — without
/// blocking — if the extension or context isn't available, so the caller
/// falls back to evdev; returns `true` only once truly running (in which
/// case this function does not return at all until the process exits).
fn tryXRecord() bool {
    const control_display = x11.XOpenDisplay(null) orelse return false;
    defer _ = x11.XCloseDisplay(control_display);

    var major_opcode: c_int = 0;
    var first_event: c_int = 0;
    var first_error: c_int = 0;
    if (x11.XQueryExtension(control_display, "RECORD", &major_opcode, &first_event, &first_error) == 0) {
        return false;
    }

    // XRecordRange's `device_events` is an `XRecordRange8 { first, last }`
    // pair, not two flat fields — confirmed against the real libXtst
    // header (gitlab.freedesktop.org/xorg/lib/libxtst), since guessing
    // this wrong from memory is silent corruption, not a build error.
    const range = x11.XRecordAllocRange() orelse return false;
    defer x11.XFree(range);
    range.*.device_events.first = x11.KeyPress;
    range.*.device_events.last = x11.ButtonRelease;

    var client_spec: x11.XRecordClientSpec = x11.XRecordAllClients;
    var range_list = [_]x11.XRecordRange{range.*};
    var range_ptrs = [_][*c]x11.XRecordRange{&range_list[0]};
    const context = x11.XRecordCreateContext(control_display, 0, &client_spec, 1, &range_ptrs, 1);
    if (context == 0) return false;

    permission_state.store(@intFromEnum(PermissionState.granted), .monotonic);

    const data_display = x11.XOpenDisplay(null) orelse return false;
    // `XRecordEnableContext` blocks this thread forever, invoking
    // `recordCallback` once per intercepted event on the SAME thread —
    // exactly the dedicated-background-thread shape §6 asks for.
    _ = x11.XRecordEnableContext(data_display, context, recordCallback, null);
    return true;
}

fn recordCallback(closure: x11.XPointer, data: [*c]x11.XRecordInterceptData) callconv(.c) void {
    _ = closure;
    defer x11.XRecordFreeData(data);
    if (data.*.category != x11.XRecordFromServer) return;
    if (data.*.data == null) return;

    // The core X event type lives in the low 7 bits of the first byte of
    // the raw wire event (the high bit is the server's "generated by
    // SendEvent" marker) — that single byte is ALL this reads; nothing
    // about which key/button, position, or window is ever touched (the
    // spec's core privacy constraint).
    const event_type = data.*.data[0] & 0x7f;
    if (paused.load(.monotonic)) return;
    switch (event_type) {
        x11.KeyPress => _ = keystrokes.fetchAdd(1, .monotonic),
        x11.ButtonPress => _ = clicks.fetchAdd(1, .monotonic),
        else => {},
    }
}

// ------------------------------------------------------------------ evdev

const EV_KEY: u16 = 0x01;
const BTN_LEFT: u16 = 0x110;
const BTN_RIGHT: u16 = 0x111;
const BTN_MIDDLE: u16 = 0x112;
const KEY_MAX_RANGE: u16 = 0x100; // codes below this are keyboard scancodes

const InputEvent = extern struct {
    tv_sec: i64,
    tv_usec: i64,
    type: u16,
    code: u16,
    value: i32,
};

const max_devices = 32;

fn runEvdev() void {
    var fds: [max_devices]std.posix.pollfd = undefined;
    var fd_count: usize = 0;

    var path_buf: [32]u8 = undefined;
    var index: usize = 0;
    while (index < max_devices) : (index += 1) {
        const path = std.fmt.bufPrintZ(&path_buf, "/dev/input/event{d}", .{index}) catch continue;
        const fd = std.posix.openatZ(std.posix.AT.FDCWD, path, .{}, 0) catch continue;
        fds[fd_count] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
        fd_count += 1;
    }

    if (fd_count == 0) {
        // Distinguish "no devices at all" (unusual, but not a permission
        // problem) from "devices exist but every open failed" (the real
        // `input` group case, §7.3) isn't possible from here without
        // re-stat'ing — either way there is nothing to read, so surface
        // the same actionable state.
        permission_state.store(@intFromEnum(PermissionState.needed), .monotonic);
        return;
    }
    permission_state.store(@intFromEnum(PermissionState.granted), .monotonic);

    var event: InputEvent = undefined;
    const event_bytes = std.mem.asBytes(&event);
    while (true) {
        const ready = std.posix.poll(fds[0..fd_count], -1) catch continue;
        if (ready == 0) continue;
        for (fds[0..fd_count]) |pfd| {
            if (pfd.revents & std.posix.POLL.IN == 0) continue;
            const n = std.posix.read(pfd.fd, event_bytes) catch continue;
            if (n != event_bytes.len) continue;
            if (event.type != EV_KEY or event.value != 1) continue; // down-only, ignore up/repeat

            if (paused.load(.monotonic)) continue;
            switch (event.code) {
                BTN_LEFT, BTN_RIGHT, BTN_MIDDLE => _ = clicks.fetchAdd(1, .monotonic),
                else => if (event.code < KEY_MAX_RANGE) {
                    _ = keystrokes.fetchAdd(1, .monotonic);
                },
            }
        }
    }
}

/// One instruction, not a button that runs `sudo` on the user's behalf
/// (§7.3): granting `input`-group membership needs a re-login to take
/// effect, and running privileged commands from a background tray app
/// unprompted would be its own security problem.
pub const max_permission_actions = 1;

pub fn permissionActionLabels(buf: *[max_permission_actions][]const u8) []const []const u8 {
    buf[0] = "Run: sudo usermod -aG input $USER (then log out and back in)";
    return buf[0..1];
}

pub fn performPermissionAction(io: std.Io, index: usize) void {
    _ = io;
    _ = index;
}
