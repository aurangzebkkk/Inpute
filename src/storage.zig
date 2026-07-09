//! Local, single-user JSON storage for daily key/click counts (Functional
//! Spec §3). One flat file per calendar day, named "YYYY-MM-DD.json", in a
//! platform-appropriate app-data directory. No database, no network I/O:
//! every operation here is a plain synchronous filesystem call, cheap
//! enough to run once per 60s tick (§5) without a background executor.

const std = @import("std");
const app_dirs = @import("native_sdk").app_dirs;
const io_context = @import("io_context.zig");

pub const DayCounts = struct {
    date: [10]u8 = .{ '0', '0', '0', '0', '-', '0', '0', '-', '0', '0' },
    keystrokes: u64 = 0,
    clicks: u64 = 0,
};

/// The directory name the spec table names for every platform
/// ("InputTracker"), independent of the app's own bundle id/display name.
const app_name = "InputTracker";

var data_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
var data_dir: ?[]const u8 = null;

/// Resolves (and creates, if missing) the app-data directory once. Safe to
/// call repeatedly; later calls reuse the cached path. Surfaces
/// directory-creation failures (§7.4: read-only home, disk full) to the
/// caller instead of failing silently.
pub fn dataDir(io: std.Io) ![]const u8 {
    if (data_dir) |dir| return dir;

    const home = io_context.env.get("HOME") orelse return error.MissingHome;
    const env: app_dirs.Env = .{
        .home = home,
        .xdg_data_home = io_context.env.get("XDG_DATA_HOME"),
        .local_app_data = io_context.env.get("LOCALAPPDATA"),
    };
    const platform = app_dirs.currentPlatform();
    const dir = try app_dirs.resolveOne(.{ .name = app_name }, platform, env, .data, &data_dir_buf);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    data_dir = dir;
    return dir;
}

fn dayPath(buf: []u8, io: std.Io, day: []const u8) ![]const u8 {
    const dir = try dataDir(io);
    return std.fmt.bufPrint(buf, "{s}/{s}.json", .{ dir, day });
}

/// Returns a zeroed record if no file exists (or it fails to parse) for
/// that date — a fresh day, or a first launch, both look the same.
pub fn load(io: std.Io, day: []const u8) DayCounts {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = dayPath(&path_buf, io, day) catch return zeroed(day);

    var file_buf: [4096]u8 = undefined;
    const bytes = std.Io.Dir.cwd().readFile(io, path, &file_buf) catch return zeroed(day);

    return parse(bytes, day) orelse zeroed(day);
}

fn zeroed(day: []const u8) DayCounts {
    var counts = DayCounts{};
    const len = @min(day.len, counts.date.len);
    @memcpy(counts.date[0..len], day[0..len]);
    return counts;
}

fn parse(bytes: []const u8, fallback_day: []const u8) ?DayCounts {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, arena_state.allocator(), bytes, .{}) catch return null;
    const obj = parsed.value.object;

    var counts = zeroed(fallback_day);
    if (obj.get("date")) |date_value| {
        if (date_value == .string) {
            const len = @min(date_value.string.len, counts.date.len);
            @memcpy(counts.date[0..len], date_value.string[0..len]);
        }
    }
    counts.keystrokes = readU64(obj, "keystrokes") orelse return null;
    counts.clicks = readU64(obj, "clicks") orelse return null;
    return counts;
}

fn readU64(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |i| if (i < 0) null else @intCast(i),
        else => null,
    };
}

/// Writes/overwrites the file for that date. Errors (disk full, read-only
/// home) propagate to the caller — the tick handler (§5) logs and keeps
/// running rather than crashing.
pub fn save(io: std.Io, counts: DayCounts) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try dayPath(&path_buf, io, &counts.date);

    var out_buf: [256]u8 = undefined;
    const json = try std.fmt.bufPrint(&out_buf, "{{\"date\": \"{s}\", \"keystrokes\": {d}, \"clicks\": {d}}}", .{
        counts.date, counts.keystrokes, counts.clicks,
    });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
}

pub const DayEntry = struct {
    date: [10]u8,
    counts: DayCounts,
};

/// Scans the data directory for the calendar view (§9). Skips (does not
/// abort on) any file that fails to open, read, or parse, so one corrupt
/// day never breaks the whole calendar. Caller owns the returned slice.
pub fn loadAll(io: std.Io, allocator: std.mem.Allocator) ![]DayEntry {
    var list: std.ArrayList(DayEntry) = .empty;
    errdefer list.deinit(allocator);

    const dir_path = dataDir(io) catch return list.toOwnedSlice(allocator);
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        return list.toOwnedSlice(allocator);
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (entry.name.len != "YYYY-MM-DD.json".len) continue;

        var file_buf: [4096]u8 = undefined;
        const bytes = dir.readFile(io, entry.name, &file_buf) catch continue;
        const day = entry.name[0..10];
        const counts = parse(bytes, day) orelse continue;

        var date: [10]u8 = undefined;
        @memcpy(&date, day);
        try list.append(allocator, .{ .date = date, .counts = counts });
    }

    return list.toOwnedSlice(allocator);
}
