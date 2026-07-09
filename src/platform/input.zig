//! Cross-platform facade over the per-OS global input listener (Functional
//! Spec §6). `main.zig` only ever talks to this file — never to
//! `macos_input.zig` / `windows_input.zig` / `linux_input.zig` directly —
//! so adding a platform means implementing this same surface, not
//! touching the app logic.
//!
//! Every backend promises the same contract:
//! - `start()` spawns its own dedicated background thread (§6) and never
//!   blocks the caller.
//! - The counters it feeds are lock-free atomics, drained once per tick
//!   by `drainCounts()` — never delivered as a message per keystroke.
//! - It never suppresses, modifies, or delays the underlying input.
//! - Missing permission degrades to `.needed`, never a crash.
const std = @import("std");
const builtin = @import("builtin");

const backend = switch (builtin.os.tag) {
    .macos => @import("macos_input.zig"),
    .windows => @import("windows_input.zig"),
    .linux => @import("linux_input.zig"),
    else => @compileError("Inpute has no input-capture backend for this OS"),
};

pub const PermissionState = enum(u8) { unknown, granted, needed };
pub const DrainedCounts = struct { keystrokes: u64, clicks: u64 };
pub const max_permission_actions = backend.max_permission_actions;

pub fn start() void {
    backend.start();
}

pub fn drainCounts() DrainedCounts {
    const d = backend.drainCounts();
    return .{ .keystrokes = d.keystrokes, .clicks = d.clicks };
}

pub fn setPaused(paused: bool) void {
    backend.setPaused(paused);
}

pub fn permissionState() PermissionState {
    return switch (backend.permissionState()) {
        .unknown => .unknown,
        .granted => .granted,
        .needed => .needed,
    };
}

/// Labels for whatever the user can do about a `.needed` permission state
/// on this platform — zero on Windows (no permission model, §7.2), one on
/// Linux (an evdev group-membership instruction, §7.3), two on macOS
/// (Accessibility and Input Monitoring are checked and granted
/// separately, §7.1). `performAction` is the matching index's handler.
pub fn permissionActionLabels(buf: *[max_permission_actions][]const u8) []const []const u8 {
    return backend.permissionActionLabels(buf);
}

pub fn performPermissionAction(io: std.Io, index: usize) void {
    backend.performPermissionAction(io, index);
}
