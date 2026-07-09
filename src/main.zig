//! Inpute — a background tray app that counts the user's own keystrokes
//! and mouse clicks per day (see `Functional Spec.md`). No code path here
//! ever touches which key or button fired, cursor position, or any text
//! content — only the two integer counters described in the spec.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const io_context = @import("io_context.zig");
const storage = @import("storage.zig");
const date = @import("date.zig");
const input = @import("platform/input.zig");
const autostart = @import("platform/autostart.zig");

const canvas_label = "main-canvas";
const calendar_canvas_label = "calendar-canvas";
const window_width: f32 = 320;
const window_height: f32 = 180;
const tick_timer_key: u64 = 1;
// Fixed command names for whichever permission actions the platform
// backend reports (0-2 of them, see `input.max_permission_actions`) —
// index-matched against `input.permissionActionLabels`.
const permission_action_commands = [_][]const u8{ "app.permission_action.0", "app.permission_action.1" };
const tick_interval_ms: u64 = 60_000;
const calendar_months: u8 = 6;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
// This SDK version's canvas surface only ships a Metal backend (macOS)
// plus a generic software fallback (`GpuSurfaceBackend` has no
// Direct3D/Vulkan member) — untested on Windows/Linux, see the platform
// notes in `Functional Spec.md`'s implementation log.
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Startup canvas", .accessibility_label = "Inpute", .gpu_backend = if (builtin.os.tag == .macos) .metal else .software, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
// The main screen: today's live stats plus "Show Calendar" / "Minimize".
// Also doubles as the runtime's required always-open window — this SDK
// has no headless/zero-window run mode (closing the last window quits
// the app outright), so "Minimize" (not close) is how this gets out of
// the way.
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Inpute",
    .width = window_width,
    .height = window_height,
    .resizable = false,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const Msg = union(enum) {
    tick: native_sdk.EffectTimer,
    open_calendar,
    close_calendar,
    minimize_window,
    toggle_pause,
    toggle_autostart,
    select_day: usize,
    quit,
};

pub const Model = struct {
    today: [10]u8 = .{ '0', '0', '0', '0', '-', '0', '0', '-', '0', '0' },
    keystrokes: u64 = 0,
    clicks: u64 = 0,
    paused: bool = false,
    permission_needed: bool = false,
    autostart_enabled: bool = false,
    calendar_open: bool = false,
    calendar_days: []const storage.DayEntry = &.{},
    calendar_max_activity: u64 = 0,
    all_time_keystrokes: u64 = 0,
    all_time_clicks: u64 = 0,
    selected_day: ?usize = null,
};

pub fn initialModel() Model {
    return .{};
}

fn freeCalendarData(model: *Model) void {
    if (model.calendar_days.len > 0) {
        std.heap.page_allocator.free(model.calendar_days);
        model.calendar_days = &.{};
    }
}

// Reloads disk-backed history. Does NOT touch `selected_day` — this runs
// both when the calendar first opens and on every tick while it stays
// open (see the `.tick` handler), and a periodic refresh silently
// clearing whatever day you're looking at would be a worse bug than the
// staleness it's fixing.
fn loadCalendarData(model: *Model) void {
    freeCalendarData(model);
    const entries = storage.loadAll(io_context.io, std.heap.page_allocator) catch &.{};
    model.calendar_days = entries;

    var max_activity: u64 = 0;
    var all_keys: u64 = 0;
    var all_clicks: u64 = 0;
    for (entries) |entry| {
        const activity = entry.counts.keystrokes + entry.counts.clicks;
        if (activity > max_activity) max_activity = activity;
        all_keys += entry.counts.keystrokes;
        all_clicks += entry.counts.clicks;
    }
    // Historical (persisted) totals only — today's still-live counters are
    // shown on the main screen, not folded in here.
    model.calendar_max_activity = max_activity;
    model.all_time_keystrokes = all_keys;
    model.all_time_clicks = all_clicks;
}

fn persistToday(model: *const Model) void {
    storage.save(io_context.io, .{ .date = model.today, .keystrokes = model.keystrokes, .clicks = model.clicks }) catch |err| {
        std.log.warn("failed to save today's counts: {t}", .{err});
    };
}

fn rolloverIfNeeded(model: *Model) void {
    const now = date.today();
    var buf: [10]u8 = undefined;
    const today_str = date.formatInto(&buf, now);
    if (std.mem.eql(u8, today_str, &model.today)) return;

    // The outgoing day's final counts, then start the new day fresh (or
    // resume a previously-saved partial record, if the app relaunched
    // mid-day and this is the very first tick after that).
    persistToday(model);
    model.today = model.today; // outgoing date already matches the field
    @memcpy(&model.today, today_str);
    const loaded = storage.load(io_context.io, today_str);
    model.keystrokes = loaded.keystrokes;
    model.clicks = loaded.clicks;
}

fn update(model: *Model, msg: Msg, fx: *InputTrackerApp.Effects) void {
    switch (msg) {
        .tick => |timer| switch (timer.outcome) {
            .fired => {
                rolloverIfNeeded(model);
                const drained = input.drainCounts();
                model.keystrokes += drained.keystrokes;
                model.clicks += drained.clicks;
                model.permission_needed = input.permissionState() == .needed;
                persistToday(model);
                // Keep the calendar's disk-backed history (and the
                // all-time summary, which is deliberately historical-only
                // — see `loadCalendarData`) in sync while it's left open
                // across a tick, not just at the moment it was opened.
                if (model.calendar_open) loadCalendarData(model);
            },
            .rejected => std.log.warn("60s tick timer rejected", .{}),
        },
        .open_calendar => {
            model.calendar_open = true;
            model.selected_day = null;
            loadCalendarData(model);
        },
        .close_calendar => {
            model.calendar_open = false;
            freeCalendarData(model);
        },
        .minimize_window => fx.minimizeWindow("main"),
        .toggle_pause => {
            model.paused = !model.paused;
            input.setPaused(model.paused);
        },
        .toggle_autostart => {
            model.autostart_enabled = !model.autostart_enabled;
            autostart.setEnabled(io_context.io, model.autostart_enabled) catch |err| {
                std.log.warn("failed to update autostart: {t}", .{err});
                model.autostart_enabled = !model.autostart_enabled;
            };
        },
        .select_day => |index| {
            model.selected_day = if (model.selected_day != null and model.selected_day.? == index) null else index;
        },
        .quit => {
            persistToday(model);
            std.process.exit(0);
        },
    }
}

fn initFx(model: *Model, fx: *InputTrackerApp.Effects) void {
    const now = date.today();
    _ = date.formatInto(&model.today, now);
    const loaded = storage.load(io_context.io, &model.today);
    model.keystrokes = loaded.keystrokes;
    model.clicks = loaded.clicks;
    model.permission_needed = input.permissionState() == .needed;
    model.autostart_enabled = autostart.isEnabled(io_context.io);

    input.start();
    fx.startTimer(.{ .key = tick_timer_key, .interval_ms = tick_interval_ms, .mode = .repeating, .on_fire = InputTrackerApp.Effects.timerMsg(.tick) });
}

// -------------------------------------------------------------- tray/menu

const InputTrackerApp = native_sdk.UiAppWithFeatures(Model, Msg, .{});

fn statusItem(model: *const Model, scratch: *InputTrackerApp.StatusItemScratch) InputTrackerApp.StatusItemState {
    const title = if (model.permission_needed)
        "Inpute ⚠︎ permission needed"
    else if (model.paused)
        std.fmt.bufPrint(&scratch.title_buffer, "Paused (Keys {d} · Clicks {d})", .{ model.keystrokes, model.clicks }) catch "Inpute"
    else
        std.fmt.bufPrint(&scratch.title_buffer, "Keys {d} · Clicks {d}", .{ model.keystrokes, model.clicks }) catch "Inpute";

    var count: usize = 0;
    if (model.permission_needed) {
        var action_labels_buf: [input.max_permission_actions][]const u8 = undefined;
        const action_labels = input.permissionActionLabels(&action_labels_buf);
        for (action_labels, 0..) |label, action_index| {
            scratch.items[count] = .{
                .id = @intCast(10 + action_index),
                .label = label,
                .command = permission_action_commands[action_index],
            };
            count += 1;
        }
        if (action_labels.len > 0) {
            scratch.items[count] = .{ .separator = true };
            count += 1;
        }
    }
    scratch.items[count] = .{ .id = 3, .label = "View Calendar", .command = "app.view_calendar" };
    count += 1;
    scratch.items[count] = .{ .id = 4, .label = if (model.paused) "Resume Tracking" else "Pause Tracking", .command = "app.toggle_pause" };
    count += 1;
    scratch.items[count] = .{ .id = 5, .label = if (model.autostart_enabled) "Disable Start at Login" else "Enable Start at Login", .command = "app.toggle_autostart" };
    count += 1;
    scratch.items[count] = .{ .separator = true };
    count += 1;
    scratch.items[count] = .{ .id = 6, .label = "Quit", .command = "app.quit" };
    count += 1;

    return .{ .title = title, .items = scratch.items[0..count] };
}

fn onCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, "app.view_calendar")) return .open_calendar;
    if (std.mem.eql(u8, name, "app.toggle_pause")) return .toggle_pause;
    if (std.mem.eql(u8, name, "app.toggle_autostart")) return .toggle_autostart;
    if (std.mem.eql(u8, name, "app.quit")) return .quit;
    for (permission_action_commands, 0..) |command, action_index| {
        if (std.mem.eql(u8, name, command)) {
            input.performPermissionAction(io_context.io, action_index);
            return null;
        }
    }
    return null;
}

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

// ------------------------------------------------------- calendar window

fn windows(model: *const Model, scratch: *InputTrackerApp.WindowsScratch) []const InputTrackerApp.WindowDescriptor {
    var count: usize = 0;
    if (model.calendar_open) {
        scratch.windows[count] = .{
            .label = "calendar",
            .canvas_label = calendar_canvas_label,
            .title = "Inpute — Activity Calendar",
            .width = 620,
            .height = 640,
            .min_width = 520,
            .min_height = 480,
            .on_close = .close_calendar,
        };
        count += 1;
    }
    return scratch.windows[0..count];
}

fn findDay(model: *const Model, year: i32, month: u8, day: u8) ?storage.DayCounts {
    var buf: [10]u8 = undefined;
    const wanted = date.formatInto(&buf, .{ .year = year, .month = month, .day = day });

    // Today's cell reads the LIVE model counters, not the on-disk
    // snapshot: `calendar_days` is only ever as fresh as the last 60s
    // tick's save, so without this the calendar's today cell (and the
    // detail line when you click it) would lag behind the menu bar by up
    // to a minute, or until the calendar is closed and reopened.
    if (std.mem.eql(u8, wanted, &model.today)) {
        return .{ .date = model.today, .keystrokes = model.keystrokes, .clicks = model.clicks };
    }

    for (model.calendar_days) |entry| {
        if (std.mem.eql(u8, &entry.date, wanted)) return entry.counts;
    }
    return null;
}

fn heatColor(activity: u64, max_activity: u64) canvas.Color {
    const base = canvas.Color.rgb8(30, 33, 38);
    const accent = canvas.Color.rgb8(64, 156, 255);
    if (max_activity == 0 or activity == 0) return base;
    const t: f32 = @min(1.0, @as(f32, @floatFromInt(activity)) / @as(f32, @floatFromInt(max_activity)));
    return canvas.Color.rgba(
        base.r + (accent.r - base.r) * t,
        base.g + (accent.g - base.g) * t,
        base.b + (accent.b - base.b) * t,
        1,
    );
}

fn dayCell(ui: *InputTrackerApp.Ui, model: *const Model, year: i32, month: u8, day: u8, global_index: usize, is_today: bool) InputTrackerApp.Ui.Node {
    const counts = findDay(model, year, month, day);
    const activity = if (counts) |c| c.keystrokes + c.clicks else 0;
    // Allocated from the rebuild arena, not a function-local stack buffer:
    // the returned Node stores this slice BY REFERENCE, so it must outlive
    // this call — a stack array's contents get clobbered by the next
    // sibling cell's call frame before the tree is ever rendered.
    const label = std.fmt.allocPrint(ui.arena, "{d}", .{day}) catch "";

    return ui.panel(.{
        .width = 30,
        .height = 30,
        .main = .center,
        .cross = .center,
        .style = .{
            .background = heatColor(activity, model.calendar_max_activity),
            .border = if (is_today) canvas.Color.rgb8(255, 255, 255) else null,
            .stroke_width = if (is_today) 2 else 1,
            .radius = 6,
        },
        .semantics = .{ .label = if (counts) |c|
            std.fmt.allocPrint(ui.arena, "{d}-{d:0>2}-{d:0>2}: {d} keys, {d} clicks", .{ year, month, day, c.keystrokes, c.clicks }) catch "day"
        else
            "no activity recorded" },
        .on_press = .{ .select_day = global_index },
    }, .{
        ui.text(.{ .width = 30, .text_alignment = .center }, label),
    });
}

fn monthGrid(ui: *InputTrackerApp.Ui, model: *const Model, year: i32, month: u8, today_ymd: date.YMD, index_base: *usize) InputTrackerApp.Ui.Node {
    const days = date.daysInMonth(year, month);
    const first_weekday = date.mondayFirstWeekday(year, month, 1);

    var week_nodes = std.ArrayList(InputTrackerApp.Ui.Node).empty;
    var cells = std.ArrayList(InputTrackerApp.Ui.Node).empty;
    var col: u3 = 0;

    var pad: u3 = 0;
    while (pad < first_weekday) : (pad += 1) {
        cells.append(ui.arena, ui.panel(.{ .width = 30, .height = 30 }, .{})) catch {};
        col += 1;
    }

    var day: u8 = 1;
    while (day <= days) : (day += 1) {
        const is_today = year == today_ymd.year and month == today_ymd.month and day == today_ymd.day;
        cells.append(ui.arena, dayCell(ui, model, year, month, day, index_base.*, is_today)) catch {};
        index_base.* += 1;
        col += 1;
        if (col == 7) {
            week_nodes.append(ui.arena, ui.row(.{ .gap = 4 }, cells.items)) catch {};
            cells = std.ArrayList(InputTrackerApp.Ui.Node).empty;
            col = 0;
        }
    }
    if (col > 0) {
        while (col < 7) : (col += 1) {
            cells.append(ui.arena, ui.panel(.{ .width = 30, .height = 30 }, .{})) catch {};
        }
        week_nodes.append(ui.arena, ui.row(.{ .gap = 4 }, cells.items)) catch {};
    }

    return ui.column(.{ .gap = 4 }, .{
        ui.text(.{ .size = .heading }, date.monthName(month)),
        ui.column(.{ .gap = 4 }, week_nodes.items),
    });
}

fn calendarView(ui: *InputTrackerApp.Ui, model: *const Model, window_label: []const u8) InputTrackerApp.Ui.Node {
    _ = window_label;
    const today_ymd = date.today();

    // Descending order: the current month first, oldest last.
    var months = std.ArrayList(InputTrackerApp.Ui.Node).empty;
    var index_base: usize = 0;
    var i: u8 = 0;
    while (i < calendar_months) : (i += 1) {
        const ym = date.monthsBefore(today_ymd.year, today_ymd.month, i);
        months.append(ui.arena, monthGrid(ui, model, ym.year, ym.month, today_ymd, &index_base)) catch {};
    }

    // Arena-allocated (see `dayCell`): these strings are stored by
    // reference in the returned Node and must outlive this function call.
    const summary = std.fmt.allocPrint(ui.arena, "All time — Keys {d} · Clicks {d}", .{ model.all_time_keystrokes, model.all_time_clicks }) catch "All time";

    const detail: []const u8 = if (model.selected_day) |idx| blk: {
        var found: ?storage.DayEntry = null;
        var counter: usize = 0;
        outer: for (0..calendar_months) |m_offset| {
            const ym = date.monthsBefore(today_ymd.year, today_ymd.month, @intCast(m_offset));
            const days = date.daysInMonth(ym.year, ym.month);
            var d: u8 = 1;
            while (d <= days) : (d += 1) {
                if (counter == idx) {
                    var date_buf: [10]u8 = undefined;
                    const key = date.formatInto(&date_buf, .{ .year = ym.year, .month = ym.month, .day = d });
                    var date_copy: [10]u8 = undefined;
                    @memcpy(&date_copy, key);
                    const counts = findDay(model, ym.year, ym.month, d) orelse storage.DayCounts{ .date = date_copy };
                    found = .{ .date = date_copy, .counts = counts };
                    break :outer;
                }
                counter += 1;
            }
        }
        break :blk if (found) |f|
            std.fmt.allocPrint(ui.arena, "{s}: {d} keys · {d} clicks", .{ f.date, f.counts.keystrokes, f.counts.clicks }) catch ""
        else
            "";
    } else "Click a day to see its exact counts.";

    return ui.scroll(.{ .grow = 1 }, .{
        ui.column(.{ .gap = 16, .padding = 16 }, .{
            ui.text(.{ .size = .heading }, summary),
            ui.text(.{}, detail),
            ui.column(.{ .gap = 20 }, months.items),
        }),
    });
}

// -------------------------------------------------------------------- app

pub fn main(init: std.process.Init) !void {
    io_context.io = init.io;
    io_context.env = init.environ_map;

    const app_state = try InputTrackerApp.create(std.heap.page_allocator, .{
        .name = "inpute",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = initFx,
        .on_command = onCommand,
        .status_item = .{ .title = "Inpute", .tooltip = "Inpute — activity counter" },
        .status_item_fn = statusItem,
        .windows_fn = windows,
        .window_view = calendarView,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "inpute",
        .window_title = "Inpute",
        .bundle_id = "dev.native_sdk.inpute",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
