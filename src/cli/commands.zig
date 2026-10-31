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
const situ = @import("integrations").situ;

pub const usage =
    \\Commands:
    \\  status                     What's running: shift, break, timer
    \\  in [-s <time>] [-l <len>]  Clock in (default: now, 8h)
    \\  out                        Clock out
    \\  break                      Start or end a break
    \\  start [<project>[/<workspace>]] [-n <note>]
    \\                             Track time. With no project, use the
    \\                             linked Situ repo you're in, if any
    \\  stop                       Stop tracking
    \\  log [--week]               Time by project, today or the last 7 days
    \\  projects                   List projects and their workspaces
    \\  project add <name> [--client <name>] [--color <#rrggbb>]
    \\  project rename <name> <new name>
    \\  project color <name> <#rrggbb|none>
    \\  project delete <name>     Its time stays, unassigned
    \\  workspace add <project> <name>
    \\  clients                    List clients
    \\  client add <name>
    \\  link <project>[/<workspace>]
    \\                             Link the Situ repo you're in to a project
    \\
;

const Command = enum { status, in, out, @"break", start, stop, log, projects, project, workspace, clients, client, link };

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

    const rest = args[1..];
    switch (std.meta.stringToEnum(Command, args[0]).?) {
        .status => try status(&c, rest),
        .in => try clockIn(&c, rest),
        .out => try clockOut(&c, rest),
        .@"break" => try toggleBreak(&c, rest),
        .start => try start(&c, rest),
        .stop => try stop(&c, rest),
        .log => try log(&c, rest),
        .projects => try listProjects(&c, rest),
        .project => try project(&c, rest),
        .workspace => try workspace(&c, rest),
        .clients => try listClients(&c, rest),
        .client => try client(&c, rest),
        .link => try link(&c, rest),
    }
}

// ── Shift ───────────────────────────────────────────────────────────────────

fn status(c: *Ctx, args: []const [:0]const u8) !void {
    try noArgs(c, "status", args);
    const now = c.now.ts;

    if (try c.db.currentShift(c.arena)) |shift| {
        const brks = try c.db.breaks(c.arena, shift.id);
        const out = store.clockOut(shift, brks, now);
        try c.out.print("On shift since {f}. Clock out at {f}", .{ clock(shift.in_ts, shift.utc_offset_secs), clock(out, c.now.utc_offset_secs) });
        if (out > now) try c.out.print(" ({f} left).\n", .{dur(out - now)}) else try c.out.print(" ({f} ago).\n", .{dur(now - out)});
        if (running(brks)) |b| try c.out.print("On break since {f} ({f}).\n", .{ clock(b.in_ts, shift.utc_offset_secs), dur(now - b.in_ts) });
    } else try c.out.writeAll("Off shift.\n");

    if (try c.db.runningEntry(c.arena)) |e| {
        try c.out.print("Tracking {s} since {f} ({f})", .{ try label(c, e.project_id, e.workspace_id), clock(e.in_ts, e.utc_offset_secs), dur(now - e.in_ts) });
        if (e.note) |n| try c.out.print(": {s}", .{n});
        try c.out.writeAll(".\n");
    } else try c.out.writeAll("Not tracking.\n");
}

fn clockIn(c: *Ctx, args: []const [:0]const u8) !void {
    var start_time: ?time.Time = null;
    var length: ?i64 = null;
    var it: Args = .{ .c = c, .cmd = "in", .list = args };
    while (it.next()) |arg| {
        if (eqlAny(arg, &.{ "-s", "--start" })) {
            const v = try it.value(arg);
            start_time = time.Time.fromStr(v) catch return c.fail("invalid time '{s}' for {s}", .{ v, arg });
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

    _ = c.db.startShift(target, at) catch |e| switch (e) {
        error.Conflict => {
            const shift = (try c.db.currentShift(c.arena)).?;
            return c.fail("already on shift since {f}; `shifty out` first", .{clock(shift.in_ts, shift.utc_offset_secs)});
        },
        else => return e,
    };
    try c.out.print("Clocked in at {f}. Clock out at {f}.\n", .{ clock(at.ts, at.utc_offset_secs), clock(at.ts + target, at.utc_offset_secs) });
}

fn defaultShiftSecs(c: *Ctx) !i64 {
    const v = try c.db.setting(c.arena, "default_shift_secs") orelse return default_shift_secs;
    return std.fmt.parseInt(i64, v, 10) catch default_shift_secs;
}

fn clockOut(c: *Ctx, args: []const [:0]const u8) !void {
    try noArgs(c, "out", args);
    const now = c.now.ts;
    const shift = try c.db.currentShift(c.arena) orelse return c.fail("not on shift", .{});
    const brks = try c.db.breaks(c.arena, shift.id);
    _ = try c.db.endShift(now);

    var worked = now - shift.in_ts;
    for (brks) |b| worked -= @max(0, @min(b.out_ts orelse now, now) - @max(b.in_ts, shift.in_ts));
    try c.out.print("Clocked out at {f}, {f} worked.\n", .{ clock(now, c.now.utc_offset_secs), dur(@max(0, worked)) });
}

fn toggleBreak(c: *Ctx, args: []const [:0]const u8) !void {
    try noArgs(c, "break", args);
    const now = c.now.ts;
    const shift = try c.db.currentShift(c.arena) orelse return c.fail("not on shift; `shifty in` first", .{});

    if (running(try c.db.breaks(c.arena, shift.id))) |b| {
        if (try c.db.endBreak(now) == null) {
            try c.out.writeAll("Break under a minute; dropped.\n");
        } else {
            const out = store.clockOut(shift, try c.db.breaks(c.arena, shift.id), now);
            try c.out.print("Back after {f}. Clock out at {f}.\n", .{ dur(now - b.in_ts), clock(out, c.now.utc_offset_secs) });
        }
        return;
    }

    const tracking = try c.db.runningEntry(c.arena);
    _ = try c.db.startBreak(now);
    try c.out.print("On break since {f}.", .{clock(now, c.now.utc_offset_secs)});
    if (tracking) |e| try c.out.print(" Stopped tracking {s}.", .{try label(c, e.project_id, e.workspace_id)});
    try c.out.writeAll("\n");
}

// ── Tracking ────────────────────────────────────────────────────────────────

fn start(c: *Ctx, args: []const [:0]const u8) !void {
    var spec: ?[]const u8 = null;
    var note: ?[]const u8 = null;
    var it: Args = .{ .c = c, .cmd = "start", .list = args };
    while (it.next()) |arg| {
        if (eqlAny(arg, &.{ "-n", "--note" })) {
            note = try it.value(arg);
        } else if (spec == null and arg[0] != '-') {
            spec = arg;
        } else return it.unexpected(arg);
    }

    var target: ?store.Target = null;
    var unlinked: ?situ.Marker = null;
    if (spec) |s| {
        target = try resolve(c, s);
    } else if (try findMarker(c)) |m| {
        target = try situ.linked(&c.db, m);
        if (target == null) unlinked = m;
    }

    const prev = try c.db.runningEntry(c.arena);
    _ = c.db.startEntry(.{
        .project_id = if (target) |t| t.project_id else null,
        .workspace_id = if (target) |t| t.workspace_id else null,
        .source = .cli,
        .note = note,
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
    try c.out.print("Tracking {s} since {f}.\n", .{ name, clock(c.now.ts, c.now.utc_offset_secs) });
    if (unlinked) |m| try c.out.print("This Situ repo ({s}) isn't linked to a project; `shifty link <project>` to track it.\n", .{m.root});
}

fn stop(c: *Ctx, args: []const [:0]const u8) !void {
    try noArgs(c, "stop", args);
    const e = try c.db.runningEntry(c.arena) orelse return c.out.writeAll("Not tracking.\n");
    const name = try label(c, e.project_id, e.workspace_id);
    if (try c.db.stopEntry(c.now.ts) == null) {
        try c.out.print("Dropped {s}: stopped the second it started.\n", .{name});
    } else try c.out.print("Stopped {s} after {f}.\n", .{ name, dur(c.now.ts - e.in_ts) });
}

fn log(c: *Ctx, args: []const [:0]const u8) !void {
    var days: i64 = 1;
    var it: Args = .{ .c = c, .cmd = "log", .list = args };
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--week")) days = 7 else return it.unexpected(arg);
    }

    const now = c.now.ts;
    const today = fmt.dayStart(now, c.now.utc_offset_secs);
    const from = today - (days - 1) * std.time.s_per_day;
    const entries = try c.db.entriesBetween(c.arena, from, now + 1);
    if (entries.len == 0) return c.out.writeAll(if (days == 1) "Nothing tracked today.\n" else "Nothing tracked this week.\n");

    const names: Names = try .load(&c.db, c.arena);
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
        if (e.note) |n| try c.out.print("  {s}", .{n});
        try c.out.writeAll("\n");
    }

    const totals = try store.report.totals(c.arena, names, entries, from, now);
    try c.out.writeAll("\nBy project\n");
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
    try c.out.print("\n  {s: >7}  total\n", .{try padDur(c, totals.total)});
}

// ── Organization ────────────────────────────────────────────────────────────

fn listProjects(c: *Ctx, args: []const [:0]const u8) !void {
    try noArgs(c, "projects", args);
    const projects = try c.db.projects(c.arena);
    if (projects.len == 0) return c.out.writeAll("No projects yet; `shifty project add <name>`.\n");
    const clients = try c.db.clients(c.arena);
    for (projects) |p| {
        try c.out.print("{s}", .{p.name});
        if (p.client_id) |cid| if (findById(store.Client, clients, cid)) |cl| try c.out.print("  ({s})", .{cl.name});
        try c.out.writeAll("\n");
        for (try c.db.workspaces(c.arena, p.id)) |w| try c.out.print("  /{s}\n", .{w.name});
    }
}

const project_usage =
    \\usage: shifty project add <name> [--client <name>] [--color <#rrggbb>]
    \\       shifty project rename <name> <new name>
    \\       shifty project color <name> <#rrggbb|none>
    \\       shifty project delete <name>
;

fn project(c: *Ctx, args: []const [:0]const u8) !void {
    const Sub = enum { add, rename, color, delete };
    const sub = if (args.len > 0) std.meta.stringToEnum(Sub, args[0]) else null;
    switch (sub orelse return c.fail(project_usage, .{})) {
        .add => try addProject(c, args),
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
    var color: ?[]const u8 = null;
    var it: Args = .{ .c = c, .cmd = "project add", .list = args[1..] };
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--client")) {
            client_name = try it.value(arg);
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

    _ = try c.db.createProject(.{ .name = n, .client_id = client_id, .color = color }, c.now.ts);
    try c.out.print("Added project {s}.\n", .{n});
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
    if (args.len != 1) return c.fail("usage: shifty link <project>[/<workspace>]", .{});
    const m = try findMarker(c) orelse return c.fail("not in a Situ repo (no {s} here or above)", .{situ.file_name});
    const target = try resolve(c, args[0]);
    situ.link(&c.db, m, target, c.now.ts) catch |e| switch (e) {
        error.NoProjectId => return c.fail("{s}/{s} has no project_id", .{ m.root, situ.file_name }),
        error.NoWorkspaceId => return c.fail("{s}/{s} has no workspace_id", .{ m.root, situ.file_name }),
        else => return e,
    };
    try c.out.print("Linked {s} to {s}.\n", .{ m.root, try label(c, target.project_id, target.workspace_id) });
}

fn findMarker(c: *Ctx) !?situ.Marker {
    const cwd = std.process.currentPathAlloc(c.io, c.arena) catch return null;
    return situ.find(c.io, c.arena, cwd);
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

    fn unexpected(a: *Args, arg: []const u8) Error {
        return a.c.fail("{s}: unexpected argument '{s}'", .{ a.cmd, arg });
    }
};

const testing = std.testing;

test "isCommand" {
    try testing.expect(isCommand("start"));
    try testing.expect(isCommand("break"));
    try testing.expect(!isCommand("-s"));
    try testing.expect(!isCommand("9am"));
}
