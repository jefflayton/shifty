const std = @import("std");
const time = std.time;

extern fn swiftuiInit() void;
extern fn swiftuiRun() void;

export fn zigClockIn(ts: c_long) c_long {
    return ts + (8 * time.ms_per_hour);
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    swiftuiInit();
    swiftuiRun();
}
