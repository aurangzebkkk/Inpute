//! Linux autostart via an XDG autostart `.desktop` file (Functional Spec
//! §10). Opt-in and user-controlled: written/removed strictly by the
//! tray menu's "Enable/Disable Start at Login" toggle.
const std = @import("std");
const io_context = @import("../io_context.zig");

const desktop_file_name = "dev.native_sdk.inpute.desktop";

fn autostartDir(buf: []u8) ![]const u8 {
    if (io_context.env.get("XDG_CONFIG_HOME")) |xdg_config| {
        return std.fmt.bufPrint(buf, "{s}/autostart", .{xdg_config});
    }
    const home = io_context.env.get("HOME") orelse return error.MissingHome;
    return std.fmt.bufPrint(buf, "{s}/.config/autostart", .{home});
}

fn desktopFilePath(buf: []u8) ![]const u8 {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try autostartDir(&dir_buf);
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, desktop_file_name });
}

fn executablePath(io: std.Io, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const len = std.Io.Dir.readLinkAbsolute(io, "/proc/self/exe", buf) catch return error.ExecutablePathUnavailable;
    return buf[0..len];
}

pub fn isEnabled(io: std.Io) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = desktopFilePath(&path_buf) catch return false;
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

pub fn setEnabled(io: std.Io, enabled: bool) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try desktopFilePath(&path_buf);

    if (!enabled) {
        std.Io.Dir.deleteFileAbsolute(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return;
    }

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = try executablePath(io, &exe_buf);

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try autostartDir(&dir_buf);
    try std.Io.Dir.cwd().createDirPath(io, dir);

    var contents_buf: [1024]u8 = undefined;
    const contents = try std.fmt.bufPrint(&contents_buf,
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Inpute
        \\Exec="{s}"
        \\X-GNOME-Autostart-enabled=true
        \\NoDisplay=true
        \\
    , .{exe_path});

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents });
}
