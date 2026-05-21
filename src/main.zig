const std = @import("std");

extern fn swiftuiInit() void;
extern fn swiftuiRun() void;

export fn zigClockIn(ts: c_long) void {
    std.debug.print("{d}\n", .{ts});
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    swiftuiInit();
    swiftuiRun();
}
