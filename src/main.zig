const std = @import("std");
const time = std.time;

extern fn swiftuiInit() void;
extern fn swiftuiRun() void;

comptime {
    _ = @import("ffi.zig");
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    swiftuiInit();
    swiftuiRun();
}
