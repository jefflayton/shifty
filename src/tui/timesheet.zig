//! The TUI's timesheet: a week of shifts, breaks, and tracked time, as the
//! menu bar app's Timesheet window shows it, worked from the keyboard. Every
//! change goes straight to the store and can be undone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const core = @import("core");
const Uuid = core.Uuid;
const local = core.local;
const fmt = core.fmt;
const Time = core.time.Time;
const store = @import("store");
const Store = store.Store;
const sheet = store.sheet;
const Item = sheet.Item;
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const ui = @import("ui.zig");
const Painter = ui.Painter;
const bold = ui.bold;
const dim = ui.dim;
const green = ui.green;
const yellow = ui.yellow;
const red = ui.red;
const cyan = ui.cyan;

const max_width = 96;
/// Where a row's duration ends and its label starts.
const dur_end = 31;
const label_col = 33;

const Mode = enum { browse, edit, pick, note, help };

/// A change to the store, kept so it can be undone: running one gives back
/// the change that undoes it.
const Op = union(enum) {
    entry: struct { id: Uuid, edit: Store.EntryEdit },
    delete_entry: Uuid,
    restore_entry: Uuid,
    shift_times: struct { id: Uuid, in_ts: i64, out_ts: i64 },
    clock_in: struct { id: Uuid, in_ts: i64, target_secs: i64 },
    delete_shift: Uuid,
    restore_shift: Uuid,
    put_break: struct { id: Uuid, shift_id: Uuid, in_ts: i64, out_ts: ?i64 },
    delete_break: Uuid,
};

const Step = struct { op: Op, name: []const u8 };

/// What's on screen, line by line.
const Line = union(enum) {
    day: usize,
    shift: sheet.SheetShift,
    row: sheet.Row,

    fn item(l: Line) Item {
        return switch (l) {
            .day => |d| .{ .day = d },
            .shift => |s| .{ .shift = s.shift.id },
            .row => |r| r.item(),
        };
    }
};

pub const Timesheet = struct {
    gpa: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    db: *Store,
    /// What the repo or folder the TUI started in is linked to, offered
    /// first in the project picker.
    here: ?store.Target = null,

    /// Weeks alternate between these, so a failed reload keeps the last
    /// good one on screen.
    arenas: [2]std.heap.ArenaAllocator,
    live: u1 = 0,
    week: ?sheet.Week = null,
    now: i64 = 0,
    utc_offset_secs: i64 = 0,
    /// Local midnight starting the week shown; 0 until first shown.
    first: i64 = 0,

    /// Days folded (true) or opened (false) by hand; the rest are open only
    /// if they're today.
    fold: [7]?bool = @splat(null),
    selection: ?Item = null,
    /// Where the selection was, to land nearby when it's deleted.
    sel_index: usize = 0,
    /// The first line in view.
    scroll: usize = 0,
    mode: Mode = .browse,
    /// The week's totals instead of its days.
    show_totals: bool = false,

    /// The row being edited, and its fields: start and end, or an open
    /// shift's clock in and length.
    editing: ?Item = null,
    fields: [2]vxfw.TextField,
    field_labels: [2][]const u8 = .{ "", "" },
    field_count: u2 = 0,
    field_focus: u1 = 0,
    /// After adding time: pick its project once its times are saved.
    then_pick: bool = false,

    filter: vxfw.TextField,
    picked: usize = 0,
    note: vxfw.TextField,

    history: std.heap.ArenaAllocator,
    undo_stack: std.ArrayList(Step) = .empty,
    redo_stack: std.ArrayList(Step) = .empty,

    msg_buf: [200]u8 = undefined,
    msg: ?struct { len: usize, err: bool } = null,

    pub fn init(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, db: *Store) Timesheet {
        return .{
            .gpa = gpa,
            .io = io,
            .env = env,
            .db = db,
            .arenas = .{ .init(gpa), .init(gpa) },
            .fields = .{ .init(gpa), .init(gpa) },
            .filter = .init(gpa),
            .note = .init(gpa),
            .history = .init(gpa),
        };
    }

    /// Hooks up callbacks that point back at `self`; call once it's at its
    /// final address.
    pub fn bind(self: *Timesheet) void {
        self.filter.userdata = self;
        self.filter.onChange = onFilterChange;
    }

    pub fn deinit(self: *Timesheet) void {
        for (&self.fields) |*f| f.deinit();
        self.filter.deinit();
        self.note.deinit();
        self.undo_stack.deinit(self.gpa);
        self.redo_stack.deinit(self.gpa);
        self.history.deinit();
        for (&self.arenas) |*a| a.deinit();
    }

    pub fn widget(self: *Timesheet) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    /// The widget that should have the keyboard.
    pub fn focusedWidget(self: *Timesheet) vxfw.Widget {
        return switch (self.mode) {
            .edit => self.fields[self.field_focus].widget(),
            .pick => self.filter.widget(),
            .note => self.note.widget(),
            .browse, .help => self.widget(),
        };
    }

    /// Opens the timesheet on the week shown last, or this one.
    pub fn show(self: *Timesheet, here: ?store.Target) void {
        self.here = here;
        self.mode = .browse;
        self.msg = null;
        if (self.first == 0) {
            self.stampNow();
            self.goToWeek(self.now);
        } else self.refresh();
    }

    /// Opens the timesheet editing the open shift's clock in and length.
    pub fn editShift(self: *Timesheet, ctx: *vxfw.EventContext, here: ?store.Target, shift_id: Uuid) !void {
        self.show(here);
        self.stampNow();
        self.goToWeek(self.now);
        const w = self.week orelse return;
        const s = w.shift(shift_id) orelse return;
        if (w.dayOf(s.shift.in_ts)) |d| self.fold[d] = false;
        self.selection = .{ .shift = shift_id };
        try self.startEdit(ctx, .{ .shift = shift_id });
    }

    // ── Data ──────────────────────────────────────────────────────────────

    fn stampNow(self: *Timesheet) void {
        self.now = Io.Clock.real.now(self.io).toSeconds();
        self.utc_offset_secs = local.utcOffset(self.now);
    }

    fn reload(self: *Timesheet) !void {
        const next = self.live +% 1;
        const arena = &self.arenas[next];
        _ = arena.reset(.retain_capacity);
        self.stampNow();
        const days = sheet.weekDays(self.first, local.utcOffset);
        self.week = try sheet.Week.load(self.db, arena.allocator(), days);
        self.live = next;
    }

    pub fn refresh(self: *Timesheet) void {
        self.reload() catch |e| self.flash(true, "Can't read the timesheet: {t}", .{e});
    }

    fn goToWeek(self: *Timesheet, ts: i64) void {
        var buf: [16]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const first_day = sheet.weekStartDay(self.db, fba.allocator()) catch 7;
        const start = sheet.weekStart(ts, local.utcOffset(ts), first_day);
        if (start == self.first and self.week != null) return self.refresh();
        self.first = start;
        self.fold = @splat(null);
        self.scroll = 0;
        self.refresh();
        // Land on today, else the week's first day you work.
        const w = self.week orelse return;
        self.selection = null;
        if (w.dayOf(self.now)) |d| if (self.now < w.days[7]) {
            self.selection = .{ .day = d };
        };
        if (self.selection == null) for (0..7) |d| if (w.isVisible(d)) {
            self.selection = .{ .day = d };
            break;
        };
    }

    fn isFolded(self: *const Timesheet, w: sheet.Week, day: usize) bool {
        if (!w.hasTime(day)) return false;
        if (self.fold[day]) |f| return f;
        return !(w.dayOf(self.now) == day and self.now < w.days[7]);
    }

    fn lines(self: *const Timesheet, a: Allocator) Allocator.Error![]Line {
        const w = self.week orelse return &.{};
        var out: std.ArrayList(Line) = .empty;
        for (0..7) |d| {
            if (!w.isVisible(d)) continue;
            try out.append(a, .{ .day = d });
            if (self.isFolded(w, d)) continue;
            for (try w.shiftsOn(a, d)) |s| try out.append(a, .{ .shift = s });
            for (try w.rows(a, d)) |r| try out.append(a, .{ .row = r });
        }
        return out.items;
    }

    /// The selection's line, re-finding it after a reload; one that's gone
    /// gives way to what's now where it was.
    fn selected(self: *Timesheet, all: []const Line) ?usize {
        if (all.len == 0) return null;
        if (self.selection) |sel| for (all, 0..) |l, i| if (l.item().eql(sel)) {
            self.sel_index = i;
            return i;
        };
        const i = @min(self.sel_index, all.len - 1);
        self.selection = all[i].item();
        self.sel_index = i;
        return i;
    }

    fn flash(self: *Timesheet, err: bool, comptime f: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.msg_buf, f, args) catch blk: {
            @memcpy(self.msg_buf[self.msg_buf.len - 3 ..], "...");
            break :blk self.msg_buf[0..];
        };
        self.msg = .{ .len = s.len, .err = err };
    }

    fn tz(self: *Timesheet, buf: *local.TzBuf) ?[]const u8 {
        return local.tzName(self.io, self.env.get("TZ"), buf);
    }

    /// The day the selection is on, else today, else the first shown.
    fn selectedDay(self: *Timesheet) ?usize {
        const w = self.week orelse return null;
        if (self.selection) |s| if (w.dayOfItem(s)) |d| return d;
        if (w.dayOf(self.now)) |d| if (self.now < w.days[7]) return d;
        for (0..7) |d| if (w.isVisible(d)) return d;
        return null;
    }

    /// The shift the selection is on or in, else the selected day's first.
    fn selectedShift(self: *Timesheet, a: Allocator) !?sheet.SheetShift {
        const w = self.week orelse return null;
        if (self.selection) |s| switch (s) {
            .shift => |id| return w.shift(id),
            .brk => |id| if (w.brk(id)) |b| return b.shift,
            else => {},
        };
        const d = self.selectedDay() orelse return null;
        const on = try w.shiftsOn(a, d);
        return if (on.len > 0) on[0] else null;
    }

    // ── Changes and undo ──────────────────────────────────────────────────

    /// Runs `op` and returns the change that undoes it.
    fn perform(self: *Timesheet, op: Op) !Op {
        var tmp: std.heap.ArenaAllocator = .init(self.gpa);
        defer tmp.deinit();
        const a = tmp.allocator();
        const now = Io.Clock.real.now(self.io).toSeconds();
        const db = self.db;
        switch (op) {
            .entry => |e| {
                const old = try db.entryById(a, e.id) orelse return error.NotFound;
                try db.editEntry(e.id, e.edit, now);
                return .{ .entry = .{ .id = e.id, .edit = .{
                    .project_id = old.project_id,
                    .workspace_id = old.workspace_id,
                    .in_ts = old.in_ts,
                    .out_ts = old.out_ts,
                    .note = if (old.note) |n| try self.history.allocator().dupe(u8, n) else null,
                } } };
            },
            .delete_entry => |id| {
                try db.deleteEntry(id, now);
                return .{ .restore_entry = id };
            },
            .restore_entry => |id| {
                try db.restoreEntry(id, now);
                return .{ .delete_entry = id };
            },
            .shift_times => |s| {
                const old = try db.shiftById(a, s.id) orelse return error.NotFound;
                try db.setShiftTimes(s.id, s.in_ts, s.out_ts, now);
                return .{ .shift_times = .{ .id = s.id, .in_ts = old.in_ts, .out_ts = old.out_ts orelse return error.NotFound } };
            },
            .clock_in => |s| {
                const old = try db.shiftById(a, s.id) orelse return error.NotFound;
                try db.editShift(s.id, .{ .in_ts = s.in_ts, .target_secs = s.target_secs }, now);
                return .{ .clock_in = .{ .id = s.id, .in_ts = old.in_ts, .target_secs = old.target_secs } };
            },
            .delete_shift => |id| {
                try db.deleteShift(id, now);
                return .{ .restore_shift = id };
            },
            .restore_shift => |id| {
                try db.restoreShift(id, now);
                return .{ .delete_shift = id };
            },
            .put_break => |b| {
                const old = try db.breakById(b.id);
                try db.putBreak(b.id, b.shift_id, b.in_ts, b.out_ts, now);
                if (old) |o| return .{ .put_break = .{ .id = o.id, .shift_id = o.shift_id, .in_ts = o.in_ts, .out_ts = o.out_ts } };
                return .{ .delete_break = b.id };
            },
            .delete_break => |id| {
                const old = try db.breakById(id) orelse return error.NotFound;
                try db.deleteBreak(id, now);
                return .{ .put_break = .{ .id = id, .shift_id = old.shift_id, .in_ts = old.in_ts, .out_ts = old.out_ts } };
            },
        }
    }

    /// Makes a change the user asked for, so `u` takes it back.
    fn change(self: *Timesheet, name: []const u8, op: Op) bool {
        const inverse = self.perform(op) catch |e| {
            self.flash(true, "Couldn't save that change: {t}", .{e});
            self.refresh();
            return false;
        };
        self.remember(name, inverse);
        self.refresh();
        return true;
    }

    /// Keeps `inverse` as the way to undo a change just made.
    fn remember(self: *Timesheet, name: []const u8, inverse: Op) void {
        self.undo_stack.append(self.gpa, .{ .op = inverse, .name = name }) catch {};
        self.redo_stack.clearRetainingCapacity();
    }

    fn undo(self: *Timesheet) void {
        self.replay(&self.undo_stack, &self.redo_stack, "Undid", "undo");
    }

    fn redo(self: *Timesheet) void {
        self.replay(&self.redo_stack, &self.undo_stack, "Redid", "redo");
    }

    fn replay(self: *Timesheet, from: *std.ArrayList(Step), to: *std.ArrayList(Step), done: []const u8, noun: []const u8) void {
        const step = from.pop() orelse return self.flash(false, "Nothing to {s}.", .{noun});
        const inverse = self.perform(step.op) catch |e| {
            self.flash(true, "Couldn't {s} {s}: {t}", .{ noun, step.name, e });
            self.refresh();
            return;
        };
        to.append(self.gpa, .{ .op = inverse, .name = step.name }) catch {};
        if (self.undo_stack.items.len == 0 and self.redo_stack.items.len == 0) _ = self.history.reset(.retain_capacity);
        self.flash(false, "{s} {s}.", .{ done, step.name });
        self.refresh();
    }

    // ── Actions ───────────────────────────────────────────────────────────

    fn addEntry(self: *Timesheet, ctx: *vxfw.EventContext) !void {
        var tmp: std.heap.ArenaAllocator = .init(self.gpa);
        defer tmp.deinit();
        const w = self.week orelse return;
        const d = self.selectedDay() orelse return self.flash(false, "No day to add time to.", .{});
        const slot = try w.entrySlot(tmp.allocator(), d, self.now, self.utc_offset_secs);
        var tz_buf: local.TzBuf = undefined;
        const id = self.db.addEntry(.{ .source = .tui }, .{ .ts = slot.start, .utc_offset_secs = local.utcOffset(slot.start), .tz = self.tz(&tz_buf) }, slot.end) catch |e|
            return self.flash(true, "Couldn't add time: {t}", .{e});
        self.remember("Add Time", .{ .delete_entry = id });
        self.refresh();
        self.fold[d] = false;
        self.selection = .{ .entry = id };
        self.then_pick = true;
        try self.startEdit(ctx, .{ .entry = id });
    }

    fn addShift(self: *Timesheet, ctx: *vxfw.EventContext) !void {
        var tmp: std.heap.ArenaAllocator = .init(self.gpa);
        defer tmp.deinit();
        const w = self.week orelse return;
        const d = self.selectedDay() orelse return self.flash(false, "No day to add a shift to.", .{});
        const slot = try w.shiftSlot(tmp.allocator(), d, self.now, self.utc_offset_secs) orelse
            return self.flash(false, "That day's still to come.", .{});
        var tz_buf: local.TzBuf = undefined;
        const id = self.db.addShift(.{ .ts = slot.start, .utc_offset_secs = local.utcOffset(slot.start), .tz = self.tz(&tz_buf) }, slot.end) catch |e|
            return self.flash(true, "Couldn't add a shift: {t}", .{e});
        self.remember("Add Shift", .{ .delete_shift = id });
        self.refresh();
        self.fold[d] = false;
        self.selection = .{ .shift = id };
        try self.startEdit(ctx, .{ .shift = id });
    }

    fn addBreak(self: *Timesheet, ctx: *vxfw.EventContext) !void {
        var tmp: std.heap.ArenaAllocator = .init(self.gpa);
        defer tmp.deinit();
        const w = self.week orelse return;
        const s = try self.selectedShift(tmp.allocator()) orelse
            return self.flash(false, "No shift on that day; A adds one.", .{});
        const slot = try w.breakSlot(tmp.allocator(), s, self.now);
        const id: Uuid = .v7(self.io);
        if (!self.change("Add Break", .{ .put_break = .{ .id = id, .shift_id = s.shift.id, .in_ts = slot.start, .out_ts = slot.end } })) return;
        if (w.dayOf(slot.start)) |d| self.fold[d] = false;
        self.selection = .{ .brk = id };
        try self.startEdit(ctx, .{ .brk = id });
    }

    fn delete(self: *Timesheet) void {
        const sel = self.selection orelse return;
        const w = self.week orelse return;
        switch (sel) {
            .day => self.flash(false, "Select a shift, break, or time to delete.", .{}),
            .entry => |id| if (self.change("Delete Time", .{ .delete_entry = id })) {
                const e = w.entry(id);
                self.flash(false, "Deleted {s}. u undoes.", .{if (e) |x| self.labelOf(x) else "time"});
            },
            .shift => |id| if (self.change("Delete Shift", .{ .delete_shift = id }))
                self.flash(false, "Deleted the shift and its breaks. u undoes.", .{}),
            .brk => |id| if (self.change("Delete Break", .{ .delete_break = id }))
                self.flash(false, "Deleted the break. u undoes.", .{}),
        }
    }

    /// Stops the running entry or ends the break you're on, if selected.
    fn stop(self: *Timesheet) void {
        const sel = self.selection orelse return;
        const w = self.week orelse return;
        const now = Io.Clock.real.now(self.io).toSeconds();
        switch (sel) {
            .entry => |id| {
                const e = w.entry(id) orelse return;
                if (e.out_ts != null) return self.flash(false, "That time's already stopped.", .{});
                if (self.change("Stop Timer", .{ .entry = .{ .id = id, .edit = .{
                    .project_id = e.project_id,
                    .workspace_id = e.workspace_id,
                    .in_ts = e.in_ts,
                    .out_ts = @max(now, e.in_ts + 1),
                    .note = e.note,
                } } })) self.flash(false, "Stopped {s}.", .{self.labelOf(e)});
            },
            .brk => |id| {
                const b = w.brk(id) orelse return;
                if (b.brk.out_ts != null) return self.flash(false, "That break's already over.", .{});
                if (self.change("End Break", .{ .put_break = .{ .id = id, .shift_id = b.shift.shift.id, .in_ts = b.brk.in_ts, .out_ts = @max(now, b.brk.in_ts + store.min_break_secs) } }))
                    self.flash(false, "Back from the break.", .{});
            },
            else => self.flash(false, "Select the running time or break to stop it.", .{}),
        }
    }

    fn labelOf(self: *Timesheet, e: store.Entry) []const u8 {
        const w = self.week orelse return "time";
        return w.names.label(self.history.allocator(), e.project_id, e.workspace_id) catch "time";
    }

    fn startEdit(self: *Timesheet, ctx: *vxfw.EventContext, it: Item) !void {
        const w = self.week orelse return;
        var start: i64 = undefined;
        var end: ?i64 = null;
        var off: i64 = undefined;
        self.field_labels = .{ "Start", "End" };
        var length: ?i64 = null;
        switch (it) {
            .day => |d| {
                self.toggleFold(d);
                return ctx.consumeAndRedraw();
            },
            .entry => |id| {
                const e = w.entry(id) orelse return;
                start = e.in_ts;
                end = e.out_ts;
                off = e.utc_offset_secs;
            },
            .shift => |id| {
                const s = w.shift(id) orelse return;
                start = s.shift.in_ts;
                off = s.shift.utc_offset_secs;
                self.field_labels[0] = "Clock in";
                if (s.shift.out_ts) |out| {
                    end = out;
                    self.field_labels[1] = "Clock out";
                } else {
                    length = s.shift.target_secs;
                    self.field_labels[1] = "Length";
                }
            },
            .brk => |id| {
                const b = w.brk(id) orelse return;
                start = b.brk.in_ts;
                end = b.brk.out_ts;
                off = b.shift.shift.utc_offset_secs;
            },
        }
        try ui.setField(&self.fields[0], &clockStr(start, off));
        self.field_count = 1;
        if (end) |e| {
            try ui.setField(&self.fields[1], &clockStr(e, off));
            self.field_count = 2;
        } else if (length) |l| {
            var buf: [16]u8 = undefined;
            try ui.setField(&self.fields[1], lengthStr(&buf, l));
            self.field_count = 2;
        }
        self.editing = it;
        self.field_focus = 0;
        try self.setMode(ctx, .edit);
    }

    /// Saves the edited times; a field that doesn't read keeps the editor
    /// open.
    fn saveEdit(self: *Timesheet, ctx: *vxfw.EventContext) !void {
        var tmp: std.heap.ArenaAllocator = .init(self.gpa);
        defer tmp.deinit();
        const a = tmp.allocator();
        const w = self.week orelse return;
        const it = self.editing orelse return self.setMode(ctx, .browse);
        const t0_str = std.mem.trim(u8, try ui.fieldText(a, &self.fields[0]), " ");
        const t0 = Time.fromStr(t0_str) catch return self.fieldError(ctx, 0, "Can't read '{s}' as a time; try 9:30 or 2pm.", t0_str);
        var t1: ?Time = null;
        var len: ?i64 = null;
        const t1_str = std.mem.trim(u8, try ui.fieldText(a, &self.fields[1]), " ");
        if (self.field_count == 2) {
            if (std.mem.eql(u8, self.field_labels[1], "Length")) {
                len = core.time.parseDuration(t1_str) catch return self.fieldError(ctx, 1, "Can't read '{s}' as a length; try 8h or 7:30.", t1_str);
                if (len.? <= 0) return self.fieldError(ctx, 1, "A shift needs some length, not '{s}'.", t1_str);
            } else t1 = Time.fromStr(t1_str) catch return self.fieldError(ctx, 1, "Can't read '{s}' as a time; try 5pm or 17:00.", t1_str);
        }

        var name: []const u8 = "Change Time";
        const op: Op = switch (it) {
            .day => return self.setMode(ctx, .browse),
            .entry => |id| blk: {
                const e = w.entry(id) orelse return self.setMode(ctx, .browse);
                const off = e.utc_offset_secs;
                const start = sheet.onDay(e.in_ts, off, t0);
                const end = if (t1) |t| sheet.endAfter(start, off, t) else null;
                if (end) |x| if (!sheet.validEntry(start, x)) return self.fieldError(ctx, 1, "Time can't run longer than 16 hours{s}.", "");
                if (end == null and start > self.now) return self.fieldError(ctx, 0, "The running timer can't start in the future{s}.", "");
                break :blk .{ .entry = .{ .id = id, .edit = .{ .project_id = e.project_id, .workspace_id = e.workspace_id, .in_ts = start, .out_ts = end, .note = e.note } } };
            },
            .shift => |id| blk: {
                name = "Change Shift";
                const s = w.shift(id) orelse return self.setMode(ctx, .browse);
                const off = s.shift.utc_offset_secs;
                const start = sheet.onDay(s.shift.in_ts, off, t0);
                if (s.shift.out_ts == null) {
                    if (start > self.now) return self.fieldError(ctx, 0, "You can't clock in in the future{s}.", "");
                    break :blk .{ .clock_in = .{ .id = id, .in_ts = start, .target_secs = len orelse s.shift.target_secs } };
                }
                const end = sheet.endAfter(start, off, t1.?);
                if (!sheet.validEntry(start, end)) return self.fieldError(ctx, 1, "A shift can't run longer than 16 hours{s}.", "");
                break :blk .{ .shift_times = .{ .id = id, .in_ts = start, .out_ts = end } };
            },
            .brk => |id| blk: {
                name = "Change Break";
                const b = w.brk(id) orelse return self.setMode(ctx, .browse);
                const off = b.shift.shift.utc_offset_secs;
                const start = sheet.anchorAfter(b.shift.shift.in_ts, off, t0);
                const end = if (t1) |t| sheet.endAfter(start, off, t) else null;
                if (end) |x| if (!sheet.validBreak(start, x)) return self.fieldError(ctx, 1, "A break can't run longer than 12 hours{s}.", "");
                break :blk .{ .put_break = .{ .id = id, .shift_id = b.shift.shift.id, .in_ts = start, .out_ts = end } };
            },
        };
        const then_pick = self.then_pick;
        self.then_pick = false;
        if (!self.change(name, op)) return self.setMode(ctx, .browse);
        self.msg = null;
        if (then_pick) return self.startPick(ctx);
        try self.setMode(ctx, .browse);
    }

    fn fieldError(self: *Timesheet, ctx: *vxfw.EventContext, idx: u1, comptime f: []const u8, arg: []const u8) !void {
        self.flash(true, f, .{arg});
        self.field_focus = idx;
        try ctx.requestFocus(self.fields[idx].widget());
        ctx.consumeAndRedraw();
    }

    fn startPick(self: *Timesheet, ctx: *vxfw.EventContext) !void {
        const w = self.week orelse return;
        const sel = self.selection orelse return;
        if (sel != .entry or w.entry(sel.entry) == null) {
            self.flash(false, "Select time to change its project.", .{});
            return ctx.consumeAndRedraw();
        }
        self.filter.clearAndFree();
        self.picked = 0;
        try self.setMode(ctx, .pick);
    }

    fn pick(self: *Timesheet, ctx: *vxfw.EventContext) !void {
        var tmp: std.heap.ArenaAllocator = .init(self.gpa);
        defer tmp.deinit();
        const a = tmp.allocator();
        const w = self.week orelse return;
        const opts = try ui.options(a, w.names, self.here, try ui.fieldText(a, &self.filter));
        if (opts.len == 0) return ctx.consumeEvent();
        const o = opts[@min(self.picked, opts.len - 1)];
        const sel = self.selection orelse return self.setMode(ctx, .browse);
        const e = (if (sel == .entry) w.entry(sel.entry) else null) orelse return self.setMode(ctx, .browse);
        if (self.change("Change Project", .{ .entry = .{ .id = e.id, .edit = .{
            .project_id = if (o.target) |t| t.project_id else null,
            .workspace_id = if (o.target) |t| t.workspace_id else null,
            .in_ts = e.in_ts,
            .out_ts = e.out_ts,
            .note = e.note,
        } } })) self.flash(false, "Moved to {s}.", .{o.label});
        try self.setMode(ctx, .browse);
    }

    fn startNote(self: *Timesheet, ctx: *vxfw.EventContext) !void {
        const w = self.week orelse return;
        const sel = self.selection orelse return;
        const e = (if (sel == .entry) w.entry(sel.entry) else null) orelse {
            self.flash(false, "Select time to add a note to it.", .{});
            return ctx.consumeAndRedraw();
        };
        self.note.clearAndFree();
        if (e.note) |n| try self.note.insertSliceAtCursor(n);
        try self.setMode(ctx, .note);
    }

    fn saveNote(self: *Timesheet, ctx: *vxfw.EventContext) !void {
        const w = self.week orelse return;
        const sel = self.selection orelse return self.setMode(ctx, .browse);
        const e = (if (sel == .entry) w.entry(sel.entry) else null) orelse return self.setMode(ctx, .browse);
        const text = std.mem.trim(u8, try ui.fieldText(self.history.allocator(), &self.note), " \t");
        _ = self.change("Change Note", .{ .entry = .{ .id = e.id, .edit = .{
            .project_id = e.project_id,
            .workspace_id = e.workspace_id,
            .in_ts = e.in_ts,
            .out_ts = e.out_ts,
            .note = if (text.len == 0) null else text,
        } } });
        try self.setMode(ctx, .browse);
    }

    fn copy(self: *Timesheet, ctx: *vxfw.EventContext) !void {
        var tmp: std.heap.ArenaAllocator = .init(self.gpa);
        defer tmp.deinit();
        const a = tmp.allocator();
        const w = self.week orelse return;
        const sel = self.selection orelse return;
        const text: []const u8 = switch (sel) {
            .day => |d| try std.fmt.allocPrint(a, "{f}\t{f}", .{ fmt.date(w.days[d], local.utcOffset(w.days[d])), fmt.dur((try w.summary(a, d, self.now)).worked) }),
            .shift => |id| blk: {
                const s = w.shift(id) orelse return;
                break :blk try std.fmt.allocPrint(a, "Shift\t{s}", .{try spanText(a, s.shift.in_ts, s.shift.out_ts, s.shift.utc_offset_secs, self.now)});
            },
            .entry => |id| blk: {
                const e = w.entry(id) orelse return;
                const label = try w.names.label(a, e.project_id, e.workspace_id);
                const span = try spanText(a, e.in_ts, e.out_ts, e.utc_offset_secs, self.now);
                break :blk if (e.note) |n|
                    try std.fmt.allocPrint(a, "{s}\t{s}\t{s}", .{ label, span, n })
                else
                    try std.fmt.allocPrint(a, "{s}\t{s}", .{ label, span });
            },
            .brk => |id| blk: {
                const b = w.brk(id) orelse return;
                break :blk try std.fmt.allocPrint(a, "Break\t{s}", .{try spanText(a, b.brk.in_ts, b.brk.out_ts, b.shift.shift.utc_offset_secs, self.now)});
            },
        };
        try ctx.copyToClipboard(text);
        self.flash(false, "Copied.", .{});
    }

    fn toggleFold(self: *Timesheet, day: usize) void {
        const w = self.week orelse return;
        if (!w.hasTime(day)) return;
        self.fold[day] = !self.isFolded(w, day);
    }

    fn toggleFoldAll(self: *Timesheet) void {
        const w = self.week orelse return;
        const d = self.selectedDay() orelse return;
        const fold = !self.isFolded(w, d);
        for (0..7) |i| if (w.hasTime(i)) {
            self.fold[i] = fold;
        };
        if (fold) self.selection = .{ .day = d };
    }

    fn move(self: *Timesheet, delta: isize) !void {
        var tmp: std.heap.ArenaAllocator = .init(self.gpa);
        defer tmp.deinit();
        const all = try self.lines(tmp.allocator());
        if (all.len == 0) return;
        const i: isize = @intCast(self.selected(all) orelse 0);
        const j: usize = @intCast(std.math.clamp(i + delta, 0, @as(isize, @intCast(all.len - 1))));
        self.selection = all[j].item();
        self.sel_index = j;
    }

    /// Moves to the next (or previous) day's header.
    fn moveDay(self: *Timesheet, forward: bool) !void {
        var tmp: std.heap.ArenaAllocator = .init(self.gpa);
        defer tmp.deinit();
        const all = try self.lines(tmp.allocator());
        const i = self.selected(all) orelse return;
        if (forward) {
            for (all[i + 1 ..], i + 1..) |l, j| if (l == .day) {
                self.selection = l.item();
                self.sel_index = j;
                return;
            };
        } else {
            var j = i;
            while (j > 0) {
                j -= 1;
                // Back to this day's header first, then the one before.
                if (all[j] == .day) {
                    self.selection = all[j].item();
                    self.sel_index = j;
                    return;
                }
            }
        }
    }

    fn moveWeek(self: *Timesheet, weeks: i64) void {
        self.goToWeek(self.first + weeks * 7 * std.time.s_per_day + std.time.s_per_day / 2);
    }

    // ── Events ────────────────────────────────────────────────────────────

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Timesheet = @ptrCast(@alignCast(ptr));
        switch (event) {
            .key_press => |key| try self.onKey(ctx, key),
            else => {},
        }
    }

    fn onKey(self: *Timesheet, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        if (key.matches('c', .{ .ctrl = true })) return;
        const esc = key.matches(vaxis.Key.escape, .{});
        const enter = key.matches(vaxis.Key.enter, .{});
        switch (self.mode) {
            .help => return self.setMode(ctx, .browse),
            .edit => {
                if (esc) {
                    self.then_pick = false;
                    self.msg = null;
                    return self.setMode(ctx, .browse);
                }
                if (enter) return self.saveEdit(ctx);
                const next = key.matches('\t', .{}) or key.matches(vaxis.Key.down, .{}) or key.matches(vaxis.Key.up, .{}) or key.matches('\t', .{ .shift = true });
                if (next and self.field_count == 2) {
                    self.field_focus +%= 1;
                    try ctx.requestFocus(self.fields[self.field_focus].widget());
                    return ctx.consumeAndRedraw();
                }
            },
            .pick => {
                if (esc) return self.setMode(ctx, .browse);
                if (ui.movePick(key, &self.picked)) return ctx.consumeAndRedraw();
                if (enter) return self.pick(ctx);
            },
            .note => {
                if (esc) return self.setMode(ctx, .browse);
                if (enter) return self.saveNote(ctx);
            },
            .browse => try self.onBrowseKey(ctx, key),
        }
    }

    fn onBrowseKey(self: *Timesheet, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        self.msg = null;
        const k = vaxis.Key;
        if (key.matches('j', .{}) or key.matches(k.down, .{})) {
            try self.move(1);
        } else if (key.matches('k', .{}) or key.matches(k.up, .{})) {
            try self.move(-1);
        } else if (key.matches('g', .{}) or key.matches(k.home, .{})) {
            try self.move(-std.math.maxInt(i32));
        } else if (key.matches('G', .{}) or key.matches('g', .{ .shift = true }) or key.matches(k.end, .{})) {
            try self.move(std.math.maxInt(i32));
        } else if (key.matches('J', .{}) or key.matches('j', .{ .shift = true }) or key.matches('\t', .{})) {
            try self.moveDay(true);
        } else if (key.matches('K', .{}) or key.matches('k', .{ .shift = true }) or key.matches('\t', .{ .shift = true })) {
            try self.moveDay(false);
        } else if (key.matches('h', .{}) or key.matches(k.left, .{}) or key.matches('[', .{})) {
            self.moveWeek(-1);
        } else if (key.matches('l', .{}) or key.matches(k.right, .{}) or key.matches(']', .{})) {
            self.moveWeek(1);
        } else if (key.matches('t', .{})) {
            self.stampNow();
            self.goToWeek(self.now);
        } else if (key.matches(' ', .{}) or key.matches('z', .{})) {
            if (self.selectedDay()) |d| {
                self.toggleFold(d);
                if (self.week) |w| if (self.isFolded(w, d)) {
                    self.selection = .{ .day = d };
                };
            }
        } else if (key.matches('Z', .{}) or key.matches('z', .{ .shift = true })) {
            self.toggleFoldAll();
        } else if (key.matches(k.enter, .{}) or key.matches('e', .{})) {
            const sel = self.selection orelse return ctx.consumeAndRedraw();
            return self.startEdit(ctx, sel);
        } else if (key.matches('a', .{})) {
            return self.addEntry(ctx);
        } else if (key.matches('A', .{}) or key.matches('a', .{ .shift = true })) {
            return self.addShift(ctx);
        } else if (key.matches('b', .{})) {
            return self.addBreak(ctx);
        } else if (key.matches('p', .{})) {
            return self.startPick(ctx);
        } else if (key.matches('n', .{})) {
            return self.startNote(ctx);
        } else if (key.matches('x', .{})) {
            self.stop();
        } else if (key.matches('d', .{}) or key.matches(k.delete, .{}) or key.matches(k.backspace, .{})) {
            self.delete();
        } else if (key.matches('u', .{})) {
            self.undo();
        } else if (key.matches('U', .{}) or key.matches('u', .{ .shift = true }) or key.matches('r', .{ .ctrl = true })) {
            self.redo();
        } else if (key.matches('y', .{})) {
            try self.copy(ctx);
        } else if (key.matches('w', .{})) {
            self.show_totals = !self.show_totals;
        } else if (key.matches('?', .{}) or key.matches('/', .{ .shift = true })) {
            return self.setMode(ctx, .help);
        } else return; // esc, q, and the rest are the tracker's
        ctx.consumeAndRedraw();
    }

    fn setMode(self: *Timesheet, ctx: *vxfw.EventContext, mode: Mode) !void {
        self.mode = mode;
        if (mode != .edit) self.editing = null;
        try ctx.requestFocus(self.focusedWidget());
        ctx.consumeAndRedraw();
    }

    fn onFilterChange(ptr: ?*anyopaque, _: *vxfw.EventContext, _: []const u8) anyerror!void {
        const self: *Timesheet = @ptrCast(@alignCast(ptr.?));
        self.picked = 0;
    }

    // ── Drawing ───────────────────────────────────────────────────────────

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Timesheet = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    fn draw(self: *Timesheet, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const size = ctx.max.size();
        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), size);
        var children: std.ArrayList(vxfw.SubSurface) = .empty;
        const width = @min(size.width -| 4, max_width);
        var p: Painter = .{ .ctx = ctx, .surface = surface, .left = (size.width -| width) / 2, .width = width, .height = size.height };
        const a = ctx.arena;

        const w = self.week orelse {
            p.put("Loading...", dim);
            return p.surface;
        };
        const now = self.now;

        // Title
        p.put("Timesheet", bold);
        const this_week = now >= w.days[0] and now < w.days[7];
        try p.right(try p.fmt("{s}Week of {f}", .{ if (this_week) "This week · " else "", fmt.date(w.days[0], local.utcOffset(w.days[0])) }), dim);
        p.nl(2);

        const hints: []const ui.Hint = &.{
            .{ "⏎", "edit" },    .{ "a", "add time" }, .{ "A", "shift" }, .{ "b", "break" },
            .{ "p", "project" }, .{ "n", "note" },     .{ "d", "delete" }, .{ "u", "undo" },
            .{ "←→", "week" },   .{ "?", "all keys" }, .{ "esc", "back" },
        };
        const footer_row = size.height -| (1 + if (self.mode == .browse) ui.hintRows(ctx, hints, width) else 1);
        if (self.mode == .help) {
            drawHelp(&p, footer_row);
            p.row = footer_row;
            p.col = 0;
            p.put("any key closes", dim);
            return p.surface;
        }

        try self.drawStrip(&p, w, a);
        p.nl(1);

        const s = try w.summary(a, null, now);
        try p.print(.{}, "{f}", .{fmt.dur(s.worked)});
        p.put(" worked", dim);
        if (s.over > 0) try p.print(yellow, "  +{f}", .{fmt.dur(s.over)});
        try p.print(dim, "  ·  {f} tracked  ·  {f} untracked  ·  {f} on break", .{ fmt.dur(s.tracked), fmt.dur(s.untracked), fmt.dur(s.on_break) });
        if (try w.goal(a, now)) |g| {
            p.nl(1);
            try p.print(dim, "Goal {f}", .{fmt.dur(g.secs)});
            if (g.isMet()) {
                p.put("  ·  ", dim);
                p.put("met", green);
                if (g.over() >= 60) try p.print(dim, "  ·  {f} over", .{fmt.dur(g.over())});
            } else {
                try p.print(.{}, "  ·  {f} left", .{fmt.dur(g.left())});
                if (g.leftAfterClockOut()) |after| {
                    if (after == 0) {
                        try p.print(green, "  ·  met at {f}", .{fmt.clock(g.meets_at.?, self.utc_offset_secs)});
                    } else try p.print(dim, "  ·  {f} after today's clock out", .{fmt.dur(after)});
                }
            }
        }
        p.nl(2);

        switch (self.mode) {
            .help => unreachable,
            .pick => try self.drawPicker(&p, &children, w, a, footer_row),
            else => if (self.show_totals) {
                // Clipped above the footer.
                const height = p.height;
                p.height = footer_row -| 1;
                try drawTotals(&p, w, a, now);
                p.height = height;
            } else try self.drawDays(&p, w, a, footer_row),
        }

        p.row = footer_row;
        p.col = 0;
        p.highlight = false;
        switch (self.mode) {
            .browse => ui.drawHints(&p, hints),
            .help => unreachable,
            .pick => ui.drawHints(&p, &.{ .{ "⏎", "choose" }, .{ "↑↓", "move" }, .{ "esc", "cancel" } }),
            .note => {
                p.put("Note ", bold);
                try children.append(a, try p.field(self.note.widget(), 5, width -| 5));
            },
            .edit => {
                var col: u16 = 0;
                for (0..self.field_count) |i| {
                    p.col = col;
                    p.put(self.field_labels[i], if (self.field_focus == i) bold else dim);
                    p.put(" ", .{});
                    const field_col = p.col;
                    p.put("▕", dim);
                    try children.append(a, try p.field(self.fields[i].widget(), field_col + 1, 10));
                    p.col = field_col + 11;
                    p.put("▏", dim);
                    col = p.col + 2;
                }
                p.col = col;
                p.put(if (self.field_count == 2) "⏎ save  tab switch  esc cancel" else "⏎ save  esc cancel", dim);
            },
        }
        p.nl(1);
        if (self.msg) |m| p.put(self.msg_buf[0..m.len], if (m.err) red else .{});

        var out = p.surface;
        out.children = children.items;
        return out;
    }

    /// Each day's label and time, the selected day marked.
    fn drawStrip(self: *Timesheet, p: *Painter, w: sheet.Week, a: Allocator) !void {
        const cell: u16 = p.width / 7;
        const sel_day = self.selectedDay();
        const today = if (self.now < w.days[7]) w.dayOf(self.now) else null;
        for (0..7) |d| {
            p.col = @intCast(d * cell);
            var style: vaxis.Style = if (w.isVisible(d)) .{} else dim;
            if (today == d) style = .{ .bold = true, .fg = green.fg };
            if (sel_day == d) style.ul_style = .single;
            try p.print(style, "{s}", .{try dayLabel(a, w.days[d])});
        }
        p.nl(1);
        for (0..7) |d| {
            p.col = @intCast(d * cell);
            const sum = try w.summary(a, d, self.now);
            const secs = if (sum.worked > 0) sum.worked else sum.tracked;
            if (secs > 0) try p.print(.{}, "{f}", .{fmt.dur(secs)}) else p.put("—", dim);
            if (sum.over > 0) p.put("+", yellow);
        }
        p.nl(1);
    }

    fn drawDays(self: *Timesheet, p: *Painter, w: sheet.Week, a: Allocator, bottom: u16) !void {
        const all = try self.lines(a);
        if (all.len == 0) {
            p.put("No days to show this week. Set the days you work in the menu bar's Settings.", dim);
            return;
        }
        const room: usize = @max(1, bottom -| p.row -| 1);
        if (self.selected(all)) |si| {
            if (si < self.scroll) self.scroll = si;
            if (si >= self.scroll + room) self.scroll = si + 1 - room;
        }
        self.scroll = @min(self.scroll, all.len -| room);
        const sel = self.selection;
        for (all[self.scroll..@min(all.len, self.scroll + room)]) |l| {
            p.highlight = if (sel) |s| l.item().eql(s) else false;
            switch (l) {
                .day => |d| try self.drawDay(p, w, a, d),
                .shift => |s| try self.drawShift(p, w, a, s),
                .row => |r| switch (r) {
                    .entry => |e| try self.drawEntry(p, w, a, e),
                    .brk => |b| try self.drawBreak(p, w, a, b.brk, b.shift),
                },
            }
            p.nl(1);
        }
        p.highlight = false;
    }

    fn drawDay(self: *Timesheet, p: *Painter, w: sheet.Week, a: Allocator, d: usize) !void {
        const has = w.hasTime(d);
        p.put(if (!has) "  " else if (self.isFolded(w, d)) "▸ " else "▾ ", dim);
        const is_today = self.now < w.days[7] and w.dayOf(self.now) == d;
        try p.print(if (is_today) .{ .bold = true, .fg = green.fg } else bold, "{f}", .{fmt.date(w.days[d], local.utcOffset(w.days[d]))});
        if (is_today) p.put("  today", dim);
        if (!has) {
            p.put(if (w.isWorkDay(d)) "   nothing yet" else "   day off", dim);
            return;
        }
        const sum = try w.summary(a, d, self.now);
        const secs = if (sum.worked > 0) sum.worked else sum.tracked;
        const total_str = try p.fmt("{f}", .{fmt.dur(secs)});
        const over_str = if (sum.over > 0) try p.fmt("  +{f}", .{fmt.dur(sum.over)}) else "";
        const tracked_str = if (sum.worked > 0) try p.fmt("{f} tracked  ·  ", .{fmt.dur(sum.tracked)}) else "";
        const wd: u16 = @intCast(p.ctx.stringWidth(tracked_str) + p.ctx.stringWidth(total_str) + p.ctx.stringWidth(over_str));
        p.pad(p.width -| wd);
        p.put(tracked_str, dim);
        p.put(total_str, bold);
        p.put(over_str, yellow);
    }

    fn drawShift(self: *Timesheet, p: *Painter, w: sheet.Week, a: Allocator, s: sheet.SheetShift) !void {
        const off = s.shift.utc_offset_secs;
        const now = self.now;
        try drawSpan(p, s.shift.in_ts, s.shift.out_ts, off);
        const done = try sheet.worked(a, s.shift, s.breaks, now);
        try drawDur(p, done);
        p.pad(label_col);
        p.put("Shift", bold);
        const o = done - s.shift.target_secs;
        if (o >= 60) try p.print(yellow, "  +{f}", .{fmt.dur(o)});
        if (s.shift.out_ts == null) {
            const out = try w.expectedEnd(a, s, now);
            try p.print(dim, "  out ", .{});
            try p.print(bold, "{f}", .{fmt.clock(out, self.utc_offset_secs)});
        } else try p.print(dim, "  of {f}", .{fmt.dur(s.shift.target_secs)});
        if (try w.lunchOf(a, s, now)) |plan| {
            const note = lunchNote(a, plan, now, off) catch return;
            p.put("  ·  ", dim);
            p.put(note.text, note.style);
        }
    }

    fn drawEntry(self: *Timesheet, p: *Painter, w: sheet.Week, a: Allocator, e: store.Entry) !void {
        try drawSpan(p, @max(e.in_ts, w.days[0]), e.out_ts, e.utc_offset_secs);
        try drawDur(p, w.seconds(e, self.now));
        p.pad(label_col);
        if (e.out_ts == null) p.put("● ", green);
        p.put(try w.names.label(a, e.project_id, e.workspace_id), ui.projectStyle(w.names, e.project_id, false));
        if (e.kind == .meeting) {
            try p.print(cyan, "  Meeting: {s}", .{e.note orelse "untitled"});
        } else if (e.note) |n| try p.print(dim, "  {s}", .{n});
    }

    fn drawBreak(self: *Timesheet, p: *Painter, w: sheet.Week, a: Allocator, b: store.Break, s: sheet.SheetShift) !void {
        try drawSpan(p, b.in_ts, b.out_ts, s.shift.utc_offset_secs);
        try drawDur(p, (b.out_ts orelse @max(self.now, b.in_ts)) - b.in_ts);
        p.pad(label_col);
        const plan = try w.lunchOf(a, s, self.now);
        const lunch = if (plan) |pl| pl.isLunch(b.in_ts) else false;
        p.put(if (lunch) "Lunch" else "Break", yellow);
        if (b.out_ts == null) p.put("  on it now", dim) else if (b.in_ts > self.now) p.put("  planned", dim);
    }

    fn drawPicker(self: *Timesheet, p: *Painter, children: *std.ArrayList(vxfw.SubSurface), w: sheet.Week, a: Allocator, bottom: u16) !void {
        p.put("Project", bold);
        if (self.selection) |sel| if (sel == .entry) if (w.entry(sel.entry)) |e| {
            try p.print(dim, "  for {s}", .{try spanText(a, e.in_ts, e.out_ts, e.utc_offset_secs, self.now)});
        };
        p.nl(1);
        p.put("  › ", dim);
        try children.append(a, try p.field(self.filter.widget(), 4, @min(p.width -| 4, 40)));
        p.nl(2);
        const opts = try ui.options(a, w.names, self.here, try ui.fieldText(a, &self.filter));
        ui.drawOptions(p, opts, self.picked, bottom);
    }
};

fn drawSpan(p: *Painter, start: i64, end: ?i64, off: i64) !void {
    p.pad(4);
    try p.print(.{}, "{f}", .{fmt.clock(start, off)});
    p.put(" – ", dim);
    if (end) |e| try p.print(.{}, "{f}", .{fmt.clock(e, off)}) else p.put("now", green);
}

/// A duration ending at `dur_end`.
fn drawDur(p: *Painter, secs: i64) !void {
    const s = try p.fmt("{f}", .{fmt.dur(secs)});
    p.pad(dur_end -| @as(u16, @intCast(s.len)));
    p.put(s, .{});
}

fn drawTotals(p: *Painter, w: sheet.Week, a: Allocator, now: i64) !void {
    const s = try w.summary(a, null, now);
    p.put("This week", bold);
    p.nl(1);
    const rows = [_]struct { []const u8, i64 }{
        .{ "Worked", s.worked },
        .{ "Over", s.over },
        .{ "On break", s.on_break },
        .{ "Tracked", s.tracked },
        .{ "Untracked", s.untracked },
    };
    for (rows) |r| {
        try p.print(.{}, "  {s: >7}  ", .{try p.fmt("{f}", .{fmt.dur(r[1])})});
        p.put(r[0], dim);
        p.nl(1);
    }
    const t = try w.totals(a, now);
    p.nl(1);
    p.put("By project", bold);
    p.nl(1);
    if (t.by_project.len == 0) {
        p.put("  Nothing tracked this week.", dim);
        p.nl(1);
    }
    for (t.by_project) |pt| {
        try p.print(.{}, "  {s: >7}  ", .{try p.fmt("{f}", .{fmt.dur(pt.secs)})});
        p.put(try w.names.label(a, pt.id, null), ui.projectStyle(w.names, pt.id, false));
        if (w.names.clientOf(pt.id)) |cl| try p.print(dim, "  {s}", .{cl.name});
        p.nl(1);
    }
    if (t.any_client) {
        p.nl(1);
        p.put("By client", bold);
        p.nl(1);
        for (t.by_client) |ct| {
            try p.print(.{}, "  {s: >7}  ", .{try p.fmt("{f}", .{fmt.dur(ct.secs)})});
            if (ct.id) |id| p.put(w.names.client(id).?.name, .{}) else p.put("(no client)", dim);
            p.nl(1);
        }
    }
}

const help = [_][2][]const u8{
    .{ "↑↓ j k", "Move between days and rows" },
    .{ "tab J  ⇧tab K", "Next or previous day" },
    .{ "←→ h l [ ]", "Previous or next week" },
    .{ "t", "This week, today" },
    .{ "space z", "Fold or open the day; Z every day" },
    .{ "⏎ e", "Edit times; on a day, fold it" },
    .{ "a", "Add time on the day, then pick its project" },
    .{ "A", "Add a shift you forgot to clock" },
    .{ "b", "Add a break to the day's shift" },
    .{ "p  n", "Change the time's project or note" },
    .{ "x", "Stop the running time, or end the break" },
    .{ "d ⌫", "Delete" },
    .{ "u  U ctrl+r", "Undo, redo" },
    .{ "y", "Copy the row" },
    .{ "w", "The week's totals by project and client, and back" },
    .{ "esc", "Back to today" },
};

fn drawHelp(p: *Painter, bottom: u16) void {
    p.put("Keys", bold);
    p.nl(1);
    for (help) |h| {
        if (p.row >= bottom) break;
        p.pad(2);
        p.put(h[0], bold);
        p.pad(18);
        p.put(h[1], .{});
        p.nl(1);
    }
}

/// How lunch stands on a shift, for its line.
fn lunchNote(a: Allocator, plan: sheet.Plan, now: i64, off: i64) !struct { text: []const u8, style: vaxis.Style } {
    return switch (plan.status(now)) {
        .upcoming => .{ .text = try std.fmt.allocPrint(a, "lunch {f} – {f}", .{ fmt.clock(plan.opens, off), fmt.clock(plan.closes, off) }), .style = cyan },
        .open => .{ .text = try std.fmt.allocPrint(a, "lunch by {f}", .{fmt.clock(plan.closes, off)}), .style = yellow },
        .on_lunch => .{ .text = "on lunch", .style = yellow },
        .taken => if (plan.lunch.?.start > now)
            .{ .text = try std.fmt.allocPrint(a, "lunch at {f}", .{fmt.clock(plan.lunch.?.start, off)}), .style = cyan }
        else
            .{ .text = "had lunch", .style = dim },
        .late => .{ .text = "lunch late", .style = yellow },
        .missed => .{ .text = "no lunch", .style = red },
    };
}

fn clockStr(ts: i64, off: i64) [8]u8 {
    // Every time of day fits.
    return Time.fromTs(ts + off).toStr() catch unreachable;
}

/// `8h`, `7h30m`: a length the length field reads back.
fn lengthStr(buf: []u8, secs: i64) []const u8 {
    const mins: u64 = @intCast(@divFloor(@max(secs, 0), 60));
    return (if (mins % 60 == 0)
        std.fmt.bufPrint(buf, "{d}h", .{mins / 60})
    else
        std.fmt.bufPrint(buf, "{d}h{d}m", .{ mins / 60, mins % 60 })) catch "8h";
}

fn spanText(a: Allocator, start: i64, end: ?i64, off: i64, now: i64) ![]const u8 {
    if (end) |e| return std.fmt.allocPrint(a, "{f} – {f}\t{f}", .{ fmt.clock(start, off), fmt.clock(e, off), fmt.dur(e - start) });
    return std.fmt.allocPrint(a, "{f} – now\t{f}", .{ fmt.clock(start, off), fmt.dur(now - start) });
}

/// `Tue 10`.
fn dayLabel(a: Allocator, midnight: i64) ![]const u8 {
    const full = try std.fmt.allocPrint(a, "{f}", .{fmt.date(midnight, local.utcOffset(midnight))});
    var it = std.mem.tokenizeScalar(u8, full, ' ');
    const wd = it.next() orelse return full;
    _ = it.next();
    const day = it.next() orelse return full;
    return std.fmt.allocPrint(a, "{s} {s}", .{ wd, day });
}

const testing = std.testing;

test "lengthStr reads back" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("8h", lengthStr(&buf, 8 * 3600));
    try testing.expectEqual(7 * 3600 + 30 * 60, try core.time.parseDuration(lengthStr(&buf, 7 * 3600 + 30 * 60)));
}

fn testSheet(db: *Store) !*Timesheet {
    const env = try testing.allocator.create(std.process.Environ.Map);
    env.* = .init(testing.allocator);
    const t = try testing.allocator.create(Timesheet);
    t.* = .init(testing.allocator, testing.io, env, db);
    t.bind();
    return t;
}

fn freeSheet(t: *Timesheet) void {
    const env: *std.process.Environ.Map = @constCast(t.env);
    t.deinit();
    env.deinit();
    testing.allocator.destroy(env);
    testing.allocator.destroy(t);
}

test "perform - every change undoes" {
    var db: Store = try .open(testing.io, ":memory:");
    defer db.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try testSheet(&db);
    defer freeSheet(t);

    const h = std.time.s_per_hour;
    const start: i64 = 1794268800 + 15 * h;
    const at: local.Stamp = .{ .ts = start, .utc_offset_secs = 0, .tz = null };
    const entry_id = try db.addEntry(.{ .source = .tui, .note = "first" }, at, start + h);
    const shift_id = try db.addShift(at, start + 8 * h);

    // Moving an entry, then undoing it, puts it back.
    const undo_edit = try t.perform(.{ .entry = .{ .id = entry_id, .edit = .{ .project_id = null, .workspace_id = null, .in_ts = start + 60, .out_ts = start + 2 * h, .note = null } } });
    try testing.expectEqual(start + 60, (try db.entryById(a, entry_id)).?.in_ts);
    _ = try t.perform(undo_edit);
    const back = (try db.entryById(a, entry_id)).?;
    try testing.expectEqual(start, back.in_ts);
    try testing.expectEqualStrings("first", back.note.?);

    // Deleting and restoring.
    const restore = try t.perform(.{ .delete_entry = entry_id });
    try testing.expectEqual(null, try db.entryById(a, entry_id));
    _ = try t.perform(restore);
    try testing.expect(try db.entryById(a, entry_id) != null);

    // A new break undoes to no break; an edited one to what it was.
    const brk_id: Uuid = .v7At(5, @splat(1));
    const undo_add = try t.perform(.{ .put_break = .{ .id = brk_id, .shift_id = shift_id, .in_ts = start + 3 * h, .out_ts = start + 3 * h + 1800 } });
    try testing.expect(undo_add == .delete_break);
    const undo_move = try t.perform(.{ .put_break = .{ .id = brk_id, .shift_id = shift_id, .in_ts = start + 4 * h, .out_ts = start + 4 * h + 1800 } });
    try testing.expectEqual(start + 3 * h, undo_move.put_break.in_ts);
    const redo_add = try t.perform(undo_add);
    try testing.expectEqual(null, try db.breakById(brk_id));
    _ = try t.perform(redo_add);
    try testing.expectEqual(start + 4 * h, (try db.breakById(brk_id)).?.in_ts);

    // Shift times.
    const undo_times = try t.perform(.{ .shift_times = .{ .id = shift_id, .in_ts = start - h, .out_ts = start + 7 * h } });
    _ = try t.perform(undo_times);
    const s = (try db.shiftById(a, shift_id)).?;
    try testing.expectEqual(start, s.in_ts);
    try testing.expectEqual(start + 8 * h, s.out_ts.?);
}
