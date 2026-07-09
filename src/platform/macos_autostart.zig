//! macOS autostart via a per-user LaunchAgent (Functional Spec §10). Opt-in
//! and user-controlled: the plist is only ever written in response to the
//! tray menu's "Enable Start at Login" toggle, never on first launch.
const std = @import("std");
const io_context = @import("../io_context.zig");

// Hand-bound instead of `@cImport("mach-o/dyld.h")`: that header pulls in
// mach message headers this SDK's translate-c pass chokes on (see
// `macos_input.zig`). `_NSGetExecutablePath`'s C ABI is stable.
extern "c" fn _NSGetExecutablePath(buf: [*]u8, buf_size: *u32) c_int;

const label = "dev.native_sdk.inpute";

fn plistPath(buf: []u8) ![]const u8 {
    const home = io_context.env.get("HOME") orelse return error.MissingHome;
    return std.fmt.bufPrint(buf, "{s}/Library/LaunchAgents/{s}.plist", .{ home, label });
}

fn executablePath(buf: *[1024]u8) ![]const u8 {
    var size: u32 = @intCast(buf.len);
    if (_NSGetExecutablePath(buf, &size) != 0) return error.PathTooLong;
    const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..len];
}

pub fn isEnabled(io: std.Io) bool {
    var path_buf: [1024]u8 = undefined;
    const path = plistPath(&path_buf) catch return false;
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

pub fn setEnabled(io: std.Io, enabled: bool) !void {
    var path_buf: [1024]u8 = undefined;
    const path = try plistPath(&path_buf);

    if (!enabled) {
        std.Io.Dir.deleteFileAbsolute(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return;
    }

    var exe_buf: [1024]u8 = undefined;
    const exe_path = try executablePath(&exe_buf);

    const home = io_context.env.get("HOME") orelse return error.MissingHome;
    var dir_buf: [1024]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/Library/LaunchAgents", .{home});
    try std.Io.Dir.cwd().createDirPath(io, dir);

    var plist_buf: [2048]u8 = undefined;
    const plist = try std.fmt.bufPrint(&plist_buf,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>{s}</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>{s}</string>
        \\    </array>
        \\    <key>RunAtLoad</key>
        \\    <true/>
        \\    <key>ProcessType</key>
        \\    <string>Background</string>
        \\</dict>
        \\</plist>
        \\
    , .{ label, exe_path });

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = plist });
}
