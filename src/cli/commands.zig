//! Subcommands backed by the shared store. Without one, `shifty` is the
//! clock-out calculator in main.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const core = @import("core");
const Uuid = core.Uuid;
const local = core.local;
const time = core.time;
const fmt = core.fmt;
const clock = fmt.clock;
const dur = fmt.dur;
const store = @import("store");
const Names = store.report.Names;
const Store = store.Store;
const sheet = store.sheet;
const integrations = @import("integrations");
const situ = integrations.situ;
const place = integrations.place;
const here_ = integrations.here;
const rex_ = integrations.rex;
const clock_link = integrations.clock_link;
const tui = @import("tui");

pub const usage =
    \\Commands:
    \\  tui                        Open the terminal UI
    \\  status                     What's running: shift, break, lunch, timer
    \\  in [-s <time>] [-l <len>] [--open]
    \\                             Clock in (default: now, 8h), with the
    \\                             day's scheduled breaks. --open opens
    \\                             the clock link
    \\  out [--open]               Clock out
    \\  break [--open]             Start or end a break; --open opens the
    \\                             clock link for lunch
    \\  break plan <start> <end> [-d <day>] [-n <name>]
    \\                             Plan a one-off break, like the dentist:
    \\                             it goes on that day's shift. Days:
    \\                             today, tomorrow, mon...sun (the next
    \\                             one), or 2026-11-14
    \\  break unplan <start> [-d <day>]
    \\                             Drop the one-off break starting then
    \\  breaks [<day>] [--last]    The week's breaks by day, lunch marked,
    \\                             and the one-off breaks still to come
    \\  sheet [<day>] [--last] [--org <name>]
    \\                             The week's timesheet: shifts, breaks,
    \\                             lunch, and time, with totals. --org
    \\                             shows one organization's
    \\  goal [<hours>|off]         Show the weekly hours goal and what's
    \\                             left of it, set it (20h, 20, 37:30),
    \\                             or turn it off
    \\  add <start> <end> [<project>[/<workspace>]] [-n <note>] [-d <day>]
    \\                             Record time after the fact
    \\  add <start> <end> [<project>[/<workspace>]] -m <title> [-d <day>]
    \\                             Record a meeting: worked time on the
    \\                             project, kept apart and titled
    \\  add --shift <start> <end> [-d <day>]
    \\                             Record a shift you forgot to clock
    \\  add --break <start> <end> [-d <day>]
    \\                             Add a break to that day's shift
    \\                             Days: today, yesterday, mon...sun (the
    \\                             last one), or 2026-11-09
    \\  start [<project>[/<workspace>]] [-n <note>]
    \\                             Track time. With no project, use the
    \\                             project linked to the repo or folder
    \\                             you're in, if any
    \\  start [<project>[/<workspace>]] -m <title>
    \\                             Track a meeting until the next start
    \\                             or stop
    \\  meetings [<day>] [--last]  The week's meetings, by day
    \\  stop                       Stop tracking
    \\  log [--week] [--org <name>]
    \\                             Time by project, today or the last 7
    \\                             days, personal time apart
    \\  orgs                       List organizations: who the time is for
    \\  org add <name> [--auto] [--color <#rrggbb>]
    \\                             Add one. It's on the shift you share
    \\                             with the others, or with --auto it has
    \\                             none: the menu bar tracks its projects
    \\                             from the window you're in, and its time
    \\                             is personal, never worked
    \\  org rename <name> <new name>
    \\  org tracking <name> <shift|auto>
    \\  org color <name> <#rrggbb|none>
    \\  org delete <name> [--to <org>]
    \\                             Its projects and their time move to
    \\                             <org> (default: the first on the shift)
    \\  projects                   List projects by organization, and
    \\                             their workspaces
    \\  project add <name> [--org <name>] [--client <name>] [--color <#rrggbb>]
    \\  project move <name> <org>  Move a project, with its time
    \\  project rename <name> <new name>
    \\  project color <name> <#rrggbb|none>
    \\  project delete <name>     Its time stays, unassigned
    \\  workspace add <project> <name>
    \\  clients                    List clients
    \\  client add <name>
    \\  link <project>[/<workspace>]
    \\                             Link the repo or folder you're in to a
    \\                             project: by its Situ ids, else its git
    \\                             remote, else its path. A repo can link
    \\                             to several projects
    \\  link --app <bundle id> <project>[/<workspace>]
    \\                             Link a macOS app, for the menu bar's
    \\                             auto-switch
    \\  unlink [<project>]         Remove here's link to <project>, or all
    \\                             of here's links
    \\  unlink --app <bundle id> [<project>]
    \\                             The same for an app
    \\  keyword add <project>[/<workspace>] <word>...
    \\                             A window titled with <word> (a Rex
    \\                             session or tab, say) is <project>'s
    \\  keyword remove <word>...   Stop matching <word>
    \\  keywords                   List keywords and their projects
    \\  hook <fish|zsh|bash|nvim>  Print a prompt hook that tells the menu
    \\                             bar which folder your terminal is in
    \\  hook rex                   Print a Lua script for `rex do` that
    \\                             tells the menu bar which Rex tab and
    \\                             session you're on, remote hosts too
    \\  here [<dir>] [--pid <pid>]  What the hook runs: record <dir>
    \\                             (default: this one) for the shell <pid>
    \\  rex --session <label> [--window <label>] [--server <host>]
    \\                             What the Rex script runs: record the
    \\                             Rex tab and session you're on
    \\
;

const Command = enum { tui, status, in, out, @"break", breaks, sheet, goal, add, start, stop, meetings, log, orgs, org, projects, project, workspace, clients, client, link, unlink, keyword, keywords, hook, here, rex };

pub fn isCommand(arg: []const u8) bool {
    return std.meta.stringToEnum(Command, arg) != null;
}

/// A mistake the user can fix. The message is already on stderr.
pub const Error = error{Reported};

const default_shift_secs = 8 * std.time.s_per_hour;

const Ctx = struct {
    io: Io,
    arena: Allocator,
    env: *const std.process.Environ.Map,
    out: *Io.Writer,
    err: *Io.Writer,
    db: Store,
    now: local.Stamp,
    tz_buf: local.TzBuf,

    fn fail(c: *Ctx, comptime msg: []const u8, args: anytype) Error {
        c.err.print("shifty: " ++ msg ++ "\n", args) catch {};
        return error.Reported;
    }
};

/// Runs `args[0]`, which `isCommand` accepted.
pub fn run(init: std.process.Init, out: *Io.Writer, err: *Io.Writer, args: []const [:0]const u8) !void {
    const arena = init.arena.allocator();
    var c: Ctx = .{
        .io = init.io,
        .arena = arena,
        .env = init.environ_map,
        .out = out,
        .err = err,
        .db = undefined,
        .now = undefined,
        .tz_buf = undefined,
    };
    c.now = .now(c.io, c.env.get("TZ"), &c.tz_buf);

    const command = std.meta.stringToEnum(Command, args[0]).?;
    const rest = args[1..];
    switch (command) {
        // Hot paths that run at every prompt: no database.
        .hook => return hook(&c, rest),
        .here => return here(&c, rest),
        .rex => return rex(&c, rest),
        // Opens the database itself, before it takes over the terminal.
        .tui => {
            try noArgs(&c, "tui", rest);
            return tui.run(init);
        },
        else => {},
    }

    const path = store.defaultPath(arena, c.env) catch |e| switch (e) {
        error.NoHome => return c.fail("$HOME isn't set; set $SHIFTY_DB to choose where the database goes", .{}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    c.db = Store.open(c.io, path) catch |e| switch (e) {
        error.SchemaTooNew => return c.fail("{s} was written by a newer Shifty; update this one", .{path}),
        else => return c.fail("can't open {s}: {t}", .{ path, e }),
    };
    defer c.db.deinit();
    _ = try c.db.closeStaleShift(arena, c.now.ts);

    switch (command) {
        .status => try status(&c, rest),
        .in => try clockIn(&c, rest),
        .out => try clockOut(&c, rest),
        .@"break" => try breakCommand(&c, rest),
        .breaks => try listBreaks(&c, rest),
        .sheet => try timesheet(&c, rest),
        .goal => try goal(&c, rest),
        .add => try add(&c, rest),
        .start => try start(&c, rest),
        .stop => try stop(&c, rest),
        .meetings => try meetings(&c, rest),
        .log => try log(&c, rest),
        .orgs => try listOrganizations(&c, rest),
        .org => try organization(&c, rest),
        .projects => try listProjects(&c, rest),
        .project => try project(&c, rest),
        .workspace => try workspace(&c, rest),
        .clients => try listClients(&c, rest),
        .client => try client(&c, rest),
        .link => try link(&c, rest),
        .unlink => try unlink(&c, rest),
        .keyword => try keyword(&c, rest),
        .keywords => try listKeywords(&c, rest),
        .hook, .here, .rex, .tui => unreachable,
    }
}

// ── Shift ───────────────────────────────────────────────────────────────────

fn status(c: *Ctx, args: []const [:0]const u8) !void {
    try noArgs(c, "status", args);
    const now = c.now.ts;

    if (try c.db.currentShift(c.arena)) |shift| {
        const brks = try c.db.breaks(c.arena, shift.id);
        const lunch = try sheet.Lunch.load(&c.db, c.arena);
        const plan = if (lunch) |l| try l.planFor(c.arena, shift, brks, now) else null;
        const out = try sheet.clockOut(c.arena, shift, brks, lunch, now);
        try c.out.print("On shift since {f}. Clock out at {f}", .{ clock(shift.in_ts, shift.utc_offset_secs), clock(out, c.now.utc_offset_secs) });
        if (out > now) try c.out.print(" ({f} left", .{dur(out - now)}) else try c.out.print(" ({f} over", .{dur(now - out)});
        const ahead = if (lunch) |l| l.ahead(plan, now) else 0;
        if (ahead > 0) try c.out.print(", {f} of it lunch to come", .{dur(ahead)});
        try c.out.writeAll(").\n");
        if (running(brks)) |b| {
            const what = if (plan) |p| (if (p.isLunch(b.in_ts)) "lunch" else "break") else "break";
            try c.out.print("On {s} since {f} ({f}).\n", .{ what, clock(b.in_ts, shift.utc_offset_secs), dur(now - b.in_ts) });
        }
        if (plan) |p| try lunchStatus(c, p, lunch.?, shift.utc_offset_secs);
    } else try c.out.writeAll("Off shift.\n");
    try weekGoalStatus(c);

    if (try c.db.runningEntry(c.arena)) |e| {
        try c.out.print("Tracking {s} since {f} ({f})", .{ try label(c, e.project_id, e.workspace_id), clock(e.in_ts, e.utc_offset_secs), dur(now - e.in_ts) });
        if (e.kind == .meeting) {
            try c.out.print(", in the meeting {s}", .{e.note orelse "untitled"});
        } else if (e.note) |n| try c.out.print(": {s}", .{n});
        try c.out.writeAll(".\n");
    } else try c.out.writeAll("Not tracking.\n");
}

/// This week against the weekly goal, if there is one.
fn weekGoalStatus(c: *Ctx) !void {
    const first = sheet.weekStart(c.now.ts, c.now.utc_offset_secs, try sheet.weekStartDay(&c.db, c.arena));
    const w: sheet.Week = try .load(&c.db, c.arena, sheet.weekDays(first, local.utcOffset));
    const g = try w.goal(c.arena, c.now.ts) orelse return;
    try c.out.print("This week: {f} of your {f} goal", .{ dur(g.worked), dur(g.secs) });
    if (g.isMet()) {
        try c.out.writeAll(", met");
        if (g.over() >= 60) try c.out.print(" ({f} over)", .{dur(g.over())});
        return c.out.writeAll(".\n");
    }
    try c.out.print(", {f} left", .{dur(g.left())});
    if (g.leftAfterClockOut()) |after| {
        if (after == 0) {
            try c.out.print("; you'll reach it at {f}, by today's clock out", .{clock(g.meets_at.?, c.now.utc_offset_secs)});
        } else try c.out.print("; {f} after today's clock out", .{dur(after)});
    }
    try c.out.writeAll(".\n");
}

/// `shifty goal`: show, set, or turn off the weekly hours goal.
fn goal(c: *Ctx, args: []const [:0]const u8) !void {
    if (args.len > 1) return c.fail("goal: unexpected argument '{s}'", .{args[1]});
    if (args.len == 1) {
        const arg = args[0];
        if (eqlAny(arg, &.{ "off", "none", "clear" })) {
            try c.db.setSetting(sheet.goal_setting, null, c.now.ts);
            return c.out.writeAll("Weekly goal off.\n");
        }
        const secs = time.parseDuration(arg) catch return c.fail("invalid goal '{s}'; try 20h, 20, or 37:30", .{arg});
        if (secs < 60) return c.fail("a goal needs at least a minute; `shifty goal off` turns it off", .{});
        if (secs > sheet.max_goal_secs) return c.fail("a week has only {d} hours", .{@divExact(sheet.max_goal_secs, std.time.s_per_hour)});
        try c.db.setSetting(sheet.goal_setting, try std.fmt.allocPrint(c.arena, "{d}", .{secs}), c.now.ts);
        try c.out.print("Weekly goal set to {f}.\n", .{dur(secs)});
        return weekGoalStatus(c);
    }
    if (try sheet.weeklyGoal(&c.db, c.arena) == null) return c.out.writeAll("No weekly goal. Set one with `shifty goal 20h`.\n");
    try weekGoalStatus(c);
}

fn clockIn(c: *Ctx, args: []const [:0]const u8) !void {
    var start_time: ?time.Time = null;
    var length: ?i64 = null;
    var open = false;
    var it: Args = .{ .c = c, .cmd = "in", .list = args };
    while (it.next()) |arg| {
        if (eqlAny(arg, &.{ "-s", "--start" })) {
            start_time = try it.time(arg);
        } else if (std.mem.eql(u8, arg, "--open")) {
            open = true;
        } else if (eqlAny(arg, &.{ "-l", "--length" })) {
            const v = try it.value(arg);
            length = time.parseDuration(v) catch return c.fail("invalid length '{s}' for {s}", .{ v, arg });
        } else return it.unexpected(arg);
    }

    const target = length orelse try defaultShiftSecs(c);
    var at = c.now;
    if (start_time) |t| {
        // Today at that time, or yesterday if that's still to come: at 1 AM,
        // `-s 10pm` means last night.
        at.ts = fmt.dayStart(c.now.ts, c.now.utc_offset_secs) + t.toTs();
        if (at.ts > c.now.ts) at.ts -= std.time.s_per_day;
        at.utc_offset_secs = local.utcOffset(at.ts);
    }

    const shift_id = c.db.startShift(target, at) catch |e| switch (e) {
        error.Conflict => {
            const shift = (try c.db.currentShift(c.arena)).?;
            return c.fail("already on shift since {f}; `shifty out` first", .{clock(shift.in_ts, shift.utc_offset_secs)});
        },
        else => return e,
    };
    // The day's break presets are on the shift now, or it's the day's
    // shift resumed, with the time away as break.
    const shift = (try c.db.currentShift(c.arena)).?;
    const brks = try c.db.breaks(c.arena, shift_id);
    const lunch = try sheet.Lunch.load(&c.db, c.arena);
    const out = try sheet.clockOut(c.arena, shift, brks, lunch, c.now.ts);
    if (shift.in_ts != at.ts) {
        try c.out.print("Back on today's shift from {f}. Clock out at {f}.\n", .{ clock(shift.in_ts, at.utc_offset_secs), clock(out, at.utc_offset_secs) });
    } else {
        try c.out.print("Clocked in at {f}. Clock out at {f}.\n", .{ clock(at.ts, at.utc_offset_secs), clock(out, at.utc_offset_secs) });
    }
    for (brks) |b| try c.out.print("Break {f}-{f}.\n", .{ clock(b.in_ts, at.utc_offset_secs), clock(b.out_ts.?, at.utc_offset_secs) });
    if (lunch) |l| if (try l.planFor(c.arena, shift, brks, c.now.ts)) |p| try lunchStatus(c, p, l, at.utc_offset_secs);
    if (open) try openLink(c, .in);
}

fn defaultShiftSecs(c: *Ctx) !i64 {
    const v = try c.db.setting(c.arena, "default_shift_secs") orelse return default_shift_secs;
    return std.fmt.parseInt(i64, v, 10) catch default_shift_secs;
}

fn clockOut(c: *Ctx, args: []const [:0]const u8) !void {
    const open = try onlyOpen(c, "out", args);
    const now = c.now.ts;
    const shift = try c.db.currentShift(c.arena) orelse return c.fail("not on shift", .{});
    const brks = try c.db.breaks(c.arena, shift.id);
    _ = try c.db.endShift(now);

    var worked = now - shift.in_ts;
    for (brks) |b| worked -= @max(0, @min(b.out_ts orelse now, now) - @max(b.in_ts, shift.in_ts));
    try c.out.print("Clocked out at {f}, {f} worked.\n", .{ clock(now, c.now.utc_offset_secs), dur(@max(0, worked)) });
    if (open) try openLink(c, .out);
}

/// `break`, `break plan`, or `break unplan`.
fn breakCommand(c: *Ctx, args: []const [:0]const u8) !void {
    if (args.len > 0 and std.mem.eql(u8, args[0], "plan")) return planBreak(c, args[1..]);
    if (args.len > 0 and std.mem.eql(u8, args[0], "unplan")) return unplanBreak(c, args[1..]);
    return toggleBreak(c, args);
}

fn toggleBreak(c: *Ctx, args: []const [:0]const u8) !void {
    const open = try onlyOpen(c, "break", args);
    const now = c.now.ts;
    const shift = try c.db.currentShift(c.arena) orelse return c.fail("not on shift; `shifty in` first", .{});
    const lunch = try sheet.Lunch.load(&c.db, c.arena);
    const before = try c.db.breaks(c.arena, shift.id);

    if (running(before)) |b| {
        const was_lunch = if (lunch) |l| (if (try l.planFor(c.arena, shift, before, now)) |p| p.isLunch(b.in_ts) else false) else false;
        if (try c.db.endBreak(now) == null) {
            try c.out.writeAll("Break under a minute; dropped.\n");
        } else {
            const out = try sheet.clockOut(c.arena, shift, try c.db.breaks(c.arena, shift.id), lunch, now);
            try c.out.print("Back from {s} after {f}. Clock out at {f}.\n", .{ if (was_lunch) "lunch" else "the break", dur(now - b.in_ts), clock(out, c.now.utc_offset_secs) });
            if (open and was_lunch and lunch.?.clock_link) try openLink(c, .in);
        }
        return;
    }

    const tracking = try c.db.runningEntry(c.arena);
    _ = try c.db.startBreak(now);
    const after = try c.db.breaks(c.arena, shift.id);
    const is_lunch = if (lunch) |l| (if (try l.planFor(c.arena, shift, after, now)) |p| p.isLunch(now) else false) else false;
    try c.out.print("On {s} since {f}.", .{ if (is_lunch) "lunch" else "break", clock(now, c.now.utc_offset_secs) });
    if (tracking) |e| try c.out.print(" Stopped tracking {s}.", .{try label(c, e.project_id, e.workspace_id)});
    if (is_lunch) try c.out.print(" Clock out holds until you've had {f}.", .{dur(lunch.?.minimum_secs)});
    try c.out.writeAll("\n");
    if (open and is_lunch and lunch.?.clock_link) try openLink(c, .out);
}

// ── One-off breaks ──────────────────────────────────────────────────────────

fn planBreak(c: *Ctx, args: []const [:0]const u8) !void {
    var times: [2]time.Time = undefined;
    var n_times: usize = 0;
    var name: ?[]const u8 = null;
    var day: ?i64 = null;
    var it: Args = .{ .c = c, .cmd = "break plan", .list = args };
    while (it.peek()) |arg| {
        if (eqlAny(arg, &.{ "-n", "--name" })) {
            _ = it.next();
            name = try it.value(arg);
        } else if (eqlAny(arg, &.{ "-d", "--day" })) {
            _ = it.next();
            day = try parseNextDay(c, try it.value(arg));
        } else if (arg.len > 0 and arg[0] != '-' and n_times < 2) {
            times[n_times] = try it.time("break plan");
            n_times += 1;
        } else {
            _ = it.next();
            return it.unexpected(arg);
        }
    }
    if (n_times < 2) return c.fail("usage: shifty break plan <start> <end> [-d <day>] [-n <name>]", .{});

    const now = c.now.ts;
    const midnight = day orelse fmt.dayStart(now, c.now.utc_offset_secs);
    const noon = midnight + std.time.s_per_day / 2;
    const off = local.utcOffset(noon);
    const from = sheet.onDay(noon, off, times[0]);
    const end = sheet.endAfter(from, off, times[1]);
    if (!sheet.validBreak(from, end)) return c.fail("a break can't run longer than 12 hours", .{});
    if (end <= now) return c.fail("that's over already; -d for another day", .{});

    const label_ = name orelse "Break";
    const a = c.arena;
    const was = if (try c.db.currentShift(a)) |sh| (try c.db.breaks(a, sh.id)).len else 0;
    try c.db.putOneOffBreak(.{ .id = .v7(c.io), .name = label_, .in_ts = from, .out_ts = end }, now);
    const at_off = local.utcOffset(from);
    try c.out.print("Planned {s} on {f}, {f} – {f}.\n", .{ label_, fmt.date(from, at_off), clock(from, at_off), clock(end, at_off) });
    if (try c.db.currentShift(a)) |sh| {
        const brks = try c.db.breaks(a, sh.id);
        if (brks.len > was) {
            const lunch = try sheet.Lunch.load(&c.db, a);
            const out = try sheet.clockOut(a, sh, brks, lunch, now);
            try c.out.print("It's on today's shift: clock out at {f}.\n", .{clock(out, c.now.utc_offset_secs)});
        }
    }
}

fn unplanBreak(c: *Ctx, args: []const [:0]const u8) !void {
    var from_time: ?time.Time = null;
    var day: ?i64 = null;
    var it: Args = .{ .c = c, .cmd = "break unplan", .list = args };
    while (it.peek()) |arg| {
        if (eqlAny(arg, &.{ "-d", "--day" })) {
            _ = it.next();
            day = try parseNextDay(c, try it.value(arg));
        } else if (arg.len > 0 and arg[0] != '-' and from_time == null) {
            from_time = try it.time("break unplan");
        } else {
            _ = it.next();
            return it.unexpected(arg);
        }
    }
    const t = from_time orelse return c.fail("usage: shifty break unplan <start> [-d <day>]", .{});
    const midnight = day orelse fmt.dayStart(c.now.ts, c.now.utc_offset_secs);
    const noon = midnight + std.time.s_per_day / 2;
    const from = sheet.onDay(noon, local.utcOffset(noon), t);
    for (try c.db.oneOffBreaks(c.arena, midnight, midnight + std.time.s_per_day)) |o| {
        if (o.in_ts != from) continue;
        try c.db.deleteOneOffBreak(o.id, c.now.ts);
        const o_off = local.utcOffset(o.in_ts);
        return c.out.print("Dropped {s} on {f}, {f} – {f}.\n", .{ o.name, fmt.date(o.in_ts, o_off), clock(o.in_ts, o_off), clock(o.out_ts, o_off) });
    }
    return c.fail("no one-off break starts at {f} on {f}; `shifty breaks` lists them", .{ clock(from, local.utcOffset(from)), fmt.date(noon, local.utcOffset(noon)) });
}

/// A day's local midnight, looking ahead: `today`, `tomorrow`, a weekday
/// (the next one, today included), or `YYYY-MM-DD`.
fn parseNextDay(c: *Ctx, str: []const u8) !i64 {
    const today = fmt.dayStart(c.now.ts, c.now.utc_offset_secs);
    if (std.ascii.eqlIgnoreCase(str, "today")) return today;
    if (std.ascii.eqlIgnoreCase(str, "tomorrow")) return midnightOf(today + std.time.s_per_day + std.time.s_per_day / 2);
    const names = [_][]const u8{ "mon", "tue", "wed", "thu", "fri", "sat", "sun" };
    for (names, 1..) |n, iso| {
        if (str.len >= 3 and std.ascii.startsWithIgnoreCase(str, n) and std.ascii.startsWithIgnoreCase(fullDay(iso), str)) {
            const wd = sheet.isoWeekday(c.now.ts + c.now.utc_offset_secs);
            const ahead: i64 = @mod(@as(i64, @intCast(iso)) - @as(i64, wd), 7);
            return midnightOf(today + ahead * std.time.s_per_day + std.time.s_per_day / 2);
        }
    }
    const ymd = parseYmd(str) orelse return c.fail("can't read '{s}' as a day; use today, tomorrow, mon...sun, or 2026-11-14", .{str});
    return midnightOf(ymd * std.time.s_per_day + std.time.s_per_day / 2);
}

/// The week's breaks by day, with lunch marked and days that missed it,
/// then the one-off breaks still to come.
fn listBreaks(c: *Ctx, args: []const [:0]const u8) !void {
    var day: ?i64 = null;
    var last = false;
    var it: Args = .{ .c = c, .cmd = "breaks", .list = args };
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--last")) {
            last = true;
        } else if (day == null and arg[0] != '-') {
            day = try parseDay(c, arg);
        } else return it.unexpected(arg);
    }
    const a = c.arena;
    const now = c.now.ts;
    var ref = (day orelse fmt.dayStart(now, c.now.utc_offset_secs)) + std.time.s_per_day / 2;
    if (last) ref -= 7 * std.time.s_per_day;
    const first = sheet.weekStart(ref, local.utcOffset(ref), try sheet.weekStartDay(&c.db, a));
    const w: sheet.Week = try .load(&c.db, a, sheet.weekDays(first, local.utcOffset));

    // A break a one-off put on its shift goes by the one-off's name.
    const one_offs = try c.db.oneOffBreaks(a, w.days[0], w.days[7]);

    try c.out.print("Breaks, week of {f}\n", .{fmt.date(w.days[0], local.utcOffset(w.days[0]))});
    var total: i64 = 0;
    var any = false;
    for (0..7) |d| {
        const shifts = try w.shiftsOn(a, d);
        if (shifts.len == 0) continue;
        any = true;
        try c.out.print("\n{f}\n", .{fmt.date(w.days[d], local.utcOffset(w.days[d]))});
        for (shifts) |sh| {
            const off = sh.shift.utc_offset_secs;
            const plan = try w.lunchOf(a, sh, now);
            for (sh.breaks) |b| {
                const secs = (b.out_ts orelse @max(now, b.in_ts)) - b.in_ts;
                total += secs;
                try printSpan(c, b.in_ts, b.out_ts, off);
                const is_lunch = if (plan) |p| p.isLunch(b.in_ts) else false;
                var what: []const u8 = if (is_lunch) "Lunch" else "Break";
                for (one_offs) |o| {
                    if (o.out_ts == b.out_ts and o.in_ts <= b.in_ts and !is_lunch) what = o.name;
                }
                try c.out.print("  {s: >7}  {s}\n", .{ try padDur(c, secs), what });
            }
            if (plan) |p| switch (p.status(now)) {
                .missed => try c.out.writeAll("  No lunch\n"),
                .late => try c.out.writeAll("  Lunch was late\n"),
                else => {},
            };
            if (sh.breaks.len == 0 and plan == null) try c.out.writeAll("  No breaks\n");
        }
    }
    if (any) {
        try c.out.print("\n  {s: >7}  on break\n", .{try padDur(c, total)});
    } else try c.out.writeAll("\nNo shifts this week.\n");

    const today = fmt.dayStart(now, c.now.utc_offset_secs);
    const planned = try c.db.oneOffBreaks(a, now, today + 60 * std.time.s_per_day);
    if (planned.len == 0) return;
    try c.out.writeAll("\nPlanned\n");
    for (planned) |o| {
        const off = local.utcOffset(o.in_ts);
        try c.out.print("  {f}  {f} – {f}  {s: >7}  {s}\n", .{ fmt.date(o.in_ts, off), clock(o.in_ts, off), clock(o.out_ts, off), try padDur(c, o.out_ts - o.in_ts), o.name });
    }
}

/// How lunch stands on the shift you're on.
fn lunchStatus(c: *Ctx, p: sheet.Plan, l: sheet.Lunch, off: i64) !void {
    const now = c.now.ts;
    switch (p.status(now)) {
        .upcoming => try c.out.print("Lunch opens at {f}; start it by {f}.\n", .{ clock(p.opens, off), clock(p.closes, off) }),
        .open => try c.out.print("Lunch is open: start it by {f} ({f} left).\n", .{ clock(p.closes, off), dur(p.closes - now) }),
        .on_lunch => try c.out.print("On lunch {f} of {f}.\n", .{ dur(now - p.lunch.?.start), dur(l.minimum_secs) }),
        .taken => if (p.lunch.?.start > now)
            try c.out.print("Lunch planned at {f}.\n", .{clock(p.lunch.?.start, off)})
        else
            try c.out.print("Had lunch at {f}.\n", .{clock(p.lunch.?.start, off)}),
        .late => try c.out.print("Lunch started late, at {f}; the window closed at {f}.\n", .{ clock(p.lunch.?.start, off), clock(p.closes, off) }),
        .missed => try c.out.print("Missed lunch: the window closed at {f}.\n", .{clock(p.closes, off)}),
    }
}

/// Opens the clock link, if there is one.
fn openLink(c: *Ctx, which: clock_link.Which) !void {
    const url = try clock_link.get(&c.db, c.arena, which) orelse
        return c.fail("no clock link set; set one in the menu bar's Settings", .{});
    clock_link.open(c.io, url) catch |e| return c.fail("couldn't open {s}: {t}", .{ url, e });
    try c.out.print("Opened {s}.\n", .{url});
}

/// `--open`, or nothing.
fn onlyOpen(c: *Ctx, comptime cmd: []const u8, args: []const [:0]const u8) !bool {
    if (args.len == 0) return false;
    if (args.len == 1 and std.mem.eql(u8, args[0], "--open")) return true;
    return c.fail(cmd ++ ": unexpected argument '{s}'", .{args[0]});
}

// ── Timesheet ───────────────────────────────────────────────────────────────

fn timesheet(c: *Ctx, args: []const [:0]const u8) !void {
    var day: ?i64 = null;
    var last = false;
    var org: ?store.Organization = null;
    var it: Args = .{ .c = c, .cmd = "sheet", .list = args };
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--last")) {
            last = true;
        } else if (std.mem.eql(u8, arg, "--org")) {
            org = try namedOrganization(c, try c.db.organizations(c.arena), try it.value(arg));
        } else if (day == null and arg[0] != '-') {
            day = try parseDay(c, arg);
        } else return it.unexpected(arg);
    }
    var ref = (day orelse fmt.dayStart(c.now.ts, c.now.utc_offset_secs)) + std.time.s_per_day / 2;
    if (last) ref -= 7 * std.time.s_per_day;
    const first = sheet.weekStart(ref, local.utcOffset(ref), try sheet.weekStartDay(&c.db, c.arena));
    const w: sheet.Week = try .loadFor(&c.db, c.arena, sheet.weekDays(first, local.utcOffset), if (org) |o| o.id else null);
    const now = c.now.ts;
    const this_week = now >= w.days[0] and now < w.days[7];
    const a = c.arena;
    // An organization with no shift: only its own time, none of it worked.
    const off_shift = if (org) |o| o.tracking == .auto else false;

    try c.out.print("Week of {f}{s}", .{ fmt.date(w.days[0], local.utcOffset(w.days[0])), if (this_week) " (this week)" else "" });
    if (org) |o| try c.out.print(", {s}", .{o.name});
    try c.out.writeAll("\n");
    var any = false;
    for (0..7) |d| {
        const is_today = this_week and w.dayOf(now) == d;
        if (!w.hasTime(d) and !is_today) continue;
        any = true;
        const sum = try w.summary(a, d, now);
        const head = try std.fmt.allocPrint(a, "{f}{s}", .{ fmt.date(w.days[d], local.utcOffset(w.days[d])), if (is_today) "  today" else "" });
        try c.out.print("\n{s}", .{head});
        if (sum.worked > 0 or sum.tracked > 0) {
            const secs = if (sum.worked > 0) sum.worked else sum.tracked;
            try c.out.print("{s}{s: >7}", .{ try spaces(a, 44 -| head.len), try padDur(c, secs) });
            if (sum.over > 0) try c.out.print("  +{f}", .{dur(sum.over)});
        } else if (sum.personal > 0) {
            try c.out.print("{s}{s: >7}  personal", .{ try spaces(a, 44 -| head.len), try padDur(c, sum.personal) });
        }
        try c.out.writeAll("\n");
        if (!w.hasTime(d)) {
            try c.out.writeAll("  Nothing yet.\n");
            continue;
        }
        for (try w.shiftsOn(a, d)) |s| {
            const off = s.shift.utc_offset_secs;
            try printSpan(c, s.shift.in_ts, s.shift.out_ts, off);
            try c.out.print("  {s: >7}  Shift", .{try padDur(c, try sheet.worked(a, s.shift, s.breaks, now))});
            if (s.shift.out_ts == null) {
                try c.out.print(", out at {f}", .{clock(try w.expectedEnd(a, s, now), c.now.utc_offset_secs)});
            } else try c.out.print(" of {f}", .{dur(s.shift.target_secs)});
            if (try w.lunchOf(a, s, now)) |p| try c.out.print("; {s}", .{switch (p.status(now)) {
                .upcoming => try std.fmt.allocPrint(a, "lunch {f}-{f}", .{ clock(p.opens, off), clock(p.closes, off) }),
                .open => try std.fmt.allocPrint(a, "lunch by {f}", .{clock(p.closes, off)}),
                .on_lunch => "on lunch",
                .taken => if (p.lunch.?.start > now) "lunch planned" else "had lunch",
                .late => "lunch late",
                .missed => "no lunch",
            }});
            try c.out.writeAll("\n");
        }
        for (try w.rows(a, d)) |r| switch (r) {
            .entry => |e| {
                try printSpan(c, @max(e.in_ts, w.days[0]), e.out_ts, e.utc_offset_secs);
                try c.out.print("  {s: >7}  {s}", .{ try padDur(c, w.seconds(e, now)), try w.names.label(a, e.project_id, e.workspace_id) });
                try printNote(c, e);
                if (org == null and w.names.isPersonal(e.project_id)) try c.out.print("  ({s})", .{w.names.organizationOf(e.project_id).?.name});
                try c.out.writeAll("\n");
            },
            .brk => |b| {
                try printSpan(c, b.brk.in_ts, b.brk.out_ts, b.shift.shift.utc_offset_secs);
                const lunch = if (try w.lunchOf(a, b.shift, now)) |p| p.isLunch(b.brk.in_ts) else false;
                try c.out.print("  {s: >7}  {s}\n", .{ try padDur(c, (b.brk.out_ts orelse @max(now, b.brk.in_ts)) - b.brk.in_ts), if (lunch) "Lunch" else "Break" });
            },
        };
    }
    if (!any) return c.out.writeAll("\nNothing this week.\n");

    const s = try w.summary(a, null, now);
    const t = try w.totals(a, now);
    try c.out.writeAll("\nWeek\n");
    if (off_shift) {
        try c.out.print("  {s: >7}  personal, not worked\n", .{try padDur(c, s.personal)});
        return printPersonal(c, w.names, t);
    }
    try c.out.print("  {s: >7}  worked\n", .{try padDur(c, s.worked)});
    if (try w.goal(a, now)) |g| {
        if (g.isMet()) {
            try c.out.print("  {s: >7}  goal, met\n", .{try padDur(c, g.secs)});
        } else try c.out.print("  {s: >7}  goal, {f} left\n", .{ try padDur(c, g.secs), dur(g.left()) });
    }
    if (s.over > 0) try c.out.print("  {s: >7}  over\n", .{try padDur(c, s.over)});
    try c.out.print("  {s: >7}  on break\n", .{try padDur(c, s.on_break)});
    try c.out.print("  {s: >7}  tracked\n", .{try padDur(c, s.tracked)});
    try c.out.print("  {s: >7}  untracked\n", .{try padDur(c, s.untracked)});
    if (s.personal > 0) try c.out.print("  {s: >7}  personal, not worked\n", .{try padDur(c, s.personal)});

    if (t.by_project.len > 0) {
        try c.out.writeAll("\nBy project\n");
        for (t.by_project) |pt| {
            try c.out.print("  {s: >7}  {s}", .{ try padDur(c, pt.secs), try w.names.label(a, pt.id, null) });
            if (w.names.clientOf(pt.id)) |cl| try c.out.print("  ({s})", .{cl.name});
            try c.out.writeAll("\n");
        }
    }
    if (t.any_client) {
        try c.out.writeAll("\nBy client\n");
        for (t.by_client) |ct| {
            const name = if (ct.id) |cid| w.names.client(cid).?.name else "(no client)";
            try c.out.print("  {s: >7}  {s}\n", .{ try padDur(c, ct.secs), name });
        }
    }
    if (org == null) try printByOrganization(c, w.names, t);
    try printPersonal(c, w.names, t);
}

/// Work time per organization, when it went to more than one.
fn printByOrganization(c: *Ctx, names: Names, t: store.report.Totals) !void {
    if (t.by_organization.len < 2) return;
    try c.out.writeAll("\nBy organization\n");
    for (t.by_organization) |ot| {
        const name = if (ot.id) |oid| (if (names.organization(oid)) |o| o.name else "(deleted)") else "(unassigned)";
        try c.out.print("  {s: >7}  {s}\n", .{ try padDur(c, ot.secs), name });
    }
}

/// Time on organizations with no shift, by project. It's never worked time.
fn printPersonal(c: *Ctx, names: Names, t: store.report.Totals) !void {
    if (t.personal_by_project.len == 0) return;
    try c.out.writeAll("\nPersonal, not worked\n");
    for (t.personal_by_project) |pt| {
        try c.out.print("  {s: >7}  {s}", .{ try padDur(c, pt.secs), try names.label(c.arena, pt.id, null) });
        if (names.organizationOf(pt.id)) |o| try c.out.print("  ({s})", .{o.name});
        try c.out.writeAll("\n");
    }
}

/// An entry's note, or a meeting's title.
fn printNote(c: *Ctx, e: store.Entry) !void {
    switch (e.kind) {
        .meeting => try c.out.print("  Meeting: {s}", .{e.note orelse "untitled"}),
        .work => if (e.note) |n| try c.out.print("  {s}", .{n}),
    }
}

fn printSpan(c: *Ctx, from: i64, end: ?i64, off: i64) !void {
    try c.out.print("  {f} – ", .{clock(from, off)});
    if (end) |e| try c.out.print("{f}", .{clock(e, off)}) else try c.out.writeAll("     now");
}

fn spaces(a: Allocator, n: usize) ![]const u8 {
    const s = try a.alloc(u8, n);
    @memset(s, ' ');
    return s;
}

fn add(c: *Ctx, args: []const [:0]const u8) !void {
    const Kind = enum { entry, shift, @"break" };
    var kind: Kind = .entry;
    var times: [2]time.Time = undefined;
    var n_times: usize = 0;
    var spec: ?[]const u8 = null;
    var note: ?[]const u8 = null;
    var meeting: ?[]const u8 = null;
    var day: ?i64 = null;
    var it: Args = .{ .c = c, .cmd = "add", .list = args };
    while (it.peek()) |arg| {
        if (std.mem.eql(u8, arg, "--shift")) {
            _ = it.next();
            kind = .shift;
        } else if (std.mem.eql(u8, arg, "--break")) {
            _ = it.next();
            kind = .@"break";
        } else if (eqlAny(arg, &.{ "-n", "--note" })) {
            _ = it.next();
            note = try it.value(arg);
        } else if (eqlAny(arg, &.{ "-m", "--meeting" })) {
            _ = it.next();
            meeting = try meetingTitle(c, try it.value(arg));
        } else if (eqlAny(arg, &.{ "-d", "--day" })) {
            _ = it.next();
            day = try parseDay(c, try it.value(arg));
        } else if (arg.len > 0 and arg[0] == '-') {
            _ = it.next();
            return it.unexpected(arg);
        } else if (n_times < 2) {
            times[n_times] = try it.time("add");
            n_times += 1;
        } else if (spec == null) {
            spec = it.next();
        } else {
            _ = it.next();
            return it.unexpected(arg);
        }
    }
    if (n_times < 2) return c.fail("usage: shifty add <start> <end> [<project>] [-n <note>] [-d <day>]", .{});
    if (kind != .entry and (spec != null or note != null or meeting != null)) return c.fail("add --{t} takes only times and -d", .{kind});
    if (meeting != null and note != null) return c.fail("a meeting's note is its title; use -m alone", .{});

    const now = c.now.ts;
    // Today, or yesterday for a from that's still to come today.
    const midnight = day orelse blk: {
        const today = fmt.dayStart(now, c.now.utc_offset_secs);
        break :blk if (today + times[0].toTs() > now) today - std.time.s_per_day else today;
    };
    const noon = midnight + std.time.s_per_day / 2;
    const off = local.utcOffset(noon);
    const a = c.arena;

    switch (kind) {
        .entry, .shift => {
            const from = sheet.onDay(noon, off, times[0]);
            const end = sheet.endAfter(from, off, times[1]);
            if (!sheet.validEntry(from, end)) return c.fail("that's longer than 16 hours", .{});
            if (end > now) return c.fail("that ends in the future; `shifty {s}` for now", .{if (kind == .entry) "start" else "in"});
            const at: local.Stamp = .{ .ts = from, .utc_offset_secs = local.utcOffset(from), .tz = c.now.tz };
            if (kind == .shift) {
                _ = try c.db.addShift(at, end);
                return c.out.print("Added a shift on {f}, {f} – {f} ({f}).\n", .{ fmt.date(from, at.utc_offset_secs), clock(from, at.utc_offset_secs), clock(end, at.utc_offset_secs), dur(end - from) });
            }
            const target = if (spec) |sp| try resolve(c, sp) else null;
            _ = try c.db.addEntry(.{
                .project_id = if (target) |t| t.project_id else null,
                .workspace_id = if (target) |t| t.workspace_id else null,
                .source = .cli,
                .note = meeting orelse note,
                .kind = if (meeting != null) .meeting else .work,
            }, at, end);
            const name = if (target) |t| try label(c, t.project_id, t.workspace_id) else try label(c, null, null);
            if (meeting) |m| {
                try c.out.print("Added the meeting {s}, {f} of {s} on {f}, {f} – {f}.\n", .{ m, dur(end - from), name, fmt.date(from, at.utc_offset_secs), clock(from, at.utc_offset_secs), clock(end, at.utc_offset_secs) });
            } else try c.out.print("Added {f} of {s} on {f}, {f} – {f}.\n", .{ dur(end - from), name, fmt.date(from, at.utc_offset_secs), clock(from, at.utc_offset_secs), clock(end, at.utc_offset_secs) });
        },
        .@"break" => {
            const shifts = try c.db.shiftsBetween(a, midnight, midnight + std.time.s_per_day);
            var found: ?store.Shift = null;
            for (shifts) |s| if (s.in_ts >= midnight) {
                found = s;
                break;
            };
            const s = found orelse (if (shifts.len > 0) shifts[0] else null) orelse
                return c.fail("no shift on {f}; `shifty add --shift` first", .{fmt.date(noon, off)});
            const so = s.utc_offset_secs;
            const from = sheet.anchorAfter(s.in_ts, so, times[0]);
            const end = sheet.endAfter(from, so, times[1]);
            if (!sheet.validBreak(from, end)) return c.fail("a break can't run longer than 12 hours", .{});
            _ = try c.db.addBreak(s.id, from, end, now);
            try c.out.print("Added a {f} break, {f} – {f}, to the shift on {f}.\n", .{ dur(end - from), clock(from, so), clock(end, so), fmt.date(s.in_ts, so) });
            if (s.out_ts == null) {
                const lunch = try sheet.Lunch.load(&c.db, a);
                const out = try sheet.clockOut(a, s, try c.db.breaks(a, s.id), lunch, now);
                try c.out.print("Clock out at {f}.\n", .{clock(out, c.now.utc_offset_secs)});
            }
        },
    }
}

/// A day's local midnight: `today`, `yesterday`, a weekday (the last one,
/// today included), or `YYYY-MM-DD`.
fn parseDay(c: *Ctx, str: []const u8) !i64 {
    const today = fmt.dayStart(c.now.ts, c.now.utc_offset_secs);
    if (std.ascii.eqlIgnoreCase(str, "today")) return today;
    if (std.ascii.eqlIgnoreCase(str, "yesterday")) return midnightOf(today - std.time.s_per_day / 2);
    const names = [_][]const u8{ "mon", "tue", "wed", "thu", "fri", "sat", "sun" };
    for (names, 1..) |n, iso| {
        if (str.len >= 3 and std.ascii.startsWithIgnoreCase(str, n) and std.ascii.startsWithIgnoreCase(fullDay(iso), str)) {
            const wd = sheet.isoWeekday(c.now.ts + c.now.utc_offset_secs);
            const back: i64 = @mod(@as(i64, wd) - @as(i64, @intCast(iso)), 7);
            return midnightOf(today - back * std.time.s_per_day + std.time.s_per_day / 2);
        }
    }
    const ymd = parseYmd(str) orelse return c.fail("can't read '{s}' as a day; use today, yesterday, mon...sun, or 2026-11-09", .{str});
    return midnightOf(ymd * std.time.s_per_day + std.time.s_per_day / 2);
}

fn fullDay(iso: usize) []const u8 {
    return ([_][]const u8{ "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday" })[iso - 1];
}

/// Local midnight of the day holding `ts`.
fn midnightOf(ts: i64) i64 {
    return fmt.dayStart(ts, local.utcOffset(ts));
}

/// Days since 1970-01-01 for `YYYY-MM-DD`.
fn parseYmd(str: []const u8) ?i64 {
    var it = std.mem.splitScalar(u8, str, '-');
    const y = std.fmt.parseInt(i64, it.next() orelse return null, 10) catch return null;
    const m = std.fmt.parseInt(i64, it.next() orelse return null, 10) catch return null;
    const d = std.fmt.parseInt(i64, it.next() orelse return null, 10) catch return null;
    if (it.next() != null or m < 1 or m > 12 or d < 1 or d > 31 or y < 1970) return null;
    // Howard Hinnant's days_from_civil.
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

// ── Tracking ────────────────────────────────────────────────────────────────

fn start(c: *Ctx, args: []const [:0]const u8) !void {
    var spec: ?[]const u8 = null;
    var note: ?[]const u8 = null;
    var meeting: ?[]const u8 = null;
    var it: Args = .{ .c = c, .cmd = "start", .list = args };
    while (it.next()) |arg| {
        if (eqlAny(arg, &.{ "-n", "--note" })) {
            note = try it.value(arg);
        } else if (eqlAny(arg, &.{ "-m", "--meeting" })) {
            meeting = try meetingTitle(c, try it.value(arg));
        } else if (spec == null and arg[0] != '-') {
            spec = arg;
        } else return it.unexpected(arg);
    }
    if (meeting != null and note != null) return c.fail("a meeting's note is its title; use -m alone", .{});

    var target: ?store.Target = null;
    var unlinked: ?[]const u8 = null;
    if (spec) |s| {
        target = try resolve(c, s);
    } else if (try cwd(c)) |d| {
        const p = try place.resolve(&c.db, c.io, c.arena, d, null, null);
        target = p.target;
        if (target == null) unlinked = p.root;
    }

    const prev = try c.db.runningEntry(c.arena);
    _ = c.db.startEntry(.{
        .project_id = if (target) |t| t.project_id else null,
        .workspace_id = if (target) |t| t.workspace_id else null,
        .source = .cli,
        .note = meeting orelse note,
        .kind = if (meeting != null) .meeting else .work,
    }, c.now) catch |e| switch (e) {
        error.Conflict => return c.fail("another timer started at the same moment; try again", .{}),
        else => return e,
    };

    if (prev) |p| {
        const name = try label(c, p.project_id, p.workspace_id);
        if (c.now.ts > p.in_ts) {
            try c.out.print("Stopped {s} after {f}.\n", .{ name, dur(c.now.ts - p.in_ts) });
        } else try c.out.print("Dropped {s}: stopped the second it started.\n", .{name});
    }
    const name = if (target) |t| try label(c, t.project_id, t.workspace_id) else try label(c, null, null);
    if (meeting) |m| {
        try c.out.print("In the meeting {s} for {s} since {f}.\n", .{ m, name, clock(c.now.ts, c.now.utc_offset_secs) });
    } else try c.out.print("Tracking {s} since {f}.\n", .{ name, clock(c.now.ts, c.now.utc_offset_secs) });
    if (unlinked) |root| try c.out.print("This repo ({s}) isn't linked to a project; `shifty link <project>` to track it.\n", .{root});
}

fn stop(c: *Ctx, args: []const [:0]const u8) !void {
    try noArgs(c, "stop", args);
    const e = try c.db.runningEntry(c.arena) orelse return c.out.writeAll("Not tracking.\n");
    const name = try label(c, e.project_id, e.workspace_id);
    if (try c.db.stopEntry(c.now.ts) == null) {
        try c.out.print("Dropped {s}: stopped the second it started.\n", .{name});
    } else try c.out.print("Stopped {s} after {f}.\n", .{ name, dur(c.now.ts - e.in_ts) });
}

/// A meeting's title, trimmed; it can't be empty.
fn meetingTitle(c: *Ctx, raw: []const u8) ![]const u8 {
    const title = std.mem.trim(u8, raw, " \t\r\n");
    if (title.len == 0) return c.fail("a meeting needs a title", .{});
    return title;
}

fn meetings(c: *Ctx, args: []const [:0]const u8) !void {
    var day: ?i64 = null;
    var last = false;
    var it: Args = .{ .c = c, .cmd = "meetings", .list = args };
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--last")) {
            last = true;
        } else if (day == null and arg[0] != '-') {
            day = try parseDay(c, arg);
        } else return it.unexpected(arg);
    }
    var ref = (day orelse fmt.dayStart(c.now.ts, c.now.utc_offset_secs)) + std.time.s_per_day / 2;
    if (last) ref -= 7 * std.time.s_per_day;
    const a = c.arena;
    const first = sheet.weekStart(ref, local.utcOffset(ref), try sheet.weekStartDay(&c.db, a));
    const days = sheet.weekDays(first, local.utcOffset);
    const now = c.now.ts;
    const list = try c.db.meetingsBetween(a, days[0], days[7]);
    try c.out.print("Meetings, week of {f}\n", .{fmt.date(days[0], local.utcOffset(days[0]))});
    if (list.len == 0) return c.out.writeAll("\nNone this week.\n");

    const names: Names = try .load(&c.db, a);
    var current: ?i64 = null;
    var total: i64 = 0;
    for (list) |e| {
        const in_ts = @max(e.in_ts, days[0]);
        const d = fmt.dayStart(in_ts, e.utc_offset_secs);
        if (current != d) {
            try c.out.print("\n{f}\n", .{fmt.date(in_ts, e.utc_offset_secs)});
            current = d;
        }
        const secs = store.report.clipped(e, days[0], @min(now, days[7]));
        total += secs;
        try printSpan(c, in_ts, e.out_ts, e.utc_offset_secs);
        try c.out.print("  {s: >7}  {s}  {s}\n", .{ try padDur(c, secs), e.note orelse "untitled", try names.label(a, e.project_id, e.workspace_id) });
    }
    try c.out.print("\n  {s: >7}  in {d} meeting{s}\n", .{ try padDur(c, total), list.len, if (list.len == 1) "" else "s" });
}

fn log(c: *Ctx, args: []const [:0]const u8) !void {
    var days: i64 = 1;
    var org: ?store.Organization = null;
    var it: Args = .{ .c = c, .cmd = "log", .list = args };
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--week")) {
            days = 7;
        } else if (std.mem.eql(u8, arg, "--org")) {
            org = try namedOrganization(c, try c.db.organizations(c.arena), try it.value(arg));
        } else return it.unexpected(arg);
    }

    const now = c.now.ts;
    const today = fmt.dayStart(now, c.now.utc_offset_secs);
    const from = today - (days - 1) * std.time.s_per_day;
    const names: Names = try .load(&c.db, c.arena);
    const entries = try names.only(c.arena, try c.db.entriesBetween(c.arena, from, now + 1), if (org) |o| o.id else null);
    if (entries.len == 0) return c.out.writeAll(if (days == 1) "Nothing tracked today.\n" else "Nothing tracked this week.\n");

    var day: ?i64 = null;
    for (entries) |e| {
        const in_ts = @max(e.in_ts, from);
        const d = fmt.dayStart(in_ts, e.utc_offset_secs);
        if (day != d) {
            try c.out.print("{s}{f}\n", .{ if (day == null) "" else "\n", fmt.date(in_ts, e.utc_offset_secs) });
            day = d;
        }
        try c.out.print("  {f} – ", .{clock(in_ts, e.utc_offset_secs)});
        if (e.out_ts) |out| try c.out.print("{f}", .{clock(out, e.utc_offset_secs)}) else try c.out.writeAll("     now");
        try c.out.print("  {s: >7}  {s}", .{ try padDur(c, store.report.clipped(e, from, now)), try names.label(c.arena, e.project_id, e.workspace_id) });
        try printNote(c, e);
        if (org == null and names.isPersonal(e.project_id)) try c.out.print("  ({s})", .{names.organizationOf(e.project_id).?.name});
        try c.out.writeAll("\n");
    }

    const totals = try store.report.totals(c.arena, names, entries, from, now);
    if (totals.by_project.len > 0) try c.out.writeAll("\nBy project\n");
    for (totals.by_project) |t| {
        try c.out.print("  {s: >7}  {s}", .{ try padDur(c, t.secs), try names.label(c.arena, t.id, null) });
        if (names.clientOf(t.id)) |cl| try c.out.print("  ({s})", .{cl.name});
        try c.out.writeAll("\n");
    }
    if (totals.any_client) {
        try c.out.writeAll("\nBy client\n");
        for (totals.by_client) |t| {
            const name = if (t.id) |cid| names.client(cid).?.name else "(no client)";
            try c.out.print("  {s: >7}  {s}\n", .{ try padDur(c, t.secs), name });
        }
    }
    if (org == null) try printByOrganization(c, names, totals);
    try printPersonal(c, names, totals);
    try c.out.writeAll("\n");
    if (totals.by_project.len > 0) try c.out.print("  {s: >7}  total\n", .{try padDur(c, totals.total)});
    if (totals.personal > 0) try c.out.print("  {s: >7}  personal, not worked\n", .{try padDur(c, totals.personal)});
}

// ── Organization ────────────────────────────────────────────────────────────

fn listOrganizations(c: *Ctx, args: []const [:0]const u8) !void {
    try noArgs(c, "orgs", args);
    const orgs = try c.db.organizations(c.arena);
    const projects = try c.db.projects(c.arena);
    const default = try c.db.defaultOrganization();
    for (orgs) |o| {
        var count: usize = 0;
        for (projects) |p| if (p.organization_id != null and p.organization_id.?.eql(o.id)) {
            count += 1;
        };
        try c.out.print("{s}  {s}, {d} project{s}", .{
            o.name,
            switch (o.tracking) {
                .shift => "on the shift",
                .auto => "tracks itself, personal",
            },
            count,
            if (count == 1) "" else "s",
        });
        if (default != null and default.?.eql(o.id)) try c.out.writeAll("; new projects go here");
        try c.out.writeAll("\n");
    }
}

const org_usage =
    \\usage: shifty org add <name> [--auto] [--color <#rrggbb>]
    \\       shifty org rename <name> <new name>
    \\       shifty org tracking <name> <shift|auto>
    \\       shifty org color <name> <#rrggbb|none>
    \\       shifty org delete <name> [--to <org>]
;

fn organization(c: *Ctx, args: []const [:0]const u8) !void {
    const Sub = enum { add, rename, tracking, color, delete };
    const sub = if (args.len > 0) std.meta.stringToEnum(Sub, args[0]) else null;
    const orgs = try c.db.organizations(c.arena);
    switch (sub orelse return c.fail(org_usage, .{})) {
        .add => {
            var name: ?[]const u8 = null;
            var tracking: store.Tracking = .shift;
            var color: ?[]const u8 = null;
            var it: Args = .{ .c = c, .cmd = "org add", .list = args[1..] };
            while (it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--auto")) {
                    tracking = .auto;
                } else if (std.mem.eql(u8, arg, "--color")) {
                    color = try it.value(arg);
                    if (!isColor(color.?)) return c.fail("invalid color '{s}'; use #rrggbb", .{color.?});
                } else if (name == null and arg[0] != '-') {
                    name = arg;
                } else return it.unexpected(arg);
            }
            const n = try validName(c, name orelse return c.fail("org add needs a name", .{}));
            if (try findByName(c, store.Organization, orgs, n, "organization") != null)
                return c.fail("there's already an organization named '{s}'", .{n});
            _ = try c.db.createOrganization(.{ .name = n, .tracking = tracking, .color = color }, c.now.ts);
            try c.out.print("Added organization {s}, {s}.\n", .{ n, switch (tracking) {
                .shift => "on the shift",
                .auto => "tracking itself; its time is personal",
            } });
        },
        .rename => {
            if (args.len != 3) return c.fail("usage: shifty org rename <name> <new name>", .{});
            const o = try namedOrganization(c, orgs, args[1]);
            const n = try validName(c, args[2]);
            if (try findByName(c, store.Organization, orgs, n, "organization")) |other| {
                if (!other.id.eql(o.id)) return c.fail("there's already an organization named '{s}'", .{other.name});
            }
            try c.db.editOrganization(o.id, .{ .name = n, .tracking = o.tracking, .color = o.color }, c.now.ts);
            try c.out.print("Renamed {s} to {s}.\n", .{ o.name, n });
        },
        .tracking => {
            if (args.len != 3) return c.fail("usage: shifty org tracking <name> <shift|auto>", .{});
            const o = try namedOrganization(c, orgs, args[1]);
            const tracking = std.meta.stringToEnum(store.Tracking, args[2]) orelse
                return c.fail("tracking is shift or auto, not '{s}'", .{args[2]});
            try c.db.editOrganization(o.id, .{ .name = o.name, .tracking = tracking, .color = o.color }, c.now.ts);
            try c.out.print("{s} {s}.\n", .{ o.name, switch (tracking) {
                .shift => "is on the shift; its time is worked time",
                .auto => "tracks itself now; its time is personal, not worked",
            } });
        },
        .color => {
            if (args.len != 3) return c.fail("usage: shifty org color <name> <#rrggbb|none>", .{});
            const o = try namedOrganization(c, orgs, args[1]);
            const color: ?[]const u8 = if (std.mem.eql(u8, args[2], "none")) null else args[2];
            if (color) |v| if (!isColor(v)) return c.fail("invalid color '{s}'; use #rrggbb or none", .{v});
            try c.db.editOrganization(o.id, .{ .name = o.name, .tracking = o.tracking, .color = color }, c.now.ts);
            if (color) |v|
                try c.out.print("{s} is now {s}.\n", .{ o.name, v })
            else
                try c.out.print("{s} is back to its default color.\n", .{o.name});
        },
        .delete => {
            var name: ?[]const u8 = null;
            var to_name: ?[]const u8 = null;
            var it: Args = .{ .c = c, .cmd = "org delete", .list = args[1..] };
            while (it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--to")) {
                    to_name = try it.value(arg);
                } else if (name == null and arg[0] != '-') {
                    name = arg;
                } else return it.unexpected(arg);
            }
            const o = try namedOrganization(c, orgs, name orelse return c.fail("org delete needs a name", .{}));
            if (orgs.len == 1) return c.fail("{s} is the only organization; add another to move its projects to", .{o.name});
            const to = if (to_name) |tn| try namedOrganization(c, orgs, tn) else otherOrganization(orgs, o.id);
            if (to.id.eql(o.id)) return c.fail("can't move {s}'s projects to itself", .{o.name});
            try c.db.deleteOrganization(o.id, to.id, c.now.ts);
            try c.out.print("Deleted {s}. Its projects and their time are in {s} now.\n", .{ o.name, to.name });
        },
    }
}

fn namedOrganization(c: *Ctx, orgs: []const store.Organization, name: []const u8) !store.Organization {
    return try findByName(c, store.Organization, orgs, name, "organization") orelse
        return c.fail("no organization named '{s}'; `shifty orgs` lists them", .{name});
}

/// Where a deleted organization's projects go: the first other one on the
/// shift, else the first other.
fn otherOrganization(orgs: []const store.Organization, not: Uuid) store.Organization {
    for (orgs) |o| if (!o.id.eql(not) and o.tracking == .shift) return o;
    for (orgs) |o| if (!o.id.eql(not)) return o;
    unreachable;
}

fn listProjects(c: *Ctx, args: []const [:0]const u8) !void {
    try noArgs(c, "projects", args);
    const projects = try c.db.projects(c.arena);
    if (projects.len == 0) return c.out.writeAll("No projects yet; `shifty project add <name>`.\n");
    const clients = try c.db.clients(c.arena);
    const orgs = try c.db.organizations(c.arena);
    for (orgs, 0..) |o, i| {
        try c.out.print("{s}{s}{s}\n", .{ if (i == 0) "" else "\n", o.name, if (o.tracking == .auto) "  (tracks itself, personal)" else "" });
        var any = false;
        for (projects) |p| {
            if (p.organization_id == null or !p.organization_id.?.eql(o.id)) continue;
            any = true;
            try c.out.print("  {s}", .{p.name});
            if (p.client_id) |cid| if (findById(store.Client, clients, cid)) |cl| try c.out.print("  ({s})", .{cl.name});
            try c.out.writeAll("\n");
            for (try c.db.workspaces(c.arena, p.id)) |w| try c.out.print("    /{s}\n", .{w.name});
        }
        if (!any) try c.out.writeAll("  No projects; `shifty project move <name> <org>`.\n");
    }
}

const project_usage =
    \\usage: shifty project add <name> [--org <name>] [--client <name>] [--color <#rrggbb>]
    \\       shifty project rename <name> <new name>
    \\       shifty project color <name> <#rrggbb|none>
    \\       shifty project move <name> <org>
    \\       shifty project delete <name>
;

fn project(c: *Ctx, args: []const [:0]const u8) !void {
    const Sub = enum { add, rename, color, move, delete };
    const sub = if (args.len > 0) std.meta.stringToEnum(Sub, args[0]) else null;
    switch (sub orelse return c.fail(project_usage, .{})) {
        .add => try addProject(c, args),
        .move => {
            if (args.len != 3) return c.fail("usage: shifty project move <name> <org>", .{});
            const p = try namedProject(c, try c.db.projects(c.arena), args[1]);
            const o = try namedOrganization(c, try c.db.organizations(c.arena), args[2]);
            try c.db.moveProject(p.id, o.id, c.now.ts);
            try c.out.print("Moved {s} to {s}{s}.\n", .{ p.name, o.name, if (o.tracking == .auto) "; its time is personal now, not worked" else "" });
        },
        .rename => {
            if (args.len != 3) return c.fail("usage: shifty project rename <name> <new name>", .{});
            const projects = try c.db.projects(c.arena);
            const p = try namedProject(c, projects, args[1]);
            const n = try validName(c, args[2]);
            if (try findByName(c, store.Project, projects, n, "project")) |other| {
                if (!other.id.eql(p.id)) return c.fail("there's already a project named '{s}'", .{other.name});
            }
            try c.db.editProject(p.id, .{ .name = n, .client_id = p.client_id, .color = p.color }, c.now.ts);
            try c.out.print("Renamed {s} to {s}.\n", .{ p.name, n });
        },
        .color => {
            if (args.len != 3) return c.fail("usage: shifty project color <name> <#rrggbb|none>", .{});
            const p = try namedProject(c, try c.db.projects(c.arena), args[1]);
            const color: ?[]const u8 = if (std.mem.eql(u8, args[2], "none")) null else args[2];
            if (color) |v| if (!isColor(v)) return c.fail("invalid color '{s}'; use #rrggbb or none", .{v});
            try c.db.editProject(p.id, .{ .name = p.name, .client_id = p.client_id, .color = color }, c.now.ts);
            if (color) |v|
                try c.out.print("{s} is now {s}.\n", .{ p.name, v })
            else
                try c.out.print("{s} is back to its default color.\n", .{p.name});
        },
        .delete => {
            if (args.len != 2) return c.fail("usage: shifty project delete <name>", .{});
            const p = try namedProject(c, try c.db.projects(c.arena), args[1]);
            try c.db.deleteProject(p.id, c.now.ts);
            try c.out.print("Deleted {s}. Its time stays, with no project.\n", .{p.name});
        },
    }
}

fn namedProject(c: *Ctx, projects: []const store.Project, name: []const u8) !store.Project {
    return try findByName(c, store.Project, projects, name, "project") orelse
        return c.fail("no project named '{s}'", .{name});
}

fn addProject(c: *Ctx, args: []const [:0]const u8) !void {
    var name: ?[]const u8 = null;
    var client_name: ?[]const u8 = null;
    var org_name: ?[]const u8 = null;
    var color: ?[]const u8 = null;
    var it: Args = .{ .c = c, .cmd = "project add", .list = args[1..] };
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--client")) {
            client_name = try it.value(arg);
        } else if (std.mem.eql(u8, arg, "--org")) {
            org_name = try it.value(arg);
        } else if (std.mem.eql(u8, arg, "--color")) {
            color = try it.value(arg);
            if (!isColor(color.?)) return c.fail("invalid color '{s}'; use #rrggbb", .{color.?});
        } else if (name == null and arg[0] != '-') {
            name = arg;
        } else return it.unexpected(arg);
    }
    const n = try validName(c, name orelse return c.fail("project add needs a name", .{}));

    var client_id: ?Uuid = null;
    if (client_name) |cn| {
        const cl = try findByName(c, store.Client, try c.db.clients(c.arena), cn, "client") orelse
            return c.fail("no client named '{s}'; `shifty client add {s}`", .{ cn, cn });
        client_id = cl.id;
    }
    if (try findByName(c, store.Project, try c.db.projects(c.arena), n, "project") != null)
        return c.fail("there's already a project named '{s}'", .{n});
    const org: ?store.Organization = if (org_name) |on| try namedOrganization(c, try c.db.organizations(c.arena), on) else null;

    _ = try c.db.createProject(.{ .name = n, .client_id = client_id, .color = color, .organization_id = if (org) |o| o.id else null }, c.now.ts);
    if (org) |o| try c.out.print("Added project {s} to {s}.\n", .{ n, o.name }) else try c.out.print("Added project {s}.\n", .{n});
}

fn workspace(c: *Ctx, args: []const [:0]const u8) !void {
    if (args.len != 3 or !std.mem.eql(u8, args[0], "add")) return c.fail("usage: shifty workspace add <project> <name>", .{});
    const p = try findByName(c, store.Project, try c.db.projects(c.arena), args[1], "project") orelse
        return c.fail("no project named '{s}'", .{args[1]});
    const n = try validName(c, args[2]);
    if (try findByName(c, store.Workspace, try c.db.workspaces(c.arena, p.id), n, "workspace") != null)
        return c.fail("{s} already has a workspace named '{s}'", .{ p.name, n });

    _ = try c.db.createWorkspace(p.id, n, c.now.ts);
    try c.out.print("Added workspace {s}/{s}.\n", .{ p.name, n });
}

fn listClients(c: *Ctx, args: []const [:0]const u8) !void {
    try noArgs(c, "clients", args);
    const clients = try c.db.clients(c.arena);
    if (clients.len == 0) return c.out.writeAll("No clients yet; `shifty client add <name>`.\n");
    for (clients) |cl| try c.out.print("{s}\n", .{cl.name});
}

fn client(c: *Ctx, args: []const [:0]const u8) !void {
    if (args.len != 2 or !std.mem.eql(u8, args[0], "add")) return c.fail("usage: shifty client add <name>", .{});
    const n = try validName(c, args[1]);
    if (try findByName(c, store.Client, try c.db.clients(c.arena), n, "client") != null)
        return c.fail("there's already a client named '{s}'", .{n});
    _ = try c.db.createClient(n, c.now.ts);
    try c.out.print("Added client {s}.\n", .{n});
}

// ── Situ ────────────────────────────────────────────────────────────────────

fn link(c: *Ctx, args: []const [:0]const u8) !void {
    if (args.len == 3 and std.mem.eql(u8, args[0], "--app")) {
        const target = try resolve(c, args[2]);
        try place.linkApp(&c.db, args[1], target, c.now.ts);
        return c.out.print("Linked {s} to {s}.\n", .{ args[1], try label(c, target.project_id, target.workspace_id) });
    }
    if (args.len != 1 or args[0][0] == '-') return c.fail("usage: shifty link <project>[/<workspace>], or link --app <bundle id> <project>", .{});
    const dir = try cwd(c) orelse return c.fail("can't tell which directory this is", .{});
    const target = try resolve(c, args[0]);
    const via = place.linkDir(&c.db, c.io, c.arena, dir, target, c.now.ts) catch |e| switch (e) {
        error.NoWorkspaceId => return c.fail("this Situ repo's {s} has no workspace_id to link to a workspace", .{situ.file_name}),
        else => return e,
    };
    const p = try place.resolve(&c.db, c.io, c.arena, dir, null, null);
    const what = p.root orelse p.folder orelse dir;
    const by: []const u8 = switch (via) {
        .situ => "its Situ ids",
        .git => p.repo.?.remote.?,
        .folder => "its path",
        .app, .keyword => unreachable,
    };
    try c.out.print("Linked {s} ({s}) to {s}.\n", .{ what, by, try label(c, target.project_id, target.workspace_id) });
}

fn unlink(c: *Ctx, args: []const [:0]const u8) !void {
    if (args.len >= 2 and args.len <= 3 and std.mem.eql(u8, args[0], "--app")) {
        const pid = if (args.len == 3) (try resolve(c, args[2])).project_id else null;
        c.db.unlink(place.app_provider, place.app_kind, args[1], pid, c.now.ts) catch |e| switch (e) {
            error.NotFound => return c.fail("{s} isn't linked{s}", .{ args[1], if (pid != null) " to that project" else "" }),
            else => return e,
        };
        return c.out.print("Unlinked {s}.\n", .{args[1]});
    }
    if (args.len > 1 or (args.len == 1 and args[0][0] == '-'))
        return c.fail("usage: shifty unlink [<project>], or unlink --app <bundle id> [<project>]", .{});
    const pid = if (args.len == 1) (try resolve(c, args[0])).project_id else null;
    const dir = try cwd(c) orelse return c.fail("can't tell which directory this is", .{});
    const p = try place.resolve(&c.db, c.io, c.arena, dir, null, null);
    const via = p.via orelse return c.fail("nothing links {s} to a project", .{p.root orelse dir});
    const removed = switch (via) {
        .situ => situ: {
            const m = p.marker.?;
            var any = false;
            if (m.workspace_id) |w| if (gone(c.db.unlink(situ.provider, "workspace", w, pid, c.now.ts))) {
                any = true;
            };
            if (m.project_id) |id| if (gone(c.db.unlink(situ.provider, "project", id, pid, c.now.ts))) {
                any = true;
            };
            break :situ any;
        },
        .git => gone(c.db.unlink(integrations.git.provider, integrations.git.kind_remote, p.repo.?.remote.?, pid, c.now.ts)),
        .folder => gone(c.db.unlink(place.folder_provider, place.folder_kind, p.folder.?, pid, c.now.ts)),
        .app, .keyword => unreachable,
    };
    if (!removed) return c.fail("{s} isn't linked to that project", .{p.folder orelse p.root orelse dir});
    const after = try place.resolve(&c.db, c.io, c.arena, dir, null, null);
    try c.out.print("Unlinked {s}.", .{p.folder orelse p.root orelse dir});
    if (after.target) |t| try c.out.print(" It's still {s}, through {s}.", .{ try label(c, t.project_id, t.workspace_id), @tagName(after.via.?) });
    try c.out.writeAll("\n");
}

/// Whether an unlink removed something.
fn gone(r: store.Error!void) bool {
    r catch return false;
    return true;
}

fn keyword(c: *Ctx, args: []const [:0]const u8) !void {
    const how = "usage: shifty keyword add <project>[/<workspace>] <word>..., or keyword remove <word>...";
    if (args.len < 2) return c.fail(how, .{});
    if (std.mem.eql(u8, args[0], "add")) {
        if (args.len < 3) return c.fail(how, .{});
        const target = try resolve(c, args[1]);
        const raw = try std.mem.join(c.arena, " ", args[2..]);
        const word = try place.linkKeyword(&c.db, c.arena, raw, target, c.now.ts) orelse
            return c.fail("a keyword is 1 to {d} characters on one line", .{place.max_keyword});
        return c.out.print("Windows titled with \"{s}\" are {s}.\n", .{ word, try label(c, target.project_id, target.workspace_id) });
    }
    if (std.mem.eql(u8, args[0], "remove")) {
        const word = try place.keyword(c.arena, try std.mem.join(c.arena, " ", args[1..])) orelse return c.fail(how, .{});
        c.db.unlink(place.keyword_provider, place.keyword_kind, word, null, c.now.ts) catch |e| switch (e) {
            error.NotFound => return c.fail("\"{s}\" isn't a keyword", .{word}),
            else => return e,
        };
        return c.out.print("Removed \"{s}\".\n", .{word});
    }
    return c.fail(how, .{});
}

fn listKeywords(c: *Ctx, args: []const [:0]const u8) !void {
    try noArgs(c, "keywords", args);
    var any = false;
    for (try c.db.links(c.arena)) |l| {
        if (!std.mem.eql(u8, l.provider, place.keyword_provider)) continue;
        any = true;
        try c.out.print("{s}\t{s}\n", .{ l.external_id, try label(c, l.target.project_id, l.target.workspace_id) });
    }
    if (!any) try c.out.writeAll("No keywords yet; `shifty keyword add <project> <word>`.\n");
}

fn cwd(c: *Ctx) !?[]const u8 {
    return std.process.currentPathAlloc(c.io, c.arena) catch null;
}

// ── Shell hook ──────────────────────────────────────────────────────────────

fn hook(c: *Ctx, args: []const [:0]const u8) !void {
    if (args.len != 1) return c.fail("usage: shifty hook <fish|zsh|bash|nvim|rex>", .{});
    // This binary by its full path, so a dev build's hook feeds a dev app.
    const exe = std.process.executablePathAlloc(c.io, c.arena) catch "shifty";
    if (std.mem.eql(u8, args[0], "rex")) return c.out.writeAll(try rex_.script(c.arena, exe));
    const shell = std.meta.stringToEnum(here_.Shell, args[0]) orelse
        return c.fail("unknown shell '{s}'; use fish, zsh, bash, nvim, or rex", .{args[0]});
    try c.out.writeAll(try here_.hook(c.arena, shell, exe));
}

fn rex(c: *Ctx, args: []const [:0]const u8) !void {
    var focus: rex_.Focus = .{ .ts = c.now.ts };
    var it: Args = .{ .c = c, .cmd = "rex", .list = args };
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--session")) {
            focus.session = try it.value(arg);
        } else if (std.mem.eql(u8, arg, "--window")) {
            focus.window = try it.value(arg);
        } else if (std.mem.eql(u8, arg, "--server")) {
            focus.server = try it.value(arg);
        } else return it.unexpected(arg);
    }
    if (focus.session.len == 0 and focus.window.len == 0) return c.fail("rex needs --session or --window", .{});
    const db_path = store.defaultPath(c.arena, c.env) catch return;
    rex_.record(c.io, c.arena, try rex_.pathFor(c.arena, db_path), focus) catch |e|
        return c.fail("can't record the Rex tab: {t}", .{e});
}

fn here(c: *Ctx, args: []const [:0]const u8) !void {
    var dir: ?[]const u8 = null;
    var pid: ?i32 = null;
    var it: Args = .{ .c = c, .cmd = "here", .list = args };
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--pid")) {
            const v = try it.value(arg);
            pid = std.fmt.parseInt(i32, v, 10) catch return c.fail("invalid pid '{s}'", .{v});
        } else if (dir == null and arg[0] != '-') {
            dir = arg;
        } else return it.unexpected(arg);
    }
    const d = dir orelse try cwd(c) orelse return;
    if (!std.fs.path.isAbsolute(d)) return c.fail("here needs an absolute directory", .{});
    const db_path = store.defaultPath(c.arena, c.env) catch return;
    here_.record(c.io, c.arena, try here_.pathFor(c.arena, db_path), .{
        .ts = c.now.ts,
        .pid = pid orelse std.c.getppid(),
        .bundle = c.env.get("__CFBundleIdentifier") orelse "",
        .term = c.env.get("TERM_PROGRAM") orelse "",
        .dir = d,
    }) catch |e| return c.fail("can't record where you are: {t}", .{e});
}

// ── Helpers ─────────────────────────────────────────────────────────────────

/// `project` or `project/workspace`, by name, ignoring case.
fn resolve(c: *Ctx, spec: []const u8) !store.Target {
    const slash = std.mem.indexOfScalar(u8, spec, '/');
    const pname = spec[0 .. slash orelse spec.len];
    const p = try findByName(c, store.Project, try c.db.projects(c.arena), pname, "project") orelse
        return c.fail("no project named '{s}'; `shifty projects` lists them", .{pname});
    const s = slash orelse return .{ .project_id = p.id };

    const wname = spec[s + 1 ..];
    const w = try findByName(c, store.Workspace, try c.db.workspaces(c.arena, p.id), wname, "workspace") orelse
        return c.fail("{s} has no workspace named '{s}'", .{ p.name, wname });
    return .{ .project_id = p.id, .workspace_id = w.id };
}

fn findByName(c: *Ctx, comptime T: type, items: []const T, name: []const u8, comptime noun: []const u8) !?T {
    var found: ?T = null;
    for (items) |item| if (std.ascii.eqlIgnoreCase(item.name, name)) {
        if (found != null) return c.fail("more than one " ++ noun ++ " is named '{s}'", .{name});
        found = item;
    };
    return found;
}

fn findById(comptime T: type, items: []const T, id: Uuid) ?T {
    for (items) |item| if (item.id.eql(id)) return item;
    return null;
}

/// Names are typed back as `project/workspace`, so they can't hold a slash.
fn validName(c: *Ctx, name: []const u8) ![]const u8 {
    const n = std.mem.trim(u8, name, " \t");
    if (n.len == 0) return c.fail("name can't be empty", .{});
    if (std.mem.indexOfScalar(u8, n, '/') != null) return c.fail("name can't contain '/': '{s}'", .{n});
    return n;
}

fn isColor(s: []const u8) bool {
    if (s.len != 7 or s[0] != '#') return false;
    for (s[1..]) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

fn running(brks: []const store.Break) ?store.Break {
    for (brks) |b| if (b.out_ts == null) return b;
    return null;
}

/// `project/workspace`, `project`, or `(unassigned)`.
fn label(c: *Ctx, project_id: ?Uuid, workspace_id: ?Uuid) ![]const u8 {
    const names: Names = try .load(&c.db, c.arena);
    return names.label(c.arena, project_id, workspace_id);
}

/// A duration as a string, for padding with `{s: >7}` (`{f}` can't pad).
fn padDur(c: *Ctx, secs: i64) ![]const u8 {
    return std.fmt.allocPrint(c.arena, "{f}", .{dur(secs)});
}

fn noArgs(c: *Ctx, comptime cmd: []const u8, args: []const [:0]const u8) !void {
    if (args.len != 0) return c.fail(cmd ++ " takes no arguments", .{});
}

fn eqlAny(s: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

const Args = struct {
    c: *Ctx,
    cmd: []const u8,
    list: []const [:0]const u8,
    i: usize = 0,

    fn next(a: *Args) ?[:0]const u8 {
        if (a.i == a.list.len) return null;
        defer a.i += 1;
        return a.list[a.i];
    }

    fn value(a: *Args, flag: []const u8) Error![:0]const u8 {
        return a.next() orelse a.c.fail("{s} requires a value", .{flag});
    }

    fn peek(a: *Args) ?[:0]const u8 {
        return if (a.i == a.list.len) null else a.list[a.i];
    }

    /// A time of day, joining a following `AM`/`PM` so `9:30 PM` works
    /// without quotes.
    fn time(a: *Args, flag: []const u8) Error!core.time.Time {
        var str: []const u8 = try a.value(flag);
        if (a.peek()) |m| if (std.ascii.eqlIgnoreCase(m, "am") or std.ascii.eqlIgnoreCase(m, "pm")) {
            _ = a.next();
            str = std.fmt.allocPrint(a.c.arena, "{s} {s}", .{ str, m }) catch return a.c.fail("out of memory", .{});
        };
        return core.time.Time.fromStr(str) catch a.c.fail("invalid time '{s}' for {s}", .{ str, flag });
    }

    fn unexpected(a: *Args, arg: []const u8) Error {
        return a.c.fail("{s}: unexpected argument '{s}'", .{ a.cmd, arg });
    }
};

const testing = std.testing;

test "parseYmd" {
    try testing.expectEqual(0, parseYmd("1970-01-01"));
    try testing.expectEqual(20401, parseYmd("2025-11-09"));
    try testing.expectEqual(null, parseYmd("2025-13-01"));
    try testing.expectEqual(null, parseYmd("nov 9"));
}

test "isCommand" {
    try testing.expect(isCommand("tui"));
    try testing.expect(isCommand("start"));
    try testing.expect(isCommand("break"));
    try testing.expect(isCommand("goal"));
    try testing.expect(isCommand("meetings"));
    try testing.expect(!isCommand("-s"));
    try testing.expect(!isCommand("9am"));
}

test "tui takes no arguments" {
    var err_buf: [128]u8 = undefined;
    var err: Io.Writer = .fixed(&err_buf);
    var c: Ctx = .{
        .io = testing.io,
        .arena = testing.allocator,
        .env = undefined,
        .out = undefined,
        .err = &err,
        .db = undefined,
        .now = undefined,
        .tz_buf = undefined,
    };
    try noArgs(&c, "tui", &.{});
    try testing.expectError(error.Reported, noArgs(&c, "tui", &.{"--week"}));
    try testing.expectEqualStrings("shifty: tui takes no arguments\n", err.buffered());
}
