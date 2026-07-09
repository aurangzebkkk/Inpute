//! Windows global input listener (Functional Spec §6, §7.2).
//!
//! Two low-level hooks (`WH_KEYBOARD_LL`, `WH_MOUSE_LL`), each installed
//! and pumped from its own dedicated thread, exactly as the Win32 hook
//! API requires (a low-level hook only receives events while the
//! installing thread runs a message loop). Hand-bound against `user32`/
//! `kernel32` — Zig's `std.os.windows` covers NT/kernel32 surface, not the
//! user32 messaging/hook API this needs.
//!
//! NOTE: written to the documented Win32 ABI (stable since Windows 2000)
//! but not compiled or run on Windows — this dev machine is macOS-only.
//! Treat as unverified until built and exercised on a real Windows host.
const std = @import("std");

const HHOOK = *opaque {};
const HINSTANCE = ?*opaque {};
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const DWORD = u32;
const HWND = ?*opaque {};
const UINT = c_uint;
const BOOL = i32;
const ULONG_PTR = usize;
const LONG = i32;

const POINT = extern struct { x: LONG, y: LONG };

const MSG = extern struct {
    hwnd: HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

const KBDLLHOOKSTRUCT = extern struct {
    vkCode: DWORD,
    scanCode: DWORD,
    flags: DWORD,
    time: DWORD,
    dwExtraInfo: ULONG_PTR,
};

const MSLLHOOKSTRUCT = extern struct {
    pt: POINT,
    mouseData: DWORD,
    flags: DWORD,
    time: DWORD,
    dwExtraInfo: ULONG_PTR,
};

const WH_KEYBOARD_LL: i32 = 13;
const WH_MOUSE_LL: i32 = 14;
const HC_ACTION: i32 = 0;

const WM_KEYDOWN: UINT = 0x0100;
const WM_SYSKEYDOWN: UINT = 0x0104;
const WM_LBUTTONDOWN: UINT = 0x0201;
const WM_RBUTTONDOWN: UINT = 0x0204;
const WM_MBUTTONDOWN: UINT = 0x0207;

const HOOKPROC = *const fn (code: i32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;

extern "user32" fn SetWindowsHookExW(id_hook: i32, lpfn: HOOKPROC, hmod: HINSTANCE, thread_id: DWORD) callconv(.winapi) ?HHOOK;
extern "user32" fn UnhookWindowsHookEx(hhk: HHOOK) callconv(.winapi) BOOL;
extern "user32" fn CallNextHookEx(hhk: ?HHOOK, code: i32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn GetMessageW(msg: *MSG, hwnd: HWND, filter_min: UINT, filter_max: UINT) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) LRESULT;
extern "kernel32" fn GetModuleHandleW(module_name: ?[*:0]const u16) callconv(.winapi) HINSTANCE;

pub const PermissionState = enum(u8) { unknown, granted, needed };

var keystrokes = std.atomic.Value(u64).init(0);
var clicks = std.atomic.Value(u64).init(0);
var paused = std.atomic.Value(bool).init(false);
// No OS permission prompt gates `SetWindowsHookEx` (§7.2) — this only
// ever flips to `.needed` if hook installation itself fails, which
// degrades gracefully rather than crashing (§6).
var permission_state = std.atomic.Value(u8).init(@intFromEnum(PermissionState.granted));

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

/// Spawns the two dedicated hook-pump threads (§6). Each is independent:
/// one failing to install still leaves the other counting.
pub fn start() void {
    const kb = std.Thread.spawn(.{}, runKeyboardHook, .{}) catch null;
    if (kb) |t| t.detach() else permission_state.store(@intFromEnum(PermissionState.needed), .monotonic);

    const mouse = std.Thread.spawn(.{}, runMouseHook, .{}) catch null;
    if (mouse) |t| t.detach() else permission_state.store(@intFromEnum(PermissionState.needed), .monotonic);
}

fn pumpMessages() void {
    var msg: MSG = undefined;
    // A low-level hook only fires while its installing thread runs a
    // message loop — this blocks the thread forever, which is the point
    // (§6: "Runs on a dedicated background thread, never the UI thread").
    while (GetMessageW(&msg, null, 0, 0) > 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}

fn runKeyboardHook() void {
    const hmod = GetModuleHandleW(null);
    const hook = SetWindowsHookExW(WH_KEYBOARD_LL, keyboardProc, hmod, 0);
    if (hook == null) {
        permission_state.store(@intFromEnum(PermissionState.needed), .monotonic);
        return;
    }
    defer _ = UnhookWindowsHookEx(hook.?);
    pumpMessages();
}

fn runMouseHook() void {
    const hmod = GetModuleHandleW(null);
    const hook = SetWindowsHookExW(WH_MOUSE_LL, mouseProc, hmod, 0);
    if (hook == null) {
        permission_state.store(@intFromEnum(PermissionState.needed), .monotonic);
        return;
    }
    defer _ = UnhookWindowsHookEx(hook.?);
    pumpMessages();
}

// Every path through both procs ends in `CallNextHookEx` with the
// untouched code/wparam/lparam and returns its result verbatim — the
// Win32 contract for a passive observer (§6: never suppress, modify, or
// delay the underlying input), independent of the `nCode` value.

fn keyboardProc(code: i32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    if (code == HC_ACTION and !paused.load(.monotonic)) {
        const msg: UINT = @intCast(wparam);
        if (msg == WM_KEYDOWN or msg == WM_SYSKEYDOWN) {
            _ = keystrokes.fetchAdd(1, .monotonic);
        }
    }
    return CallNextHookEx(null, code, wparam, lparam);
}

fn mouseProc(code: i32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    if (code == HC_ACTION and !paused.load(.monotonic)) {
        const msg: UINT = @intCast(wparam);
        if (msg == WM_LBUTTONDOWN or msg == WM_RBUTTONDOWN or msg == WM_MBUTTONDOWN) {
            _ = clicks.fetchAdd(1, .monotonic);
        }
    }
    return CallNextHookEx(null, code, wparam, lparam);
}

/// No permission model to act on (§7.2) — `permissionState()` is only
/// ever `.needed` if hook installation itself failed, which no Settings
/// pane can fix, so there is nothing to offer here.
pub const max_permission_actions = 0;

pub fn permissionActionLabels(buf: *[max_permission_actions][]const u8) []const []const u8 {
    return buf[0..0];
}

pub fn performPermissionAction(io: std.Io, index: usize) void {
    _ = io;
    _ = index;
}
