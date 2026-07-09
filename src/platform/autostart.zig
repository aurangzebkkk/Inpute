//! Cross-platform facade over autostart-at-login (Functional Spec §10).
//! `main.zig` only ever talks to this file.
const std = @import("std");
const builtin = @import("builtin");

const backend = switch (builtin.os.tag) {
    .macos => @import("macos_autostart.zig"),
    .windows => @import("windows_autostart.zig"),
    .linux => @import("linux_autostart.zig"),
    else => @compileError("Inpute has no autostart backend for this OS"),
};

pub fn isEnabled(io: std.Io) bool {
    return backend.isEnabled(io);
}

pub fn setEnabled(io: std.Io, enabled: bool) !void {
    return backend.setEnabled(io, enabled);
}
