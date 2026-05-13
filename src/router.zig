const std = @import("std");
const mem = std.mem;
const StaticStringMap = std.static_string_map.StaticStringMap;

const time = @import("time.zig");
const state = @import("state.zig");

const Handler = *const fn (params: []const u8) []const u8;

fn clockIn(params: []const u8) []const u8 {
    std.debug.print("{s}:{d}: param={s}\n", .{ @src().file, @src().line, params });
    const timestamp = std.fmt.parseInt(i64, params, 10) catch |err| {
        std.debug.print("clock_in parse error: {}\n", .{err});
        return "";
    };
    std.debug.print("clock_in: timestamp={d}\n", .{timestamp});
    return params;
}

fn setTimezone(params: []const u8) []const u8 {
    state.setTimezone(params);
    return "";
}

pub const router: StaticStringMap(Handler) = .initComptime(.{
    .{ "clock_in", clockIn },
    .{ "timezone", setTimezone },
});
