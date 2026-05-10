const std = @import("std");

pub const Time = struct {
    hour: u8,
    min: u16,
};
pub const Interval = struct {
    start: Time,
    end: Time,
};

pub const Shift = struct {
    start: []const u8,
    lunch_start: ?[]const u8,
    lunch_end: ?[]const u8,
};

const ParseError = error{ MissingComponent, InvalidInt, InvalidSuffix };
pub fn parseStrToTime(str: []const u8) ParseError!Time {
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

pub fn parseTimeToStr(time: Time) ![8]u8 {
    var buf: [8]u8 = undefined;

    const hour12: u8 = switch (time.hour) {
        0 => 12,
        1...12 => time.hour,
        else => time.hour - 12,
    };
    const suffix = if (time.hour < 12) "AM" else "PM";

    var writer: std.Io.Writer = .fixed(&buf);
    try writer.print("{d:0>2}:{d:0>2} {s}", .{ hour12, time.min, suffix });

    return buf;
}

pub fn calc(start: Time, max_mins: u16, lunch: ?Interval) Time {
    const lunch_mins: u16 = if (lunch) |l| blk: {
        const start_mins = @as(u16, l.start.hour) * 60 + l.start.min;
        const end_mins = @as(u16, l.end.hour) * 60 + l.end.min;
        break :blk end_mins - start_mins;
    } else 0;

    const start_mins = @as(u16, start.hour) * 60 + start.min;
    const total_mins = start_mins + max_mins + lunch_mins;

    return .{
        .hour = @intCast(@mod(@divFloor(total_mins, 60), 24)),
        .min = @intCast(@mod(total_mins, 60)),
    };
}

test "parseStrToTime" {
    const cases = .{
        .{ "09:00", Time{ .hour = 9, .min = 0 } },
        .{ "09:00 AM", Time{ .hour = 9, .min = 0 } },
        .{ "09:00AM", Time{ .hour = 9, .min = 0 } },
        .{ "12:00 PM", Time{ .hour = 12, .min = 0 } },
        .{ "12:00 AM", Time{ .hour = 0, .min = 0 } },
        .{ "01:00 PM", Time{ .hour = 13, .min = 0 } },
        .{ "11:59 PM", Time{ .hour = 23, .min = 59 } },
    };
    inline for (cases) |c| {
        const time = try parseStrToTime(c[0]);
        try std.testing.expectEqual(c[1], time);
    }
}

test "parseTimeToStr" {
    const cases = .{
        .{ Time{ .hour = 0, .min = 0 }, "12:00 AM" },
        .{ Time{ .hour = 9, .min = 5 }, "09:05 AM" },
        .{ Time{ .hour = 12, .min = 0 }, "12:00 PM" },
        .{ Time{ .hour = 18, .min = 0 }, "06:00 PM" },
        .{ Time{ .hour = 23, .min = 59 }, "11:59 PM" },
    };
    inline for (cases) |c| {
        const buf = try parseTimeToStr(c[0]);
        try std.testing.expectEqualStrings(&buf, c[1]);
    }
}

test "calc" {
    const cases = .{
        .{
            .{
                Time{ .hour = 9, .min = 0 },
                480,
                Interval{ .start = .{ .hour = 12, .min = 0 }, .end = .{ .hour = 13, .min = 0 } },
            },
            Time{ .hour = 18, .min = 0 },
        },
    };

    inline for (cases) |c| {
        const out = @call(.auto, calc, c[0]);
        try std.testing.expectEqual(out, c[1]);
    }
}
