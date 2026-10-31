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
const situ = @import("integrations").situ;
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Calculator = @import("calc.zig").Calculator;

const reload_ms = 1000;
const max_width = 76;
/// Where values start after a row label like "Shift".
const value_col = 10;
const default_shift_secs = 8 * std.time.s_per_hour;

const Mode = enum { track, pick, note, confirm_out, calc };

/// Everything the screen shows, read in one go.
const Snap = struct {
    now: local.Stamp,
    names: report.Names,
    shift: ?store.Shift = null,
    clock_out: i64 = 0,
    on_break: ?store.Break = null,
    running: ?store.Entry = null,
    /// Local midnight today.
    from: i64,
    today: []const store.Entry = &.{},
    totals: report.Totals = .{ .by_project = &.{}, .by_client = &.{}, .any_client = false, .total = 0 },
    /// What the Situ repo the TUI started in is linked to.
    here: ?store.Target = null,
};

/// A choice in the start picker. `target` null is unassigned time.
const Option = struct {
    label: []const u8,
    target: ?store.Target,
    here: bool = false,
};

pub const Tracker = struct {
    gpa: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    db: *Store,
    marker: ?situ.Marker,
    calc: *Calculator,

    /// Snapshots alternate between these, so a failed reload keeps the
    /// last good one on screen.
    arenas: [2]std.heap.ArenaAllocator,
    live: u1 = 0,
    snap: ?Snap = null,

    mode: Mode = .track,
    filter: vxfw.TextField,
    note: vxfw.TextField,
    selected: usize = 0,

    msg_buf: [200]u8 = undefined,
    msg: ?struct { len: usize, err: bool } = null,

    pub fn init(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, db: *Store, marker: ?situ.Marker, calc: *Calculator) Tracker {
        return .{
            .gpa = gpa,
            .io = io,
            .env = env,
            .db = db,
            .marker = marker,
            .calc = calc,
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
        };
        if (try self.db.currentShift(a)) |shift| {
            const brks = try self.db.breaks(a, shift.id);
            snap.shift = shift;
            snap.clock_out = store.clockOut(shift, brks, now.ts);
            for (brks) |b| if (b.out_ts == null) {
                snap.on_break = b;
            };
        }
        snap.running = try self.db.runningEntry(a);
        snap.today = try self.db.entriesBetween(a, snap.from, now.ts + 1);
        snap.totals = try report.totals(a, snap.names, snap.today, snap.from, now.ts);
        if (self.marker) |m| snap.here = try situ.linked(self.db, m);

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

    /// What the start picker offers, narrowed by the filter: the linked
    /// repo first, then every project and workspace, then unassigned.
    fn options(self: *Tracker, a: Allocator) ![]Option {
        const snap = self.snap orelse return &.{};
        const names = snap.names;
        var all: std.ArrayList(Option) = .empty;
        if (snap.here) |t| try all.append(a, .{ .label = try names.label(a, t.project_id, t.workspace_id), .target = t, .here = true });
        for (names.projects) |p| {
            try all.append(a, .{ .label = p.name, .target = .{ .project_id = p.id } });
            for (names.workspaces) |w| if (w.project_id.eql(p.id)) {
                try all.append(a, .{ .label = try names.label(a, p.id, w.id), .target = .{ .project_id = p.id, .workspace_id = w.id } });
            };
        }
        try all.append(a, .{ .label = "(unassigned)", .target = null });

        const query = try fieldText(a, &self.filter);
        if (query.len == 0) return all.items;
        var out: std.ArrayList(Option) = .empty;
        for (all.items) |o| if (std.ascii.indexOfIgnoreCase(o.label, query) != null) try out.append(a, o);
        return out.items;
    }

    // ── Actions ───────────────────────────────────────────────────────────

    fn start(self: *Tracker, opt: Option) void {
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
        const text = std.mem.trim(u8, try fieldText(tmp.allocator(), &self.note), " \t");
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
            const ended = self.db.endBreak(now) catch |e| return self.flash(true, "Couldn't end the break: {t}", .{e});
            if (ended == null) {
                self.flash(false, "Break under a minute; dropped.", .{});
            } else self.flash(false, "Back after {f}.", .{fmt.dur(now - b.in_ts)});
        } else {
            _ = self.db.startBreak(now) catch |e| switch (e) {
                error.NotFound => return self.flash(false, "Not on shift; press i to clock in.", .{}),
                else => return self.flash(true, "Couldn't start a break: {t}", .{e}),
            };
            self.flash(false, "On break.", .{});
        }
        self.refresh();
    }

    fn clockIn(self: *Tracker) void {
        var tz_buf: local.TzBuf = undefined;
        const at = self.stamp(&tz_buf);
        const target = self.defaultShiftSecs();
        _ = self.db.startShift(target, at) catch |e| switch (e) {
            error.Conflict => return self.flash(false, "Already on shift.", .{}),
            else => return self.flash(true, "Couldn't clock in: {t}", .{e}),
        };
        self.flash(false, "Clocked in. Clock out at {f}.", .{fmt.clock(at.ts + target, at.utc_offset_secs)});
        self.refresh();
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
            .pick => {
                if (esc) return self.setMode(ctx, .track);
                if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
                    self.selected -|= 1;
                } else if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true }) or key.matches('\t', .{})) {
                    self.selected += 1;
                } else if (enter) {
                    var tmp: std.heap.ArenaAllocator = .init(self.gpa);
                    defer tmp.deinit();
                    const opts = try self.options(tmp.allocator());
                    if (opts.len == 0) return ctx.consumeEvent();
                    self.start(opts[@min(self.selected, opts.len - 1)]);
                    return self.setMode(ctx, .track);
                } else return;
                ctx.consumeAndRedraw();
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
            .track, .confirm_out => self.widget(),
        });
        ctx.consumeAndRedraw();
    }

    fn onFilterChange(ptr: ?*anyopaque, _: *vxfw.EventContext, _: []const u8) anyerror!void {
        const self: *Tracker = @ptrCast(@alignCast(ptr.?));
        self.selected = 0;
    }

    // ── Drawing ───────────────────────────────────────────────────────────

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Tracker = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *Tracker, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        if (self.mode == .calc) {
            const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
            children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = try self.calc.widget().draw(ctx) };
            return .{ .size = size, .widget = self.widget(), .buffer = &.{}, .children = children };
        }

        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        const width = @min(size.width -| 4, max_width);
        var p: Painter = .{ .ctx = ctx, .surface = surface, .left = (size.width - width) / 2, .width = width, .height = size.height };

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
            if (snap.on_break) |b| {
                p.nl(1);
                p.col = value_col;
                try p.print(yellow, "On break since {f}  ·  {f}", .{ fmt.clock(b.in_ts, shift.utc_offset_secs), fmt.dur(now.ts - b.in_ts) });
            }
        } else p.put("Off shift", dim);
        p.nl(1);

        // Now
        p.put("Now", bold);
        p.col = value_col;
        if (snap.running) |e| {
            p.put("● ", green);
            p.put(try names.label(a, e.project_id, e.workspace_id), projectStyle(names, e.project_id, true));
            try p.print(.{}, "  {f}", .{fmt.dur(now.ts - e.in_ts)});
            if (e.note) |n| try p.print(dim, "  {s}", .{n});
        } else p.put("Not tracking", dim);
        p.nl(2);

        // Footer: two rows at the bottom.
        const footer_row = size.height -| 2;

        switch (self.mode) {
            .pick => try self.drawPicker(&p, &children, a, footer_row),
            else => try drawToday(&p, snap, a, footer_row),
        }

        // Keys, or the note field / confirmation in their place.
        p.row = footer_row;
        p.col = 0;
        switch (self.mode) {
            .track, .calc => p.put("s start  x stop  n note  b break  i in  o out  c calculator  q quit", dim),
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

        const opts = try self.options(a);
        if (opts.len == 0) {
            p.put("  No match", dim);
            return;
        }
        const sel = @min(self.selected, opts.len - 1);
        const room: usize = @max(1, bottom -| p.row -| 1);
        // Keep the selection in view.
        const first = if (sel >= room) sel - room + 1 else 0;
        for (opts[first..@min(opts.len, first + room)], first..) |o, i| {
            const on = i == sel;
            p.put(if (on) "  ▸ " else "    ", if (on) green else dim);
            p.put(o.label, if (on) bold else .{});
            if (o.here) p.put("  this repo", dim);
            p.nl(1);
        }
    }
};

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
    const room = @as(usize, bottom -| p.row) -| totals_rows -| 1;
    const shown = @min(snap.today.len, @max(room, 1));
    const hidden = snap.today.len - shown;
    if (hidden > 0) {
        try p.print(dim, "  … {d} earlier", .{hidden});
        p.nl(1);
    }
    for (snap.today[hidden..]) |e| {
        const from = @max(e.in_ts, snap.from);
        try p.print(dim, "  {f} – ", .{fmt.clock(from, e.utc_offset_secs)});
        if (e.out_ts) |out| try p.print(dim, "{f}", .{fmt.clock(out, e.utc_offset_secs)}) else p.put("     now", green);
        try p.print(.{}, "  {s: >7}  ", .{try p.fmt("{f}", .{fmt.dur(report.clipped(e, snap.from, now))})});
        p.put(try names.label(a, e.project_id, e.workspace_id), projectStyle(names, e.project_id, false));
        if (e.note) |n| try p.print(dim, "  {s}", .{n});
        p.nl(1);
    }

    p.nl(1);
    p.put("By project", bold);
    p.nl(1);
    for (t.by_project) |pt| {
        try p.print(.{}, "  {s: >7}  ", .{try p.fmt("{f}", .{fmt.dur(pt.secs)})});
        p.put(try names.label(a, pt.id, null), projectStyle(names, pt.id, false));
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
}

const bold: vaxis.Style = .{ .bold = true };
const dim: vaxis.Style = .{ .dim = true };
const green: vaxis.Style = .{ .fg = .{ .index = 2 } };
const yellow: vaxis.Style = .{ .fg = .{ .index = 3 } };
const red: vaxis.Style = .{ .fg = .{ .index = 1 } };

/// A project's own color, if it has one.
fn projectStyle(names: report.Names, project_id: ?core.Uuid, strong: bool) vaxis.Style {
    var style: vaxis.Style = .{ .bold = strong };
    const pid = project_id orelse {
        style.dim = true;
        return style;
    };
    const color = (names.project(pid) orelse return style).color orelse return style;
    if (color.len == 7 and color[0] == '#') {
        const rgb = std.fmt.parseInt(u24, color[1..], 16) catch return style;
        style.fg = .{ .rgb = .{ @truncate(rgb >> 16), @truncate(rgb >> 8), @truncate(rgb) } };
    }
    return style;
}

/// Writes styled text into a surface line by line, clipped to a column of
/// `width` cells starting at `left`.
const Painter = struct {
    ctx: vxfw.DrawContext,
    surface: vxfw.Surface,
    left: u16,
    width: u16,
    height: u16,
    row: u16 = 1,
    col: u16 = 0,

    fn put(p: *Painter, str: []const u8, style: vaxis.Style) void {
        if (p.row >= p.height) return;
        var it = p.ctx.graphemeIterator(str);
        while (it.next()) |g| {
            const bytes = g.bytes(str);
            const w: u16 = @intCast(p.ctx.stringWidth(bytes));
            if (p.col + w > p.width) return;
            p.surface.writeCell(p.left + p.col, p.row, .{ .char = .{ .grapheme = bytes, .width = @intCast(w) }, .style = style });
            p.col += w;
        }
    }

    fn fmt(p: *Painter, comptime f: []const u8, args: anytype) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(p.ctx.arena, f, args);
    }

    fn print(p: *Painter, style: vaxis.Style, comptime f: []const u8, args: anytype) Allocator.Error!void {
        p.put(try p.fmt(f, args), style);
    }

    /// Puts `str` flush right on the current row.
    fn right(p: *Painter, str: []const u8, style: vaxis.Style) Allocator.Error!void {
        const w: u16 = @intCast(p.ctx.stringWidth(str));
        p.col = @max(p.col, p.width -| w);
        p.put(str, style);
    }

    fn nl(p: *Painter, n: u16) void {
        p.row +|= n;
        p.col = 0;
    }

    /// A one-row text field at column `col` of the current row.
    fn field(p: *Painter, w: vxfw.Widget, col: u16, width: u16) Allocator.Error!vxfw.SubSurface {
        const size: vxfw.Size = .{ .width = width, .height = 1 };
        return .{
            .origin = .{ .row = p.row, .col = p.left + col },
            .surface = try w.draw(p.ctx.withConstraints(size, .fromSize(size))),
        };
    }
};

fn fieldText(a: Allocator, tf: *const vxfw.TextField) Allocator.Error![]const u8 {
    return std.mem.concat(a, u8, &.{ tf.buf.firstHalf(), tf.buf.secondHalf() });
}

const testing = std.testing;

test "projectStyle - uses the project's color" {
    const pid: core.Uuid = .v7At(1, @splat(0));
    const names: report.Names = .{
        .clients = &.{},
        .projects = &.{.{ .id = pid, .client_id = null, .name = "web", .color = "#ff8800" }},
        .workspaces = &.{},
    };
    try testing.expectEqual(vaxis.Color{ .rgb = .{ 0xff, 0x88, 0x00 } }, projectStyle(names, pid, false).fg);
    try testing.expect(projectStyle(names, null, false).dim);
}
