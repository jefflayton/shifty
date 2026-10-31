//! Display formats every frontend shares, as `{f}` values.

const std = @import("std");
const Io = std.Io;

const Time = @import("time.zig").Time;

/// `2h 05m`, `45m`, `0m`. Negative durations show as `0m`.
pub const Dur = struct {
    secs: i64,

    pub fn format(d: Dur, w: *Io.Writer) Io.Writer.Error!void {
        const mins: u64 = @intCast(@divFloor(@max(d.secs, 0), 60));
        if (mins < 60) return w.print("{d}m", .{mins});
        try w.print("{d}h {d:0>2}m", .{ mins / 60, mins % 60 });
    }
};

pub fn dur(secs: i64) Dur {
    return .{ .secs = secs };
}

/// A time of day like `09:05 AM`.
pub const Clock = struct {
    local_ts: i64,

    pub fn format(c: Clock, w: *Io.Writer) Io.Writer.Error!void {
        const s = try Time.fromTs(c.local_ts).toStr();
        try w.writeAll(&s);
    }
};

/// The time of day at unix time `ts` in a zone `utc_offset_secs` from UTC.
pub fn clock(ts: i64, utc_offset_secs: i64) Clock {
    return .{ .local_ts = ts + utc_offset_secs };
}

/// `Fri Oct 30`.
pub const Date = struct {
    local_ts: i64,

    pub fn format(d: Date, w: *Io.Writer) Io.Writer.Error!void {
        const days = @divFloor(d.local_ts, std.time.s_per_day);
        const epoch_day: std.time.epoch.EpochDay = .{ .day = @intCast(days) };
        const md = epoch_day.calculateYearDay().calculateMonthDay();
        // 1970-01-01 was a Thursday.
        const weekdays = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
        const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
        try w.print("{s} {s} {d}", .{ weekdays[@intCast(@mod(days, 7))], months[md.month.numeric() - 1], md.day_index + 1 });
    }
};

/// The date at unix time `ts` in a zone `utc_offset_secs` from UTC.
pub fn date(ts: i64, utc_offset_secs: i64) Date {
    return .{ .local_ts = ts + utc_offset_secs };
}

/// Local midnight at or before `ts`, as a unix time.
pub fn dayStart(ts: i64, utc_offset_secs: i64) i64 {
    return ts - @mod(ts + utc_offset_secs, std.time.s_per_day);
}

const testing = std.testing;

test "dur" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0m", try std.fmt.bufPrint(&buf, "{f}", .{dur(59)}));
    try testing.expectEqualStrings("0m", try std.fmt.bufPrint(&buf, "{f}", .{dur(-600)}));
    try testing.expectEqualStrings("45m", try std.fmt.bufPrint(&buf, "{f}", .{dur(45 * 60)}));
    try testing.expectEqualStrings("2h 05m", try std.fmt.bufPrint(&buf, "{f}", .{dur(2 * 3600 + 5 * 60)}));
}

test "clock" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("08:00 AM", try std.fmt.bufPrint(&buf, "{f}", .{clock(15 * 3600, -7 * 3600)}));
}

test "date" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("Fri Oct 30", try std.fmt.bufPrint(&buf, "{f}", .{date(1793372400, 0)}));
    try testing.expectEqualStrings("Thu Jan 1", try std.fmt.bufPrint(&buf, "{f}", .{date(0, 0)}));
}

test "dayStart" {
    const h = std.time.s_per_hour;
    // 2026-10-30 15:00 UTC is 08:00 in UTC-7; local midnight is 07:00 UTC.
    const ts: i64 = 1793372400;
    try testing.expectEqual(ts - 8 * h, dayStart(ts, -7 * h));
    try testing.expectEqual(ts - 15 * h, dayStart(ts, 0));
}
