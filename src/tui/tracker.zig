//! The TUI's main screen: the shift, what's being tracked, and today's time.
//! It reads the shared store and reloads every second, so changes from the
//! CLI or the menu bar show up here, and every key acts on the store.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const core = @import("core");
const local = core.local;
const fmt = core.fmt;
const store = @import("store");
const Store = store.Store;
const report = store.report;
const sheet = store.sheet;
const integrations = @import("integrations");
const place = integrations.place;
const clock_link = integrations.clock_link;
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Calculator = @import("calc.zig").Calculator;
const Timesheet = @import("timesheet.zig").Timesheet;
const ui = @import("ui.zig");
const Painter = ui.Painter;
const bold = ui.bold;
const dim = ui.dim;
const green = ui.green;
const yellow = ui.yellow;
const red = ui.red;
const cyan = ui.cyan;

const reload_ms = 1000;
const max_width = 76;
/// Where values start after a row label like "Shift".
const value_col = 10;
const default_shift_secs = 8 * std.time.s_per_hour;

const Mode = enum { track, pick, note, confirm_out, calc, sheet };

/// Everything the screen shows, read in one go.
const Snap = struct {
    now: local.Stamp,
    names: report.Names,
    shift: ?store.Shift = null,
    breaks: []const store.Break = &.{},
    /// Clock out, lunch still to come included.
    clock_out: i64 = 0,
    /// Lunch time clock out counts before you've had it.
    lunch_ahead: i64 = 0,
    lunch: ?sheet.Lunch = null,
    plan: ?sheet.Plan = null,
    on_break: ?store.Break = null,
    running: ?store.Entry = null,
    /// Local midnight today.
    from: i64,
    today: []const store.Entry = &.{},
    totals: report.Totals = .{ .by_project = &.{}, .by_client = &.{}, .any_client = false, .total = 0 },
    /// What the repo or folder the TUI started in is linked to.
    here: ?store.Target = null,
    /// This week against the weekly goal, if there is one.
    goal: ?sheet.Goal = null,
};

pub const Tracker = struct {
    gpa: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    db: *Store,
    /// The directory the TUI started in.
    dir: ?[]const u8,
    calc: *Calculator,
    sheet: *Timesheet,

    /// Snapshots alternate between these, so a failed reload keeps the
    /// last good one on screen.
    arenas: [2]std.heap.ArenaAllocator,
    live: u1 = 0,
    snap: ?Snap = null,

    mode: Mode = .track,
    filter: vxfw.TextField,
    note: vxfw.TextField,
    selected: usize = 0,
    /// The clock link `l` opens: the one the last clock in, out, or lunch
    /// offered.
    link: ?clock_link.Which = null,

    msg_buf: [200]u8 = undefined,
    msg: ?struct { len: usize, err: bool } = null,

    pub fn init(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, db: *Store, dir: ?[]const u8, calc: *Calculator, ts: *Timesheet) Tracker {
        return .{
            .gpa = gpa,
            .io = io,
            .env = env,
            .db = db,
            .dir = dir,
            .calc = calc,
            .sheet = ts,
            .arenas = .{ .init(gpa), .init(gpa) },
            .filter = .init(gpa),
            .note = .init(gpa),
        };
    }

    /// Hooks up callbacks that point back at `self`; call once it's at its
    /// final address.
    pub fn bind(self: *Tracker) void {
        self.filter.userdata = self;
        self.filter.onChange = onFilterChange;
    }

    pub fn deinit(self: *Tracker) void {
        self.filter.deinit();
        self.note.deinit();
        for (&self.arenas) |*a| a.deinit();
    }

    pub fn widget(self: *Tracker) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    // ── Data ──────────────────────────────────────────────────────────────

    fn reload(self: *Tracker) !void {
        const next = self.live +% 1;
        const arena = &self.arenas[next];
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();

        var tz_buf: local.TzBuf = undefined;
        var now: local.Stamp = .now(self.io, self.env.get("TZ"), &tz_buf);
        if (now.tz) |tz| now.tz = try a.dupe(u8, tz);
        _ = try self.db.closeStaleShift(a, now.ts);

        var snap: Snap = .{
            .now = now,
            .names = try .load(self.db, a),
            .from = fmt.dayStart(now.ts, now.utc_offset_secs),
            .lunch = try sheet.Lunch.load(self.db, a),
        };
        if (try self.db.currentShift(a)) |shift| {
            const brks = try self.db.breaks(a, shift.id);
            snap.shift = shift;
            snap.breaks = brks;
            snap.clock_out = store.clockOut(shift, brks, now.ts);
            if (snap.lunch) |l| {
                snap.plan = try l.planFor(a, shift, brks, now.ts);
                snap.lunch_ahead = l.ahead(snap.plan, now.ts);
                snap.clock_out += snap.lunch_ahead;
            }
            for (brks) |b| if (b.out_ts == null) {
                snap.on_break = b;
            };
        }
        snap.running = try self.db.runningEntry(a);
        snap.today = try self.db.entriesBetween(a, snap.from, now.ts + 1);
        snap.totals = try report.totals(a, snap.names, snap.today, snap.from, now.ts);
        if (self.dir) |d| snap.here = (try place.resolve(self.db, self.io, a, d, null, null)).target;
        // The week is only read with a goal to measure it against.
        if (try sheet.weeklyGoal(self.db, a) != null) {
            const first = sheet.weekStart(now.ts, now.utc_offset_secs, try sheet.weekStartDay(self.db, a));
            const w: sheet.Week = try .load(self.db, a, sheet.weekDays(first, local.utcOffset));
            snap.goal = try w.goal(a, now.ts);
        }

        self.snap = snap;
        self.live = next;
    }

    fn refresh(self: *Tracker) void {
        self.reload() catch |e| self.flash(true, "Can't read the database: {t}", .{e});
    }

    fn stamp(self: *Tracker, tz_buf: *local.TzBuf) local.Stamp {
        return .now(self.io, self.env.get("TZ"), tz_buf);
    }

    fn flash(self: *Tracker, err: bool, comptime f: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.msg_buf, f, args) catch blk: {
            @memcpy(self.msg_buf[self.msg_buf.len - 3 ..], "...");
            break :blk self.msg_buf[0..];
        };
        self.msg = .{ .len = s.len, .err = err };
    }

    /// Adds "l opens the timeclock" to the message, if a link is set.
    fn offerLink(self: *Tracker, which: clock_link.Which) void {
        var buf: [1024]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        _ = (clock_link.get(self.db, fba.allocator(), which) catch null) orelse return;
        self.link = which;
        const m = self.msg orelse return;
        const hint = "  l opens the timeclock.";
        if (m.len + hint.len > self.msg_buf.len) return;
        @memcpy(self.msg_buf[m.len..][0..hint.len], hint);
        self.msg.?.len += hint.len;
    }

    fn openLink(self: *Tracker) void {
        const snap = self.snap orelse return;
        // What you'd punch next: out while on shift, in while off.
        const which = self.link orelse if (snap.shift != null) clock_link.Which.out else .in;
        var buf: [1024]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const url = (clock_link.get(self.db, fba.allocator(), which) catch null) orelse
            return self.flash(false, "No clock link; set one in the menu bar's Settings, or the clock_out_link setting.", .{});
        clock_link.open(self.io, url) catch |e| return self.flash(true, "Couldn't open {s}: {t}", .{ url, e });
        self.flash(false, "Opened the clock-{s} link.", .{@tagName(which)});
        self.link = null;
    }

    // ── Actions ───────────────────────────────────────────────────────────

    fn start(self: *Tracker, opt: ui.Option) void {
        var tz_buf: local.TzBuf = undefined;
        _ = self.db.startEntry(.{
            .project_id = if (opt.target) |t| t.project_id else null,
            .workspace_id = if (opt.target) |t| t.workspace_id else null,
            .source = .tui,
        }, self.stamp(&tz_buf)) catch |e| return self.flash(true, "Couldn't start: {t}", .{e});
        self.flash(false, "Tracking {s}.", .{opt.label});
        self.refresh();
    }

    fn stop(self: *Tracker) void {
        const snap = self.snap orelse return;
        const e = snap.running orelse return self.flash(false, "Not tracking.", .{});
        var tz_buf: local.TzBuf = undefined;
        const now = self.stamp(&tz_buf).ts;
        var name_buf: [128]u8 = undefined;
        const name = self.labelInto(&name_buf, e.project_id, e.workspace_id);
        const stopped = self.db.stopEntry(now) catch |err| return self.flash(true, "Couldn't stop: {t}", .{err});
        if (stopped == null) {
            self.flash(false, "Dropped {s}: stopped the second it started.", .{name});
        } else self.flash(false, "Stopped {s} after {f}.", .{ name, fmt.dur(now - e.in_ts) });
        self.refresh();
    }

    fn saveNote(self: *Tracker) !void {
        const snap = self.snap orelse return;
        const e = snap.running orelse return self.flash(false, "Not tracking anymore.", .{});
        var tmp: std.heap.ArenaAllocator = .init(self.gpa);
        defer tmp.deinit();
        const text = std.mem.trim(u8, try ui.fieldText(tmp.allocator(), &self.note), " \t");
        var tz_buf: local.TzBuf = undefined;
        self.db.setEntryNote(e.id, if (text.len == 0) null else text, self.stamp(&tz_buf).ts) catch |err|
            return self.flash(true, "Couldn't save the note: {t}", .{err});
        self.refresh();
    }

    fn toggleBreak(self: *Tracker) void {
        const snap = self.snap orelse return;
        var tz_buf: local.TzBuf = undefined;
        const now = self.stamp(&tz_buf).ts;
        if (snap.on_break) |b| {
            const lunch = if (snap.plan) |p| p.isLunch(b.in_ts) else false;
            const ended = self.db.endBreak(now) catch |e| return self.flash(true, "Couldn't end the break: {t}", .{e});
            if (ended == null) {
                self.flash(false, "Break under a minute; dropped.", .{});
            } else {
                self.refresh();
                const out = if (self.snap) |s| s.clock_out else now;
                self.flash(false, "Back from {s} after {f}. Clock out at {f}.", .{ if (lunch) "lunch" else "the break", fmt.dur(now - b.in_ts), fmt.clock(out, snap.now.utc_offset_secs) });
                if (lunch and snap.lunch.?.clock_link) self.offerLink(.in);
                return;
            }
        } else {
            _ = self.db.startBreak(now) catch |e| switch (e) {
                error.NotFound => return self.flash(false, "Not on shift; press i to clock in.", .{}),
                else => return self.flash(true, "Couldn't start a break: {t}", .{e}),
            };
            self.refresh();
            const s = self.snap orelse return;
            const lunch = if (s.plan) |p| p.isLunch(now) else false;
            if (lunch) {
                self.flash(false, "On lunch. Clock out holds until you've had {f}.", .{fmt.dur(s.lunch.?.minimum_secs)});
                if (s.lunch.?.clock_link) self.offerLink(.out);
            } else self.flash(false, "On break.", .{});
            return;
        }
        self.refresh();
    }

    fn clockIn(self: *Tracker) void {
        var tz_buf: local.TzBuf = undefined;
        const at = self.stamp(&tz_buf);
        const target = self.defaultShiftSecs();
        const shift_id = self.db.startShift(target, at) catch |e| switch (e) {
            error.Conflict => return self.flash(false, "Already on shift.", .{}),
            else => return self.flash(true, "Couldn't clock in: {t}", .{e}),
        };
        _ = shift_id;
        // The day's break presets are on the shift, pushing clock out later.
        self.refresh();
        const snap = self.snap orelse return;
        const n = snap.breaks.len;
        if (n == 0) {
            self.flash(false, "Clocked in. Clock out at {f}.", .{fmt.clock(snap.clock_out, at.utc_offset_secs)});
        } else {
            self.flash(false, "Clocked in with {d} planned break{s}. Clock out at {f}.", .{ n, if (n == 1) "" else "s", fmt.clock(snap.clock_out, at.utc_offset_secs) });
        }
        self.offerLink(.in);
    }

    fn defaultShiftSecs(self: *Tracker) i64 {
        var buf: [64]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const v = (self.db.setting(fba.allocator(), "default_shift_secs") catch null) orelse return default_shift_secs;
        return std.fmt.parseInt(i64, v, 10) catch default_shift_secs;
    }

    fn clockOut(self: *Tracker) void {
        var tz_buf: local.TzBuf = undefined;
        const at = self.stamp(&tz_buf);
        _ = self.db.endShift(at.ts) catch |e| return self.flash(true, "Couldn't clock out: {t}", .{e});
        self.flash(false, "Clocked out at {f}.", .{fmt.clock(at.ts, at.utc_offset_secs)});
        self.offerLink(.out);
        self.refresh();
    }

    fn labelInto(self: *Tracker, buf: []u8, project_id: ?core.Uuid, workspace_id: ?core.Uuid) []const u8 {
        const snap = self.snap orelse return "";
        var fba: std.heap.FixedBufferAllocator = .init(buf);
        return snap.names.label(fba.allocator(), project_id, workspace_id) catch "(name too long)";
    }

    // ── Events ────────────────────────────────────────────────────────────

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Tracker = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => {
                self.refresh();
                try ctx.requestFocus(self.widget());
                try ctx.tick(reload_ms, self.widget());
            },
            .tick => {
                self.refresh();
                if (self.mode == .sheet) self.sheet.refresh();
                ctx.redraw = true;
                try ctx.tick(reload_ms, self.widget());
            },
            .key_press => |key| try self.onKey(ctx, key),
            else => {},
        }
    }

    fn onKey(self: *Tracker, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        if (key.matches('c', .{ .ctrl = true })) {
            ctx.quit = true;
            return;
        }
        const esc = key.matches(vaxis.Key.escape, .{});
        const enter = key.matches(vaxis.Key.enter, .{});

        switch (self.mode) {
            .calc => if (esc) return self.setMode(ctx, .track),
            // The timesheet keeps the keys it uses; the rest come here.
            .sheet => {
                if (esc) {
                    self.refresh();
                    return self.setMode(ctx, .track);
                }
                if (key.matches('q', .{})) ctx.quit = true;
            },
            .pick => {
                if (esc) return self.setMode(ctx, .track);
                if (ui.movePick(key, &self.selected)) {
                    ctx.consumeAndRedraw();
                } else if (enter) {
                    var tmp: std.heap.ArenaAllocator = .init(self.gpa);
                    defer tmp.deinit();
                    const opts = try self.options(tmp.allocator());
                    if (opts.len == 0) return ctx.consumeEvent();
                    self.start(opts[@min(self.selected, opts.len - 1)]);
                    return self.setMode(ctx, .track);
                }
            },
            .note => {
                if (esc) return self.setMode(ctx, .track);
                if (enter) {
                    try self.saveNote();
                    return self.setMode(ctx, .track);
                }
            },
            .confirm_out => {
                if (key.matches('y', .{}) or enter) self.clockOut();
                return self.setMode(ctx, .track);
            },
            .track => {
                self.msg = null;
                if (key.matches('q', .{})) {
                    ctx.quit = true;
                    return;
                } else if (key.matches('s', .{})) {
                    self.filter.clearAndFree();
                    self.selected = 0;
                    return self.setMode(ctx, .pick);
                } else if (key.matches('x', .{})) {
                    self.stop();
                } else if (key.matches('n', .{})) {
                    const e = (self.snap orelse return).running orelse {
                        self.flash(false, "Not tracking; press s to start.", .{});
                        return ctx.consumeAndRedraw();
                    };
                    self.note.clearAndFree();
                    if (e.note) |n| try self.note.insertSliceAtCursor(n);
                    return self.setMode(ctx, .note);
                } else if (key.matches('b', .{})) {
                    self.toggleBreak();
                } else if (key.matches('i', .{})) {
                    self.clockIn();
                } else if (key.matches('o', .{})) {
                    if ((self.snap orelse return).shift == null) {
                        self.flash(false, "Not on shift.", .{});
                    } else return self.setMode(ctx, .confirm_out);
                } else if (key.matches('t', .{})) {
                    self.sheet.show(if (self.snap) |s| s.here else null);
                    return self.setMode(ctx, .sheet);
                } else if (key.matches('e', .{})) {
                    const snap = self.snap orelse return;
                    const shift = snap.shift orelse {
                        self.flash(false, "Not on shift; press i to clock in, or t for the timesheet.", .{});
                        return ctx.consumeAndRedraw();
                    };
                    self.mode = .sheet;
                    try self.sheet.editShift(ctx, snap.here, shift.id);
                    return ctx.consumeAndRedraw();
                } else if (key.matches('l', .{})) {
                    self.openLink();
                } else if (key.matches('c', .{})) {
                    return self.setMode(ctx, .calc);
                } else return ctx.consumeAndRedraw();
                ctx.consumeAndRedraw();
            },
        }
    }

    fn setMode(self: *Tracker, ctx: *vxfw.EventContext, mode: Mode) !void {
        self.mode = mode;
        try ctx.requestFocus(switch (mode) {
            .pick => self.filter.widget(),
            .note => self.note.widget(),
            .calc => self.calc.focusedWidget(),
            .sheet => self.sheet.focusedWidget(),
            .track, .confirm_out => self.widget(),
        });
        ctx.consumeAndRedraw();
    }

    fn onFilterChange(ptr: ?*anyopaque, _: *vxfw.EventContext, _: []const u8) anyerror!void {
        const self: *Tracker = @ptrCast(@alignCast(ptr.?));
        self.selected = 0;
    }

    fn options(self: *Tracker, a: Allocator) ![]ui.Option {
        const snap = self.snap orelse return &.{};
        return ui.options(a, snap.names, snap.here, try ui.fieldText(a, &self.filter));
    }

    // ── Drawing ───────────────────────────────────────────────────────────

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Tracker = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *Tracker, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        if (self.mode == .calc or self.mode == .sheet) {
            const child = if (self.mode == .calc) self.calc.widget() else self.sheet.widget();
            const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
            children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try child.draw(ctx) };
            return .{ .size = size, .widget = self.widget(), .buffer = &.{}, .children = children };
        }

        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        const width = @min(size.width -| 4, max_width);
        var p: Painter = .{ .ctx = ctx, .surface = surface, .left = (size.width -| width) / 2, .width = width, .height = size.height };

        const snap = self.snap orelse {
            p.put("Loading...", dim);
            return p.surface;
        };
        const names = snap.names;
        const a = ctx.arena;
        const now = snap.now;

        // Title
        p.put("Shifty", bold);
        try p.right(try p.fmt("{f}", .{fmt.date(now.ts, now.utc_offset_secs)}), dim);
        p.nl(2);

        // Shift
        p.put("Shift", bold);
        p.col = value_col;
        if (snap.shift) |shift| {
            try p.print(.{}, "On since {f}", .{fmt.clock(shift.in_ts, shift.utc_offset_secs)});
            p.put("  ·  out ", dim);
            try p.print(bold, "{f}", .{fmt.clock(snap.clock_out, now.utc_offset_secs)});
            if (snap.clock_out >= now.ts) {
                try p.print(dim, "  ·  {f} left", .{fmt.dur(snap.clock_out - now.ts)});
            } else try p.print(yellow, "  ·  {f} over", .{fmt.dur(now.ts - snap.clock_out)});
            p.nl(1);
            p.col = value_col;
            try drawBar(&p, snap);
            if (snap.on_break) |b| {
                p.nl(1);
                p.col = value_col;
                const what = if (snap.plan) |pl| (if (pl.isLunch(b.in_ts)) "On lunch" else "On break") else "On break";
                try p.print(yellow, "{s} since {f}  ·  {f}", .{ what, fmt.clock(b.in_ts, shift.utc_offset_secs), fmt.dur(now.ts - b.in_ts) });
            }
            if (snap.plan) |plan| {
                p.nl(1);
                p.put("Lunch", bold);
                p.col = value_col;
                try drawLunch(&p, snap, plan, shift.utc_offset_secs);
            }
        } else p.put("Off shift", dim);
        p.nl(1);

        // Week
        if (snap.goal) |g| {
            p.put("Week", bold);
            p.col = value_col;
            try drawGoal(&p, g, now.utc_offset_secs);
            p.nl(1);
        }

        // Now
        p.put("Now", bold);
        p.col = value_col;
        if (snap.running) |e| {
            p.put("● ", green);
            p.put(try names.label(a, e.project_id, e.workspace_id), ui.projectStyle(names, e.project_id, true));
            try p.print(.{}, "  {f}", .{fmt.dur(now.ts - e.in_ts)});
            if (e.kind == .meeting) {
                try p.print(cyan, "  Meeting: {s}", .{e.note orelse "untitled"});
            } else if (e.note) |n| try p.print(dim, "  {s}", .{n});
        } else p.put("Not tracking", dim);
        p.nl(2);

        // Footer: the keys, then a message, at the bottom.
        const hints: []const ui.Hint = &.{
            .{ "s", "start" }, .{ "x", "stop" },  .{ "n", "note" },  .{ "b", "break" },
            .{ "i", "in" },    .{ "o", "out" },   .{ "e", "edit shift" }, .{ "t", "timesheet" },
            .{ "l", "clock link" }, .{ "c", "calculator" }, .{ "q", "quit" },
        };
        const footer_row = size.height -| (1 + ui.hintRows(ctx, hints, width));

        switch (self.mode) {
            .pick => try self.drawPicker(&p, &children, a, footer_row),
            else => try drawToday(&p, snap, a, footer_row),
        }

        // Keys, or the note field / confirmation in their place.
        p.row = footer_row;
        p.col = 0;
        switch (self.mode) {
            .track, .calc, .sheet => ui.drawHints(&p, hints),
            .pick => p.put("enter start  ↑↓ choose  esc cancel", dim),
            .note => {
                p.put("Note ", bold);
                try children.append(a, try p.field(self.note.widget(), 5, width -| 5));
            },
            .confirm_out => try p.print(yellow, "Clock out at {f}?  y yes  n no", .{fmt.clock(now.ts, now.utc_offset_secs)}),
        }
        p.nl(1);
        if (self.msg) |m| p.put(self.msg_buf[0..m.len], if (m.err) red else .{});

        var out = p.surface;
        out.children = children.items;
        return out;
    }

    fn drawPicker(self: *Tracker, p: *Painter, children: *std.ArrayList(vxfw.SubSurface), a: Allocator, bottom: u16) !void {
        p.put("Start tracking", bold);
        p.nl(1);
        p.put("  › ", dim);
        try children.append(a, try p.field(self.filter.widget(), 4, @min(p.width -| 4, 40)));
        p.nl(2);
        ui.drawOptions(p, try self.options(a), self.selected, bottom);
    }
};

/// This week against the weekly goal, and where today's shift leaves it.
fn drawGoal(p: *Painter, g: sheet.Goal, off: i64) !void {
    try p.print(.{}, "{f}", .{fmt.dur(g.worked)});
    try p.print(dim, " of {f}", .{fmt.dur(g.secs)});
    if (g.isMet()) {
        try p.print(green, "  ·  goal met", .{});
        if (g.over() >= 60) try p.print(dim, "  ·  {f} over", .{fmt.dur(g.over())});
        return;
    }
    try p.print(.{}, "  ·  {f} left", .{fmt.dur(g.left())});
    if (g.leftAfterClockOut()) |after| {
        if (after == 0) {
            try p.print(green, "  ·  met at {f}", .{fmt.clock(g.meets_at.?, off)});
        } else try p.print(dim, "  ·  {f} after today", .{fmt.dur(after)});
    }
}

/// The shift from clock in to clock out (or now, if later): work done,
/// breaks, the lunch window, and what's left.
fn drawBar(p: *Painter, snap: Snap) !void {
    const shift = snap.shift orelse return;
    const now = snap.now.ts;
    const width: i64 = p.width -| p.col;
    if (width < 8) return;
    const from = shift.in_ts;
    const to = @max(snap.clock_out, now);
    if (to <= from) return;
    const window: ?sheet.Plan = if (snap.plan) |pl| switch (pl.status(now)) {
        .upcoming, .open => pl,
        else => null,
    } else null;
    var c: i64 = 0;
    while (c < width) : (c += 1) {
        const t = from + @divFloor((2 * c + 1) * (to - from), 2 * width);
        var on_break = false;
        for (snap.breaks) |b| {
            if (t >= b.in_ts and t < (b.out_ts orelse @max(now, b.in_ts + 1))) on_break = true;
        }
        const in_window = if (window) |w| t >= w.opens and t < w.closes else false;
        const past = t < now;
        const cell: struct { []const u8, vaxis.Style } = if (on_break)
            .{ "▒", if (past) yellow else dim }
        else if (past and t >= snap.clock_out)
            .{ "█", yellow }
        else if (past)
            .{ "█", green }
        else if (in_window)
            .{ "▓", cyan }
        else
            .{ "░", dim };
        p.put(cell[0], cell[1]);
    }
}

fn drawLunch(p: *Painter, snap: Snap, plan: sheet.Plan, off: i64) !void {
    const now = snap.now.ts;
    switch (plan.status(now)) {
        .upcoming => {
            try p.print(cyan, "Opens {f}, start by {f}", .{ fmt.clock(plan.opens, off), fmt.clock(plan.closes, off) });
            if (snap.lunch_ahead > 0) try p.print(dim, "  ·  {f} counted in clock out", .{fmt.dur(snap.lunch_ahead)});
        },
        .open => try p.print(yellow, "Take it now: start by {f} ({f} left)", .{ fmt.clock(plan.closes, off), fmt.dur(plan.closes - now) }),
        .on_lunch => {
            const t = plan.lunch.?;
            const min = snap.lunch.?.minimum_secs;
            try p.print(yellow, "On it {f} of {f}", .{ fmt.dur(now - t.start), fmt.dur(min) });
        },
        .taken => {
            const t = plan.lunch.?;
            if (t.start > now) {
                try p.print(cyan, "Planned {f} – {f}", .{ fmt.clock(t.start, off), fmt.clock(t.end.?, off) });
            } else try p.print(dim, "Had it {f} – {f}", .{ fmt.clock(t.start, off), fmt.clock(t.end.?, off) });
        },
        .late => try p.print(yellow, "Started late, at {f}", .{fmt.clock(plan.lunch.?.start, off)}),
        .missed => try p.print(red, "Missed: the window closed at {f}", .{fmt.clock(plan.closes, off)}),
    }
}

fn drawToday(p: *Painter, snap: Snap, a: Allocator, bottom: u16) !void {
    const names = snap.names;
    const now = snap.now.ts;
    const t = snap.totals;

    p.put("Today", bold);
    try p.right(try p.fmt("{f}", .{fmt.dur(t.total)}), bold);
    p.nl(1);
    if (snap.today.len == 0) {
        p.put("  Nothing tracked yet. Press s to start.", dim);
        return;
    }

    // The totals sections below the entries.
    var totals_rows: usize = 2 + t.by_project.len;
    if (t.any_client) totals_rows += 2 + t.by_client.len;
    if (t.personal_by_project.len > 0) totals_rows += 2 + t.personal_by_project.len;
    const room = @as(usize, bottom -| p.row) -| totals_rows -| 1;
    const shown = @min(snap.today.len, @max(room, 1));
    const hidden = snap.today.len - shown;
    if (hidden > 0) {
        try p.print(dim, "  … {d} earlier (t shows them all)", .{hidden});
        p.nl(1);
    }
    for (snap.today[hidden..]) |e| {
        const from = @max(e.in_ts, snap.from);
        try p.print(dim, "  {f} – ", .{fmt.clock(from, e.utc_offset_secs)});
        if (e.out_ts) |out| try p.print(dim, "{f}", .{fmt.clock(out, e.utc_offset_secs)}) else p.put("     now", green);
        try p.print(.{}, "  {s: >7}  ", .{try p.fmt("{f}", .{fmt.dur(report.clipped(e, snap.from, now))})});
        p.put(try names.label(a, e.project_id, e.workspace_id), ui.projectStyle(names, e.project_id, false));
        if (e.kind == .meeting) {
            try p.print(cyan, "  Meeting: {s}", .{e.note orelse "untitled"});
        } else if (e.note) |n| try p.print(dim, "  {s}", .{n});
        if (names.isPersonal(e.project_id)) try p.print(dim, "  {s}", .{names.organizationOf(e.project_id).?.name});
        p.nl(1);
    }

    p.nl(1);
    p.put("By project", bold);
    p.nl(1);
    for (t.by_project) |pt| {
        try p.print(.{}, "  {s: >7}  ", .{try p.fmt("{f}", .{fmt.dur(pt.secs)})});
        p.put(try names.label(a, pt.id, null), ui.projectStyle(names, pt.id, false));
        if (names.clientOf(pt.id)) |cl| try p.print(dim, "  {s}", .{cl.name});
        p.nl(1);
    }
    if (t.any_client) {
        p.nl(1);
        p.put("By client", bold);
        p.nl(1);
        for (t.by_client) |ct| {
            try p.print(.{}, "  {s: >7}  ", .{try p.fmt("{f}", .{fmt.dur(ct.secs)})});
            if (ct.id) |id| p.put(names.client(id).?.name, .{}) else p.put("(no client)", dim);
            p.nl(1);
        }
    }
    try ui.drawPersonal(p, names, t, a);
}
