const std = @import("std");
const testing = std.testing;

const date = @import("date.zig");
const storage = @import("storage.zig");
const io_context = @import("io_context.zig");

test "daysInMonth handles 30/31-day months and February" {
    try testing.expectEqual(@as(u8, 31), date.daysInMonth(2026, 1));
    try testing.expectEqual(@as(u8, 30), date.daysInMonth(2026, 4));
    try testing.expectEqual(@as(u8, 28), date.daysInMonth(2026, 2));
    try testing.expectEqual(@as(u8, 29), date.daysInMonth(2024, 2));
}

test "isLeapYear follows the Gregorian century rule" {
    try testing.expect(date.isLeapYear(2024));
    try testing.expect(!date.isLeapYear(2023));
    try testing.expect(!date.isLeapYear(1900));
    try testing.expect(date.isLeapYear(2000));
}

test "mondayFirstWeekday matches a known calendar date" {
    // 2026-07-09 is a Thursday (index 3, Monday-first).
    try testing.expectEqual(@as(u3, 3), date.mondayFirstWeekday(2026, 7, 9));
    // 2026-07-06 is a Monday (index 0).
    try testing.expectEqual(@as(u3, 0), date.mondayFirstWeekday(2026, 7, 6));
}

test "monthsBefore rolls back across a year boundary" {
    const one_back = date.monthsBefore(2026, 1, 1);
    try testing.expectEqual(@as(i32, 2025), one_back.year);
    try testing.expectEqual(@as(u8, 12), one_back.month);

    const five_back = date.monthsBefore(2026, 7, 5);
    try testing.expectEqual(@as(i32, 2026), five_back.year);
    try testing.expectEqual(@as(u8, 2), five_back.month);
}

test "storage save/load/loadAll round-trips through real files, skipping corrupt ones" {
    io_context.io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home_len = try tmp.dir.realPath(io_context.io, &home_buf);
    const home = home_buf[0..home_len];

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", home);
    // Windows' app_dirs resolution needs LOCALAPPDATA specifically (no
    // HOME-based fallback, unlike macOS/Linux) — reuse the same temp dir
    // since this test only needs *a* writable directory, not real-world
    // path semantics. Missing this never surfaced until the test suite
    // actually ran on a Windows machine (error.MissingRequiredEnv).
    try env.put("LOCALAPPDATA", home);
    io_context.env = &env;

    const day_a = storage.DayCounts{ .date = "2026-07-08".*, .keystrokes = 4821, .clicks = 312 };
    try storage.save(io_context.io, day_a);

    const loaded = storage.load(io_context.io, "2026-07-08");
    try testing.expectEqual(day_a.keystrokes, loaded.keystrokes);
    try testing.expectEqual(day_a.clicks, loaded.clicks);

    // A day with no file at all comes back zeroed, not an error.
    const missing = storage.load(io_context.io, "2026-01-01");
    try testing.expectEqual(@as(u64, 0), missing.keystrokes);
    try testing.expectEqual(@as(u64, 0), missing.clicks);

    // A corrupt file must not break the rest of the scan (§3: loadAll
    // "must skip and ignore any file that fails to parse").
    const dir_path = try storage.dataDir(io_context.io);
    var dir = try std.Io.Dir.cwd().openDir(io_context.io, dir_path, .{});
    defer dir.close(io_context.io);
    try dir.writeFile(io_context.io, .{ .sub_path = "2026-07-09.json", .data = "not json" });

    const all = try storage.loadAll(io_context.io, testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 1), all.len);
    try testing.expectEqualStrings("2026-07-08", &all[0].date);
}
