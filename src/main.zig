const std = @import("std");
const time = std.time;

extern fn swiftuiInit() void;
extern fn swiftuiRun() void;

export fn zigClockIn(shift: c_int, in_ts: c_long, lunch: c_int) c_long {
    const shift_s = shift * time.s_per_hour;
    const lunch_s = lunch * time.s_per_min;
    return in_ts + shift_s + lunch_s;
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    swiftuiInit();
    swiftuiRun();
}
