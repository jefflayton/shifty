const std = @import("std");
const mem = std.mem;
const StaticStringMap = std.static_string_map.StaticStringMap;

const time = @import("time.zig");
const state = @import("state.zig");

const Handler = *const fn (params: []const u8, out: []u8) usize;

fn clockIn(params: []const u8, out: []u8) usize {
    std.debug.print("{s}:{d}: param={s}\n", .{ @src().file, @src().line, params });
    const timestamp = std.fmt.parseInt(i64, params, 10) catch |err| {
        std.debug.print("clock_in parse error: {}\n", .{err});
        return 0;
    };

    return (std.fmt.bufPrint(out, "{d}", .{timestamp}) catch return 0).len;
}

fn startup(params: []const u8, out: []u8) usize {
    std.debug.print("{s}:{d}: params={any}\n", .{ @src().file, @src().line, params });
    var iter = mem.splitScalar(u8, params, '|');

    const tz = iter.next() orelse return 0;
    state.setTimezone(tz);

    const now = std.fmt.parseInt(i64, iter.next() orelse return 0, 10) catch return 0;
    const shift_hrs = std.fmt.parseInt(u32, iter.next() orelse return 0, 10) catch return 0;
    const shift_mins = std.fmt.parseInt(u32, iter.next() orelse return 0, 10) catch return 0;

    const shift_secs: i64 = @as(i64, shift_hrs) * std.time.s_per_hour + @as(i64, shift_mins) * std.time.s_per_min;
    const clock_out = now + shift_secs;

    return (std.fmt.bufPrint(out, "{d}", .{clock_out}) catch return 0).len;
}

pub const router: StaticStringMap(Handler) = .initComptime(.{
    .{ "clock_in", clockIn },
    .{ "startup", startup },
});
