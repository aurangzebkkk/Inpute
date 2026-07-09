//! Windows autostart via a per-user Registry `Run` entry (Functional Spec
//! §10) — no admin rights needed, unlike a machine-wide Run key or a
//! service. Opt-in only: written/removed strictly by the tray menu's
//! "Enable/Disable Start at Login" toggle.
//!
//! NOTE: written to the documented Win32 registry ABI but not compiled or
//! run on Windows — see `windows_input.zig`.
const std = @import("std");

const HKEY = *opaque {};
const LSTATUS = i32;
const DWORD = u32;
const REGSAM = u32;

const hkey_current_user: HKEY = @ptrFromInt(0x80000001);
const key_read: REGSAM = 0x20019;
const key_write: REGSAM = 0x20006;
const reg_sz: DWORD = 1;
const error_success: LSTATUS = 0;
const error_file_not_found: LSTATUS = 2;

extern "advapi32" fn RegOpenKeyExW(hkey: HKEY, sub_key: [*:0]const u16, options: DWORD, sam: REGSAM, result: *?HKEY) callconv(.winapi) LSTATUS;
extern "advapi32" fn RegSetValueExW(hkey: HKEY, value_name: [*:0]const u16, reserved: DWORD, value_type: DWORD, data: [*]const u8, data_size: DWORD) callconv(.winapi) LSTATUS;
extern "advapi32" fn RegDeleteValueW(hkey: HKEY, value_name: [*:0]const u16) callconv(.winapi) LSTATUS;
extern "advapi32" fn RegQueryValueExW(hkey: HKEY, value_name: [*:0]const u16, reserved: ?*DWORD, value_type: ?*DWORD, data: ?[*]u8, data_size: ?*DWORD) callconv(.winapi) LSTATUS;
extern "advapi32" fn RegCloseKey(hkey: HKEY) callconv(.winapi) LSTATUS;
extern "kernel32" fn GetModuleFileNameW(module: ?*anyopaque, filename: [*]u16, size: DWORD) callconv(.winapi) DWORD;

const run_key_path = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const value_name = std.unicode.utf8ToUtf16LeStringLiteral("Inpute");

pub fn isEnabled(io: std.Io) bool {
    _ = io;
    var key: ?HKEY = null;
    if (RegOpenKeyExW(hkey_current_user, run_key_path, 0, key_read, &key) != error_success) return false;
    defer _ = RegCloseKey(key.?);

    var data_size: DWORD = 0;
    const status = RegQueryValueExW(key.?, value_name, null, null, null, &data_size);
    return status == error_success;
}

pub fn setEnabled(io: std.Io, enabled: bool) !void {
    _ = io;
    var key: ?HKEY = null;
    if (RegOpenKeyExW(hkey_current_user, run_key_path, 0, key_write, &key) != error_success) return error.RegistryOpenFailed;
    defer _ = RegCloseKey(key.?);

    if (!enabled) {
        const status = RegDeleteValueW(key.?, value_name);
        if (status != error_success and status != error_file_not_found) return error.RegistryDeleteFailed;
        return;
    }

    var exe_path_buf: [std.fs.max_path_bytes / 2]u16 = undefined;
    const len = GetModuleFileNameW(null, &exe_path_buf, exe_path_buf.len);
    if (len == 0) return error.ExecutablePathUnavailable;

    // Quoted so a path containing spaces (Program Files, a username with
    // a space) still parses as one token when the shell launches it.
    var quoted_buf: [std.fs.max_path_bytes / 2 + 2]u16 = undefined;
    quoted_buf[0] = '"';
    @memcpy(quoted_buf[1 .. 1 + len], exe_path_buf[0..len]);
    quoted_buf[1 + len] = '"';
    quoted_buf[2 + len] = 0;
    const quoted_len = 2 + len;

    const data_bytes = std.mem.sliceAsBytes(quoted_buf[0 .. quoted_len + 1]);
    const status = RegSetValueExW(key.?, value_name, 0, reg_sz, data_bytes.ptr, @intCast(data_bytes.len));
    if (status != error_success) return error.RegistrySetFailed;
}
