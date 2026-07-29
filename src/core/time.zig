const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const time = std.time;

const shift = @import("shift.zig");

pub const ParseError = error{ MissingComponent, InvalidInt, InvalidSuffix };

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

    pub fn fromStr(str: []const u8) ParseError!Time {
        // accept optional AM/PM suffix, case-insensitive, with optional space
        var rest = str;
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
        const min_str = s.next() orelse return ParseError.MissingComponent;

        var hour = std.fmt.parseInt(u8, hour_str, 10) catch return ParseError.InvalidInt;
        const min = std.fmt.parseInt(u8, min_str, 10) catch return ParseError.InvalidInt;

        if (is_pm) |pm| {
            if (pm) {
                if (hour != 12) hour += 12;
            } else {
                if (hour == 12) hour = 0;
            }
        }

        return .{ .hour = hour, .min = min };
    }
};

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

pub fn calc(alloc: Allocator, shift_secs: i64, start: Time, breaks: []const TimeInterval) Allocator.Error!Time {
    const in_ts = start.toTs();

    const converted = try alloc.alloc(shift.Interval, breaks.len);
    defer alloc.free(converted);

    for (breaks, 0..breaks.len) |b, i| {
        converted[i] = b.toInterval();
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
