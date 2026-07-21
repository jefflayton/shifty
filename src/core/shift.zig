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

const testing = std.testing;
const expectEqual = testing.expectEqual;
test "clockIn - no breaks" {
    const shift_hrs = 8;
    const in_ts: i64 = 1784503278;
    const out_ts = clockIn(shift_hrs, in_ts, &.{});

    // 1784503278       -- In Timestamp
    //   + (8 * 3600)   -- Shift Length
    const expected_out_ts = 1784532078;

    try expectEqual(out_ts, expected_out_ts);
}

test "clockIn - 1 break" {
    const shift_hrs = 8;
    const in_ts: i64 = 1784503278;
    const breaks: []const Interval = &.{
        .{
            .in_ts = 1784510478, // 1784503278 + (2 * 3600)
            .out_ts = 1784514078, // 1784503278 + (3 * 3600)
        },
    };

    const out_ts = clockIn(shift_hrs, in_ts, breaks);

    // 1784503278       -- In Timestamp
    //   + (8 * 3600)   -- Shift Length
    //   + (1 * 3600)   -- Break 1
    const expected_out_ts = 1784535678;

    try expectEqual(out_ts, expected_out_ts);
}

test "clockIn - 3 breaks" {
    const shift_hrs = 8;
    const in_ts: i64 = 1784503278;
    const breaks: []const Interval = &.{
        .{
            .in_ts = 1784510478, // 1784503278 + (2 * 3600)
            .out_ts = 1784514078, // 1784503278 + (3 * 3600)
        },
        .{
            .in_ts = 1784514078, // 1784503278 + (3 * 3600)
            .out_ts = 1784515698, // 1784503278 + (3 * 3600) + (0.45 * 3600)
        },
        .{
            .in_ts = 1784521278, // 1784503278 + (5 * 3600)
            .out_ts = 1784521638, // 1784503278 + (5 * 3600) + (0.1 * 3600)
        },
    };

    const out_ts = clockIn(shift_hrs, in_ts, breaks);

    // 1784503278           -- In Timestamp
    //   + (8 * 3600)       -- Shift Length
    //   + (1 * 3600)       -- Break 1
    //   + (0.45 * 3600)    -- Break 2
    //   + (0.1 * 3600)     -- Break 3
    const expected_out_ts = 1784537658;

    try expectEqual(out_ts, expected_out_ts);
}
