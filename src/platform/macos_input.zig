//! macOS global input listener (Functional Spec §6, §7.1).
//!
//! Runs a listen-only `CGEventTap` on its own background thread with its
//! own `CFRunLoop`, observing key-down and mouse-button-down events
//! system-wide. The callback does nothing but increment an atomic counter
//! and return the event unmodified — `kCGEventTapOptionListenOnly` makes
//! that the OS's guarantee, not just ours, so this can never suppress,
//! modify, or delay a keystroke or click.
//!
//! Nothing here ever inspects *which* key or button fired: the callback
//! only ever branches on the coarse `CGEventType` to pick which counter to
//! bump, matching the spec's core privacy constraint.
//!
//! Bound by hand instead of via `@cImport`: this SDK's CoreGraphics /
//! ApplicationServices headers use Block syntax and nullability
//! annotations translate-c can't parse. The handful of symbols below are
//! long-stable Apple C ABI (unchanged in a decade-plus) and resolve at
//! link time against the frameworks `build.zig` already links.

const std = @import("std");

const CFAllocatorRef = ?*anyopaque;
const CFRunLoopRef = ?*anyopaque;
const CFRunLoopSourceRef = ?*anyopaque;
const CFMachPortRef = ?*anyopaque;
const CFStringRef = ?*anyopaque;
const CFIndex = i64;
const CGEventRef = ?*anyopaque;
const CGEventTapProxy = ?*anyopaque;
const CGEventType = u32;
const CGEventMask = u64;
const CGEventTapLocation = u32;
const CGEventTapPlacement = u32;
const CGEventTapOptions = u32;
const IOHIDRequestType = c_int;
const IOHIDAccessType = c_int;

const kCGSessionEventTap: CGEventTapLocation = 1;
const kCGHeadInsertEventTap: CGEventTapPlacement = 0;
const kCGEventTapOptionListenOnly: CGEventTapOptions = 1;

const kCGEventLeftMouseDown: CGEventType = 1;
const kCGEventRightMouseDown: CGEventType = 3;
const kCGEventKeyDown: CGEventType = 10;
const kCGEventOtherMouseDown: CGEventType = 25;
const kCGEventTapDisabledByTimeout: CGEventType = 0xFFFFFFFE;
const kCGEventTapDisabledByUserInput: CGEventType = 0xFFFFFFFF;

const kIOHIDRequestTypeListenEvent: IOHIDRequestType = 0;
const kIOHIDAccessTypeGranted: IOHIDAccessType = 0;

const CGEventTapCallBack = *const fn (CGEventTapProxy, CGEventType, CGEventRef, ?*anyopaque) callconv(.c) CGEventRef;

extern "c" fn CGEventTapCreate(tap: CGEventTapLocation, place: CGEventTapPlacement, options: CGEventTapOptions, events_of_interest: CGEventMask, callback: CGEventTapCallBack, user_info: ?*anyopaque) CFMachPortRef;
extern "c" fn CGEventTapEnable(tap: CFMachPortRef, enable: bool) void;
extern "c" fn CFMachPortCreateRunLoopSource(allocator: CFAllocatorRef, port: CFMachPortRef, order: CFIndex) CFRunLoopSourceRef;
extern "c" fn CFRunLoopGetCurrent() CFRunLoopRef;
extern "c" fn CFRunLoopAddSource(rl: CFRunLoopRef, source: CFRunLoopSourceRef, mode: CFStringRef) void;
extern "c" fn CFRunLoopRun() void;
extern "c" fn CFRelease(cf: ?*anyopaque) void;
// These two are themselves pointer-valued globals (`CFStringRef` /
// `CFAllocatorRef`) — the symbol IS the pointer, so callers pass it
// directly, never `&kCFAllocatorDefault`.
extern var kCFRunLoopCommonModes: CFStringRef;
extern var kCFAllocatorDefault: CFAllocatorRef;

extern "c" fn AXIsProcessTrusted() bool;
extern "c" fn IOHIDCheckAccess(request_type: IOHIDRequestType) IOHIDAccessType;
extern "c" fn IOHIDRequestAccess(request_type: IOHIDRequestType) bool;
extern "c" fn sleep(seconds: c_uint) c_uint;

pub const PermissionState = enum(u8) { unknown, granted, needed };

var keystrokes = std.atomic.Value(u64).init(0);
var clicks = std.atomic.Value(u64).init(0);
var paused = std.atomic.Value(bool).init(false);
var permission_state = std.atomic.Value(u8).init(@intFromEnum(PermissionState.unknown));

pub const DrainedCounts = struct { keystrokes: u64, clicks: u64 };

/// Atomically reads and resets both counters — called once per 60s tick
/// (§5) from the main loop, never from the tap thread.
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

/// Spawns the dedicated listener thread (§6: "never the UI thread").
/// Fire-and-forget: failures degrade to a `.needed` permission state
/// instead of crashing the app (§6, §7.1).
pub fn start() void {
    const thread = std.Thread.spawn(.{}, run, .{}) catch {
        permission_state.store(@intFromEnum(PermissionState.needed), .monotonic);
        return;
    };
    thread.detach();
}

fn run() void {
    // Triggers the one-time Input Monitoring consent prompt on first run;
    // a no-op if already decided. Independent of Accessibility (§7.1).
    _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);

    const event_mask: CGEventMask =
        (@as(CGEventMask, 1) << kCGEventKeyDown) |
        (@as(CGEventMask, 1) << kCGEventLeftMouseDown) |
        (@as(CGEventMask, 1) << kCGEventRightMouseDown) |
        (@as(CGEventMask, 1) << kCGEventOtherMouseDown);

    // Neither permission is granted instantaneously and both can be
    // granted while the app keeps running, so retry instead of giving up
    // once (§6: "the tray shows a clear 'permission needed' state rather
    // than crashing or silently under-counting forever").
    while (true) {
        const tap = CGEventTapCreate(
            kCGSessionEventTap,
            kCGHeadInsertEventTap,
            kCGEventTapOptionListenOnly,
            event_mask,
            eventCallback,
            null,
        );
        if (tap == null) {
            permission_state.store(@intFromEnum(PermissionState.needed), .monotonic);
            // A plain libc sleep, not `std.Io.sleep`: this OS thread runs
            // its own `CFRunLoop` outside the app's cooperative Io
            // executor, so it should not depend on that executor's
            // scheduling to wake back up.
            _ = sleep(5);
            continue;
        }

        permission_state.store(@intFromEnum(PermissionState.granted), .monotonic);
        const run_loop_source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
        defer CFRelease(run_loop_source);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), run_loop_source, kCFRunLoopCommonModes);
        CGEventTapEnable(tap, true);

        // Blocks this thread forever (the SDK's UI runtime owns the main
        // thread's run loop separately). Returns only if the OS disables
        // the tap outright; loop back and re-create it.
        CFRunLoopRun();
        permission_state.store(@intFromEnum(PermissionState.needed), .monotonic);
    }
}

fn eventCallback(
    proxy: CGEventTapProxy,
    event_type: CGEventType,
    event: CGEventRef,
    user_info: ?*anyopaque,
) callconv(.c) CGEventRef {
    _ = proxy;
    _ = user_info;

    // The system disabling the tap (timeout, or user swapping the
    // frontmost app's trust) shows up here as one of these two types;
    // the outer retry loop re-creates the tap rather than under-counting
    // forever (§6).
    if (event_type == kCGEventTapDisabledByTimeout or event_type == kCGEventTapDisabledByUserInput) {
        return event;
    }

    if (!paused.load(.monotonic)) {
        switch (event_type) {
            kCGEventKeyDown => _ = keystrokes.fetchAdd(1, .monotonic),
            kCGEventLeftMouseDown, kCGEventRightMouseDown, kCGEventOtherMouseDown => _ = clicks.fetchAdd(1, .monotonic),
            else => {},
        }
    }
    return event;
}

/// Checks both permissions the spec requires (§7.1: Accessibility alone is
/// not sufficient on modern macOS). Read-only — never prompts.
fn hasAccessibility() bool {
    return AXIsProcessTrusted();
}

fn hasInputMonitoring() bool {
    return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted;
}

fn openSettingsPane(io: std.Io, url: []const u8) void {
    var child = std.process.spawn(io, .{
        .argv = &.{ "/usr/bin/open", url },
    }) catch return;
    _ = child.wait(io) catch {};
}

/// §7.1: two independently-granted permissions, so two tray actions —
/// this is the one backend with more than one.
pub const max_permission_actions = 2;

pub fn permissionActionLabels(buf: *[max_permission_actions][]const u8) []const []const u8 {
    var count: usize = 0;
    if (!hasAccessibility()) {
        buf[count] = "Grant Accessibility Access…";
        count += 1;
    }
    if (!hasInputMonitoring()) {
        buf[count] = "Grant Input Monitoring Access…";
        count += 1;
    }
    return buf[0..count];
}

pub fn performPermissionAction(io: std.Io, index: usize) void {
    // Mirrors `permissionActionLabels`: whichever permission is still
    // missing occupies index 0, so the two orderings above always match
    // (both missing: 0=Accessibility, 1=Input Monitoring; only one
    // missing: it is always index 0).
    var seen: usize = 0;
    if (!hasAccessibility()) {
        if (seen == index) return openSettingsPane(io, "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility");
        seen += 1;
    }
    if (!hasInputMonitoring()) {
        if (seen == index) return openSettingsPane(io, "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent");
        seen += 1;
    }
}
