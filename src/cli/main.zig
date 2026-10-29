const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const core = @import("core");
const time = core.time;

const usage =
    \\Usage: shifty [options]
    \\
    \\Calculate your clock-out time.
    \\
    \\Options:
    \\  -s, --start <time>         Clock-in time (default: now)
    \\                             e.g. 9:00, 9am, 21:30, "9:30 PM"
    \\  -l, --length <duration>    Shift length (default: 8h)
    \\                             e.g. 8, 7.5, 7:30, 7h30m
    \\  -b, --break <start> <end>  Add a break; repeatable
    \\                             e.g. -b 12pm 12:30pm
    \\  -h, --help                 Show this help
    \\
;

const default_shift_secs = 8 * std.time.s_per_hour;

const Options = struct {
    start: ?time.Time = null,
    shift_secs: i64 = default_shift_secs,
    breaks: []const time.TimeInterval = &.{},
    help: bool = false,
};

/// Describes the argument that failed to parse, for the error message.
const Diag = struct {
    arg: []const u8 = "",
    value: []const u8 = "",
};

const ArgError = error{ MissingArgument, UnknownArgument, InvalidValue } || Allocator.Error;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buf: [256]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [256]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(arena);

    var diag: Diag = .{};
    const opts = parseArgs(arena, args[1..], &diag) catch |err| {
        switch (err) {
            ArgError.MissingArgument => try stderr.print("shifty: {s} requires a value\n", .{diag.arg}),
            ArgError.UnknownArgument => try stderr.print("shifty: unknown argument '{s}'\n", .{diag.arg}),
            ArgError.InvalidValue => try stderr.print("shifty: invalid value '{s}' for {s}\n", .{ diag.value, diag.arg }),
            else => return err,
        }
        try stderr.print("\n{s}", .{usage});
        try stderr_writer.flush();
        std.process.exit(2);
    };

    if (opts.help) {
        try stdout.writeAll(usage);
        return stdout_writer.flush();
    }

    const start = opts.start orelse core.local.now(io);
    const out = try time.calc(init.gpa, opts.shift_secs, start, opts.breaks);
    const out_str = try out.toStr();
    try stdout.print("Clock Out: {s}\n", .{&out_str});
    try stdout_writer.flush();
}

fn isMeridiem(s: []const u8) bool {
    return std.ascii.eqlIgnoreCase(s, "am") or std.ascii.eqlIgnoreCase(s, "pm");
}

/// Consumes a time argument at `args[i.*]`, joining a following standalone
/// `AM`/`PM` argument so `-s 9:30 PM` works without quoting.
fn takeTime(arena: Allocator, args: []const [:0]const u8, i: *usize, diag: *Diag) ArgError!time.Time {
    if (i.* >= args.len) return ArgError.MissingArgument;
    var str: []const u8 = args[i.*];
    i.* += 1;
    if (i.* < args.len and isMeridiem(args[i.*])) {
        str = try std.fmt.allocPrint(arena, "{s} {s}", .{ str, args[i.*] });
        i.* += 1;
    }
    diag.value = str;
    return time.Time.fromStr(str) catch ArgError.InvalidValue;
}

fn parseArgs(arena: Allocator, args: []const [:0]const u8, diag: *Diag) ArgError!Options {
    var opts: Options = .{};
    var breaks: std.ArrayList(time.TimeInterval) = .empty;

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        diag.arg = arg;
        i += 1;
        if (eqlAny(arg, &.{ "-h", "--help" })) {
            opts.help = true;
        } else if (eqlAny(arg, &.{ "-s", "--start" })) {
            opts.start = try takeTime(arena, args, &i, diag);
        } else if (eqlAny(arg, &.{ "-l", "--length" })) {
            if (i >= args.len) return ArgError.MissingArgument;
            diag.value = args[i];
            opts.shift_secs = time.parseDuration(args[i]) catch return ArgError.InvalidValue;
            i += 1;
        } else if (eqlAny(arg, &.{ "-b", "--break" })) {
            const start = try takeTime(arena, args, &i, diag);
            const end = try takeTime(arena, args, &i, diag);
            try breaks.append(arena, .{ .start = start, .end = end });
        } else {
            return ArgError.UnknownArgument;
        }
    }

    opts.breaks = breaks.items;
    return opts;
}

fn eqlAny(s: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

const testing = std.testing;

fn testParse(args: []const [:0]const u8) ArgError!Options {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    var opts = try parseArgs(arena.allocator(), args, &diag);
    opts.breaks = &.{}; // owned by the arena
    return opts;
}

test "parseArgs - defaults" {
    const opts = try testParse(&.{});
    try testing.expectEqual(null, opts.start);
    try testing.expectEqual(default_shift_secs, opts.shift_secs);
}

test "parseArgs - start with separate meridiem" {
    const opts = try testParse(&.{ "-s", "9:30", "PM", "-l", "7.5" });
    try testing.expectEqual(time.Time{ .hour = 21, .min = 30 }, opts.start.?);
    try testing.expectEqual(7 * 3600 + 1800, opts.shift_secs);
}

test "parseArgs - breaks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const opts = try parseArgs(arena.allocator(), &.{ "-b", "12pm", "12:30", "pm", "--break", "15:00", "15:15" }, &diag);
    try testing.expectEqual(2, opts.breaks.len);
    try testing.expectEqual(time.Time{ .hour = 12, .min = 30 }, opts.breaks[0].end);
    try testing.expectEqual(time.Time{ .hour = 15, .min = 15 }, opts.breaks[1].end);
}

test "parseArgs - errors" {
    try testing.expectError(ArgError.MissingArgument, testParse(&.{"-s"}));
    try testing.expectError(ArgError.MissingArgument, testParse(&.{ "-b", "12pm" }));
    try testing.expectError(ArgError.UnknownArgument, testParse(&.{"-x"}));
    try testing.expectError(ArgError.InvalidValue, testParse(&.{ "-s", "25:00" }));
    try testing.expectError(ArgError.InvalidValue, testParse(&.{ "-l", "abc" }));
}
