const shift = @import("shift.zig");

export fn clockIn(shift_hrs: i64, in_ts: i64, breaks_ptr: [*]const shift.Interval, breaks_len: usize) i64 {
    const breaks: []const shift.Interval = breaks_ptr[0..breaks_len];
    return shift.clockIn(shift_hrs, in_ts, breaks);
}
