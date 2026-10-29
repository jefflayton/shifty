const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const time = std.time;

const shift = @import("shift.zig");

pub const ParseError = error{ MissingComponent, InvalidInt, InvalidSuffix, OutOfRange };

pub const Time = struct {
    hour: u8,
    min: u16,

    pub fn toTs(t: Time) i64 {
        return (@as(i64, t.hour) * time.s_per_hour) + (@as(i64, t.min) * time.s_per_min);
    }

    pub fn fromTs(ts: i64) Time {
        const hour: u8 = @intCast(@mod(@divFloor(ts, time.s_per_hour), 24));
        const min: u16 = @intCast(@mod(@divFloor(ts, 60), 60));

        return .{
            .hour = hour,
            .min = min,
        };
    }

    pub fn toStr(t: Time) Io.Writer.Error![8]u8 {
        const hour12: u8 = switch (t.hour) {
            0 => 12,
            1...12 => t.hour,
            else => t.hour - 12,
        };
        const suffix = if (t.hour < 12) "AM" else "PM";

        var buf: [8]u8 = undefined;
        var writer: Io.Writer = .fixed(&buf);
        try writer.print("{d:0>2}:{d:0>2} {s}", .{ hour12, t.min, suffix });
        return buf;
    }

    /// Parses `H`, `H:MM`, or either with an `AM`/`PM` suffix (case-insensitive,
    /// optional space), e.g. `9`, `09:00`, `9am`, `9:30 PM`, `21:30`.
    pub fn fromStr(str: []const u8) ParseError!Time {
        var rest = std.mem.trim(u8, str, " \t");
        var is_pm: ?bool = null;

        const upper = std.ascii.toUpper;
        if (rest.len >= 2) {
            const tail = rest[rest.len - 2 ..];
            if (upper(tail[0]) == 'A' and upper(tail[1]) == 'M') {
                is_pm = false;
                rest = std.mem.trim(u8, rest[0 .. rest.len - 2], " ");
            } else if (upper(tail[0]) == 'P' and upper(tail[1]) == 'M') {
                is_pm = true;
                rest = std.mem.trim(u8, rest[0 .. rest.len - 2], " ");
            }
        }

        var s = std.mem.splitScalar(u8, rest, ':');
        const hour_str = s.next() orelse return ParseError.MissingComponent;
        const min_str = s.next() orelse "0";
        if (s.next() != null) return ParseError.InvalidSuffix;
        if (hour_str.len == 0 or min_str.len == 0) return ParseError.MissingComponent;

        var hour = std.fmt.parseInt(u8, hour_str, 10) catch return ParseError.InvalidInt;
        const min = std.fmt.parseInt(u8, min_str, 10) catch return ParseError.InvalidInt;
        if (min > 59) return ParseError.OutOfRange;

        if (is_pm) |pm| {
            if (hour < 1 or hour > 12) return ParseError.OutOfRange;
            if (pm) {
                if (hour != 12) hour += 12;
            } else {
                if (hour == 12) hour = 0;
            }
        } else if (hour > 23) return ParseError.OutOfRange;

        return .{ .hour = hour, .min = min };
    }
};

/// Parses a shift length into seconds. Accepts decimal hours (`8`, `7.5`),
/// `H:MM` (`7:30`), and unit forms (`7h`, `45m`, `7h30m`, `7h 30m`).
pub fn parseDuration(str: []const u8) ParseError!i64 {
    const s = std.mem.trim(u8, str, " \t");
    if (s.len == 0) return ParseError.MissingComponent;

    if (std.mem.indexOfScalar(u8, s, ':')) |i| {
        const h = std.fmt.parseInt(u16, s[0..i], 10) catch return ParseError.InvalidInt;
        const m = std.fmt.parseInt(u8, s[i + 1 ..], 10) catch return ParseError.InvalidInt;
        if (m > 59) return ParseError.OutOfRange;
        return @as(i64, h) * time.s_per_hour + @as(i64, m) * time.s_per_min;
    }

    const last = std.ascii.toLower(s[s.len - 1]);
    if (last != 'h' and last != 'm') {
        const hours = std.fmt.parseFloat(f64, s) catch return ParseError.InvalidInt;
        if (!(hours >= 0) or hours > 24 * 365) return ParseError.OutOfRange;
        return @intFromFloat(@round(hours * time.s_per_hour));
    }

    // unit form: one or more `<number><h|m>` groups
    var total: i64 = 0;
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and s[i] == ' ') i += 1;
        const num_start = i;
        while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '.')) i += 1;
        if (i == num_start or i == s.len) return ParseError.MissingComponent;
        const n = std.fmt.parseFloat(f64, s[num_start..i]) catch return ParseError.InvalidInt;
        if (n > 24 * 365 * 60) return ParseError.OutOfRange;
        const unit: f64 = switch (std.ascii.toLower(s[i])) {
            'h' => time.s_per_hour,
            'm' => time.s_per_min,
            else => return ParseError.InvalidSuffix,
        };
        total += @intFromFloat(@round(n * unit));
        i += 1;
    }
    return total;
}

pub const TimeInterval = struct {
    start: Time,
    end: Time,

    pub fn toInterval(b: TimeInterval) shift.Interval {
        return .{
            .in_ts = b.start.toTs(),
            .out_ts = b.end.toTs(),
        };
    }

    pub fn fromInterval(interval: shift.Interval) TimeInterval {
        return .{
            .start = Time.fromTs(interval.in_ts),
            .end = Time.fromTs(interval.out_ts),
        };
    }
};

/// Computes the clock-out time-of-day. Times are wall-clock times on a single
/// shift: a break whose end is before its start wraps past midnight, and a
/// break that ends before `start` is taken to fall on the next day.
pub fn calc(alloc: Allocator, shift_secs: i64, start: Time, breaks: []const TimeInterval) Allocator.Error!Time {
    const in_ts = start.toTs();

    const converted = try alloc.alloc(shift.Interval, breaks.len);
    defer alloc.free(converted);

    for (breaks, 0..breaks.len) |b, i| {
        var interval = b.toInterval();
        if (interval.out_ts < interval.in_ts) interval.out_ts += time.s_per_day;
        if (interval.out_ts <= in_ts) {
            interval.in_ts += time.s_per_day;
            interval.out_ts += time.s_per_day;
        }
        converted[i] = interval;
    }

    const out_ts = shift.clockIn(shift_secs, in_ts, converted);
    return Time.fromTs(out_ts);
}

const testing = std.testing;
const expectEqual = testing.expectEqual;
test "Time.fromStr" {
    const Case = struct { in: []const u8, out: Time };
    const cases = [_]Case{
        .{ .in = "09:00", .out = .{ .hour = 9, .min = 0 } },
        .{ .in = "09:00 AM", .out = .{ .hour = 9, .min = 0 } },
        .{ .in = "09:00AM", .out = .{ .hour = 9, .min = 0 } },
        .{ .in = "12:00 PM", .out = .{ .hour = 12, .min = 0 } },
        .{ .in = "12:00 AM", .out = .{ .hour = 0, .min = 0 } },
        .{ .in = "01:00 PM", .out = .{ .hour = 13, .min = 0 } },
        .{ .in = "11:59 PM", .out = .{ .hour = 23, .min = 59 } },
    };
    for (cases) |c| {
        const out = try Time.fromStr(c.in);
        try std.testing.expectEqual(c.out, out);
    }
}

test "Time.toStr" {
    const Case = struct { in: Time, out: []const u8 };

    const cases = [_]Case{
        .{ .in = .{ .hour = 0, .min = 0 }, .out = "12:00 AM" },
        .{ .in = .{ .hour = 9, .min = 5 }, .out = "09:05 AM" },
        .{ .in = .{ .hour = 12, .min = 0 }, .out = "12:00 PM" },
        .{ .in = .{ .hour = 18, .min = 0 }, .out = "06:00 PM" },
        .{ .in = .{ .hour = 23, .min = 59 }, .out = "11:59 PM" },
    };
    for (cases) |c| {
        const buf = try Time.toStr(c.in);
        try std.testing.expectEqualStrings(c.out, &buf);
    }
}

test "calc" {
    const Case = struct {
        start: Time,
        shift_secs: i64,
        breaks: []const TimeInterval,
        out: Time,
    };
    const cases = [_]Case{
        .{
            .shift_secs = 8 * time.s_per_hour,
            .start = .{ .hour = 9, .min = 0 },
            .breaks = &.{
                .{
                    .start = .{ .hour = 12, .min = 0 },
                    .end = .{ .hour = 13, .min = 0 },
                },
            },
            .out = .{ .hour = 18, .min = 0 },
        },
    };

    for (cases) |c| {
        const out = try calc(testing.allocator, c.shift_secs, c.start, c.breaks);
        try expectEqual(c.out, out);
    }
}

test "calc - overnight" {
    const Case = struct {
        start: Time,
        shift_secs: i64,
        breaks: []const TimeInterval,
        out: Time,
    };
    const cases = [_]Case{
        // clock out wraps past midnight
        .{
            .shift_secs = 8 * time.s_per_hour,
            .start = .{ .hour = 22, .min = 0 },
            .breaks = &.{},
            .out = .{ .hour = 6, .min = 0 },
        },
        // break spans midnight
        .{
            .shift_secs = 8 * time.s_per_hour,
            .start = .{ .hour = 20, .min = 0 },
            .breaks = &.{
                .{ .start = .{ .hour = 23, .min = 30 }, .end = .{ .hour = 0, .min = 30 } },
            },
            .out = .{ .hour = 5, .min = 0 },
        },
        // break after midnight, earlier in the day than clock in
        .{
            .shift_secs = 8 * time.s_per_hour,
            .start = .{ .hour = 22, .min = 0 },
            .breaks = &.{
                .{ .start = .{ .hour = 2, .min = 0 }, .end = .{ .hour = 2, .min = 30 } },
            },
            .out = .{ .hour = 6, .min = 30 },
        },
        // break spanning clock in is clipped, not moved to tomorrow
        .{
            .shift_secs = 8 * time.s_per_hour,
            .start = .{ .hour = 9, .min = 0 },
            .breaks = &.{
                .{ .start = .{ .hour = 8, .min = 30 }, .end = .{ .hour = 9, .min = 30 } },
            },
            .out = .{ .hour = 17, .min = 30 },
        },
    };

    for (cases) |c| {
        const out = try calc(testing.allocator, c.shift_secs, c.start, c.breaks);
        try expectEqual(c.out, out);
    }
}

test "Time.fromStr - short forms" {
    const Case = struct { in: []const u8, out: Time };
    const cases = [_]Case{
        .{ .in = "9", .out = .{ .hour = 9, .min = 0 } },
        .{ .in = "9am", .out = .{ .hour = 9, .min = 0 } },
        .{ .in = "9 PM", .out = .{ .hour = 21, .min = 0 } },
        .{ .in = " 21:30 ", .out = .{ .hour = 21, .min = 30 } },
        .{ .in = "12am", .out = .{ .hour = 0, .min = 0 } },
    };
    for (cases) |c| {
        try expectEqual(c.out, try Time.fromStr(c.in));
    }
}

test "Time.fromStr - errors" {
    const Case = struct { in: []const u8, err: ParseError };
    const cases = [_]Case{
        .{ .in = "", .err = ParseError.MissingComponent },
        .{ .in = "9:", .err = ParseError.MissingComponent },
        .{ .in = "pm", .err = ParseError.MissingComponent },
        .{ .in = "ab:cd", .err = ParseError.InvalidInt },
        .{ .in = "24:00", .err = ParseError.OutOfRange },
        .{ .in = "9:60", .err = ParseError.OutOfRange },
        .{ .in = "13:00 PM", .err = ParseError.OutOfRange },
        .{ .in = "0:30 AM", .err = ParseError.OutOfRange },
        .{ .in = "9:00:00", .err = ParseError.InvalidSuffix },
    };
    for (cases) |c| {
        try testing.expectError(c.err, Time.fromStr(c.in));
    }
}

test "parseDuration" {
    const Case = struct { in: []const u8, out: i64 };
    const h = time.s_per_hour;
    const m = time.s_per_min;
    const cases = [_]Case{
        .{ .in = "8", .out = 8 * h },
        .{ .in = "7.5", .out = 7 * h + 30 * m },
        .{ .in = "7:30", .out = 7 * h + 30 * m },
        .{ .in = "7h", .out = 7 * h },
        .{ .in = "45m", .out = 45 * m },
        .{ .in = "7h30m", .out = 7 * h + 30 * m },
        .{ .in = "7H 30M", .out = 7 * h + 30 * m },
        .{ .in = " 10 ", .out = 10 * h },
    };
    for (cases) |c| {
        try expectEqual(c.out, try parseDuration(c.in));
    }
}

test "parseDuration - errors" {
    const Case = struct { in: []const u8, err: ParseError };
    const cases = [_]Case{
        .{ .in = "", .err = ParseError.MissingComponent },
        .{ .in = "abc", .err = ParseError.InvalidInt },
        .{ .in = "-1", .err = ParseError.OutOfRange },
        .{ .in = "7:75", .err = ParseError.OutOfRange },
        .{ .in = "h", .err = ParseError.MissingComponent },
        .{ .in = "7x30m", .err = ParseError.InvalidSuffix },
    };
    for (cases) |c| {
        try testing.expectError(c.err, parseDuration(c.in));
    }
}
