const std = @import("std");
const time = std.time;

pub const Interval = extern struct {
    in_ts: i64,
    out_ts: i64,

    pub fn duration(self: Interval) ?i64 {
        if (self.out_ts <= self.in_ts) return null;

        return self.out_ts - self.in_ts;
    }
};

pub fn clockIn(shift_hrs: i64, in_ts: i64, breaks: []const Interval) i64 {
    var break_s: i64 = 0;
    for (breaks) |b| {
        if (b.duration()) |d| break_s += d;
    }
    return in_ts + shift_hrs * time.s_per_hour + break_s;
}
