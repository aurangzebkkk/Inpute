//! Minimal local-time calendar helpers (Functional Spec §5: day rollover
//! keys off *local* system time, and §9's six-month grid needs
//! weekday-of-month and days-in-month). Delegates the timezone-sensitive
//! parts to libc (`time`/`localtime_r`/`mktime`) instead of hand-rolling
//! DST/leap-second-adjacent logic.
const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});

pub const YMD = struct { year: i32, month: u8, day: u8 };

pub fn today() YMD {
    var t: c.time_t = c.time(null);
    var tm_buf: c.struct_tm = undefined;
    _ = c.localtime_r(&t, &tm_buf);
    return .{
        .year = @as(i32, @intCast(tm_buf.tm_year)) + 1900,
        .month = @as(u8, @intCast(tm_buf.tm_mon)) + 1,
        .day = @as(u8, @intCast(tm_buf.tm_mday)),
    };
}

pub fn formatInto(buf: *[10]u8, ymd: YMD) []const u8 {
    // `ymd.year` as `u32`, not `i32`: zero-padded signed formatting emits
    // an explicit '+'/'-' sign, which made "YYYY-MM-DD" 11 bytes and
    // silently truncated when copied into a fixed 10-byte date field.
    // Years here are never negative in practice.
    const year: u32 = @intCast(ymd.year);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, ymd.month, ymd.day }) catch buf[0..0];
}

pub fn isLeapYear(year: i32) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
}

pub fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) @as(u8, 29) else 28,
        else => 30,
    };
}

/// 0 = Monday .. 6 = Sunday, via a libc mktime/localtime_r round trip
/// (noon local time sidesteps any DST-transition-day edge case).
pub fn mondayFirstWeekday(year: i32, month: u8, day: u8) u3 {
    var tm_buf: c.struct_tm = std.mem.zeroes(c.struct_tm);
    tm_buf.tm_year = @intCast(year - 1900);
    tm_buf.tm_mon = @intCast(month - 1);
    tm_buf.tm_mday = @intCast(day);
    tm_buf.tm_hour = 12;
    const t = c.mktime(&tm_buf);
    var normalized: c.struct_tm = undefined;
    _ = c.localtime_r(&t, &normalized);
    // tm_wday is 0=Sunday..6=Saturday; rotate to 0=Monday..6=Sunday.
    const sunday_first: i32 = @intCast(normalized.tm_wday);
    return @intCast(@mod(sunday_first + 6, 7));
}

/// Subtracts `count` months from (year, month), landing on the 1st.
pub fn monthsBefore(year: i32, month: u8, count: u8) struct { year: i32, month: u8 } {
    var y = year;
    var m: i32 = @as(i32, month) - @as(i32, count);
    while (m < 1) {
        m += 12;
        y -= 1;
    }
    return .{ .year = y, .month = @intCast(m) };
}

pub fn monthName(month: u8) []const u8 {
    const names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
    return names[month - 1];
}
