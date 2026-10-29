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

/// Returns the clock-out timestamp for a shift of `shift_secs` worked time
/// starting at `in_ts`, extended by any time spent on `breaks`.
///
/// Only break time that falls inside the shift counts: time before `in_ts` or
/// after the (break-extended) clock-out is ignored, and overlapping breaks are
/// counted once. Invalid breaks (`out_ts <= in_ts`) are skipped.
pub fn clockIn(shift_secs: i64, in_ts: i64, breaks: []const Interval) i64 {
    // Sweep breaks in order of effective start without allocating; break
    // counts are tiny so O(n^2) is fine.
    var out_ts = in_ts + shift_secs;
    var cursor = in_ts;
    while (true) {
        var next: ?Interval = null;
        for (breaks) |b| {
            if (b.duration() == null or b.out_ts <= cursor) continue;
            const s = @max(b.in_ts, cursor);
            if (next == null or s < next.?.in_ts) next = .{ .in_ts = s, .out_ts = b.out_ts };
        }
        const b = next orelse break;
        if (b.in_ts >= out_ts) break;
        out_ts += b.out_ts - b.in_ts;
        cursor = b.out_ts;
    }
    return out_ts;
}

const testing = std.testing;
const expectEqual = testing.expectEqual;
test "clockIn - no breaks" {
    const shift_secs = 8 * time.s_per_hour;
    const in_ts: i64 = 1784503278;
    const out_ts = clockIn(shift_secs, in_ts, &.{});

    // 1784503278       -- In Timestamp
    //   + (8 * 3600)   -- Shift Length
    const expected_out_ts = 1784532078;

    try expectEqual(out_ts, expected_out_ts);
}

test "clockIn - 1 break" {
    const shift_secs = 8 * time.s_per_hour;
    const in_ts: i64 = 1784503278;
    const breaks: []const Interval = &.{
        .{
            .in_ts = 1784510478, // 1784503278 + (2 * 3600)
            .out_ts = 1784514078, // 1784503278 + (3 * 3600)
        },
    };

    const out_ts = clockIn(shift_secs, in_ts, breaks);

    // 1784503278       -- In Timestamp
    //   + (8 * 3600)   -- Shift Length
    //   + (1 * 3600)   -- Break 1
    const expected_out_ts = 1784535678;

    try expectEqual(out_ts, expected_out_ts);
}

test "clockIn - 3 breaks" {
    const shift_secs = 8 * time.s_per_hour;
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

    const out_ts = clockIn(shift_secs, in_ts, breaks);

    // 1784503278           -- In Timestamp
    //   + (8 * 3600)       -- Shift Length
    //   + (1 * 3600)       -- Break 1
    //   + (0.45 * 3600)    -- Break 2
    //   + (0.1 * 3600)     -- Break 3
    const expected_out_ts = 1784537658;

    try expectEqual(out_ts, expected_out_ts);
}

test "clockIn - overlapping breaks count once" {
    const h = time.s_per_hour;
    const in_ts: i64 = 0;
    const breaks: []const Interval = &.{
        .{ .in_ts = 2 * h, .out_ts = 4 * h },
        .{ .in_ts = 3 * h, .out_ts = 5 * h }, // overlaps the first
        .{ .in_ts = 3 * h, .out_ts = 4 * h }, // nested in both
    };

    // 3h of break time: 2h..5h
    try expectEqual(11 * h, clockIn(8 * h, in_ts, breaks));
}

test "clockIn - break before clock in is clipped" {
    const h = time.s_per_hour;
    const in_ts: i64 = 10 * h;
    const breaks: []const Interval = &.{
        .{ .in_ts = 8 * h, .out_ts = 9 * h }, // entirely before
        .{ .in_ts = 9 * h, .out_ts = 11 * h }, // 1h inside
    };

    try expectEqual(19 * h, clockIn(8 * h, in_ts, breaks));
}

test "clockIn - break after clock out is ignored" {
    const h = time.s_per_hour;
    const breaks: []const Interval = &.{
        .{ .in_ts = 9 * h, .out_ts = 10 * h },
    };

    try expectEqual(8 * h, clockIn(8 * h, 0, breaks));
}

test "clockIn - break extends shift into a later break" {
    const h = time.s_per_hour;
    const breaks: []const Interval = &.{
        .{ .in_ts = 4 * h, .out_ts = 5 * h }, // pushes clock out to 9h
        .{ .in_ts = 8 * h + 30 * 60, .out_ts = 9 * h }, // now inside the shift
    };

    try expectEqual(9 * h + 30 * 60, clockIn(8 * h, 0, breaks));
}

test "clockIn - invalid breaks are skipped" {
    const h = time.s_per_hour;
    const breaks: []const Interval = &.{
        .{ .in_ts = 5 * h, .out_ts = 4 * h },
        .{ .in_ts = 5 * h, .out_ts = 5 * h },
    };

    try expectEqual(8 * h, clockIn(8 * h, 0, breaks));
}
