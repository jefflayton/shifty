const std = @import("std");

const time = @import("time.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = init.minimal.args.iterate();
    const max_mins = 480;
    const shift = try parseArgs(&args);

    const start = try time.parseStrToTime(shift.start);

    var lunch: ?time.Interval = null;
    if (shift.lunch_start != null and shift.lunch_end != null) {
        lunch = .{
            .start = try time.parseStrToTime(shift.lunch_start.?),
            .end = try time.parseStrToTime(shift.lunch_end.?),
        };
    }

    var stdout_buf: [64]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    var stdout = &stdout_writer.interface;

    const out = time.calc(start, max_mins, lunch);
    const out_str = try time.parseTimeToStr(out);
    try stdout.print("Clock Out: {s}\n", .{&out_str});
    try stdout_writer.flush();
}

const ArgError = error{ MissingArgument, UnknownArgument };

fn isMeridiem(s: []const u8) bool {
    if (s.len != 2) return false;
    const u = std.ascii.toUpper;
    return (u(s[0]) == 'A' or u(s[0]) == 'P') and u(s[1]) == 'M';
}

fn nextTimeArg(args: *std.process.Args.Iterator, buf: []u8) ArgError![]u8 {
    const t = args.next() orelse return ArgError.MissingArgument;
    if (isMeridiem(t[t.len - 2 ..])) {
        @memcpy(buf[0..t.len], t);
        return buf[0..t.len];
    }
    if (args.next()) |next| {
        if (isMeridiem(next)) {
            const joined = std.fmt.bufPrint(buf, "{s} {s}", .{ t, next }) catch return ArgError.MissingArgument;
            return joined;
        }
        return ArgError.UnknownArgument;
    }
    @memcpy(buf[0..t.len], t);
    return buf[0..t.len];
}

fn parseArgs(args: *std.process.Args.Iterator) ArgError!time.Shift {
    var start: ?[]const u8 = null;
    var lunch_start: ?[]const u8 = null;
    var lunch_end: ?[]const u8 = null;

    var start_buf: [16]u8 = undefined;
    var ls_buf: [16]u8 = undefined;
    var le_buf: [16]u8 = undefined;

    _ = args.next();
    while (args.next()) |arg| {
        if (arg.len < 2 or arg[0] != '-') return ArgError.UnknownArgument;
        switch (arg[1]) {
            's' => start = try nextTimeArg(args, &start_buf),
            'l' => {
                lunch_start = try nextTimeArg(args, &ls_buf);
                lunch_end = try nextTimeArg(args, &le_buf);
            },
            else => return ArgError.UnknownArgument,
        }
    }

    return .{
        .start = start orelse return ArgError.MissingArgument,
        .lunch_start = lunch_start,
        .lunch_end = lunch_end,
    };
}
