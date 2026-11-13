//! The timesheet and the lunch window, as the menu bar app works them out,
//! for the TUI and CLI: a week of shifts, breaks, and entries, what each
//! shift worked, when lunch is due, and where new rows go.
//!
//! Times are unix seconds. A local time of day is placed with the UTC offset
//! of the row it belongs to, as the rows record it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const core = @import("core");
const Uuid = core.Uuid;
const Time = core.time.Time;
const fmt = core.fmt;

const store = @import("root.zig");
const Store = store.Store;
const report = @import("report.zig");

const s_per_day = std.time.s_per_day;

/// No entry is longer than this; an end that would make one is a typo.
pub const max_entry_secs = 16 * std.time.s_per_hour;
/// Nor any break; most likely its start and end were swapped.
pub const max_break_secs = 12 * std.time.s_per_hour;

pub const Span = struct {
    start: i64,
    end: i64,
};

/// `spans` with every part of `cuts` removed. Allocated in `arena`.
pub fn subtract(arena: Allocator, spans: []const Span, cuts: []const Span) Allocator.Error![]Span {
    var out: std.ArrayList(Span) = .empty;
    for (spans) |s| if (s.start < s.end) try out.append(arena, s);
    for (cuts) |cut| {
        if (cut.start >= cut.end) continue;
        var next: std.ArrayList(Span) = .empty;
        for (out.items) |s| {
            if (cut.start >= s.end or cut.end <= s.start) {
                try next.append(arena, s);
                continue;
            }
            if (s.start < cut.start) try next.append(arena, .{ .start = s.start, .end = cut.start });
            if (cut.end < s.end) try next.append(arena, .{ .start = cut.end, .end = s.end });
        }
        out = next;
    }
    return out.items;
}

/// Seconds covered; `spans` shouldn't overlap.
pub fn total(spans: []const Span) i64 {
    var sum: i64 = 0;
    for (spans) |s| sum += @max(0, s.end - s.start);
    return sum;
}

// ── Lunch ───────────────────────────────────────────────────────────────────

/// When lunch has to happen, counted in time worked: the lunch window break
/// preset, if it's on and makes sense.
pub const Lunch = struct {
    preset_id: Uuid,
    /// Worked time before lunch is worth taking.
    earliest_secs: i64,
    /// Worked time lunch has to start by.
    latest_secs: i64,
    /// Shorter breaks are rests, not lunch.
    minimum_secs: i64,
    /// Whether starting and ending lunch offers the clock links.
    clock_link: bool,

    /// The first window preset, if it's on and makes sense.
    pub fn fromPresets(presets: []const store.BreakPreset) ?Lunch {
        for (presets) |p| switch (p.rule) {
            .window => |w| {
                if (!p.enabled or w.earliest_secs < 0 or w.earliest_secs >= w.latest_secs or w.minimum_secs <= 0) return null;
                return .{
                    .preset_id = p.id,
                    .earliest_secs = w.earliest_secs,
                    .latest_secs = w.latest_secs,
                    .minimum_secs = w.minimum_secs,
                    .clock_link = p.clockLink(),
                };
            },
            .scheduled => {},
        };
        return null;
    }

    pub fn load(db: *Store, arena: Allocator) store.Error!?Lunch {
        return fromPresets(try db.breakPresets(arena));
    }

    /// Where lunch falls on a shift clocked in at `clock_in`, or null if it's
    /// too short to need one. `worked` is the shift's work: its length while
    /// you're on it, what you actually worked once it's over. `brks` are
    /// oldest first; the one in progress has no end.
    pub fn plan(l: Lunch, clock_in: i64, work_secs: i64, brks: []const store.Break, now: i64) ?Plan {
        if (work_secs <= l.latest_secs) return null;
        // The first break long enough to be lunch, or the one you're on.
        var lunch: ?Plan.Taken = null;
        for (brks) |b| {
            const long = if (b.out_ts) |out| out - b.in_ts >= l.minimum_secs else true;
            if (long) {
                lunch = .{ .start = b.in_ts, .end = b.out_ts };
                break;
            }
        }
        // Breaks before lunch push the window later; lunch itself doesn't.
        var buf: [64]core.shift.Interval = undefined;
        var n: usize = 0;
        for (brks) |b| {
            if (lunch) |t| if (b.in_ts >= t.start) continue;
            if (n == buf.len) break;
            buf[n] = .{ .in_ts = b.in_ts, .out_ts = b.out_ts orelse @max(now, b.in_ts) };
            n += 1;
        }
        return .{
            .opens = core.shift.clockIn(l.earliest_secs, clock_in, buf[0..n]),
            .closes = core.shift.clockIn(l.latest_secs, clock_in, buf[0..n]),
            .lunch = lunch,
        };
    }

    /// Lunch on `shift`: the open one counts its length, an ended one what
    /// it worked.
    pub fn planFor(l: Lunch, arena: Allocator, shift: store.Shift, brks: []const store.Break, now: i64) Allocator.Error!?Plan {
        const worked_secs = if (shift.out_ts == null) shift.target_secs else try worked(arena, shift, brks, now);
        return l.plan(shift.in_ts, worked_secs, brks, now);
    }

    /// Lunch time clock out counts before you've had it: the minimum until
    /// you take lunch, then what's left of it while you're on it, then
    /// nothing. None when the shift doesn't need lunch.
    pub fn ahead(l: Lunch, p: ?Plan, now: i64) i64 {
        const pl = p orelse return 0;
        const t = pl.lunch orelse return l.minimum_secs;
        if (t.end != null) return 0;
        return @max(0, l.minimum_secs - (now - t.start));
    }
};

/// Lunch on one shift: the window it has to start in, and the break that was
/// lunch, if there's been one.
pub const Plan = struct {
    opens: i64,
    closes: i64,
    lunch: ?Taken,

    pub const Taken = struct {
        start: i64,
        /// null while it's running.
        end: ?i64,
    };

    pub const Status = enum {
        /// The window hasn't opened yet.
        upcoming,
        /// Time to take lunch.
        open,
        on_lunch,
        taken,
        /// Lunch started after the window closed.
        late,
        /// The window closed with no lunch.
        missed,
    };

    pub fn status(p: Plan, now: i64) Status {
        if (p.lunch) |t| {
            if (t.end == null) return .on_lunch;
            return if (t.start > p.closes) .late else .taken;
        }
        if (now < p.opens) return .upcoming;
        return if (now < p.closes) .open else .missed;
    }

    /// Whether the break that started at `break_in` is lunch.
    pub fn isLunch(p: Plan, break_in: i64) bool {
        const t = p.lunch orelse return false;
        return t.start == break_in;
    }
};

/// The open shift's clock out: its length of work after clock in, pushed
/// later by breaks (one in progress counting to `now`), plus lunch still to
/// come under `lunch`.
pub fn clockOut(arena: Allocator, shift: store.Shift, brks: []const store.Break, lunch: ?Lunch, now: i64) Allocator.Error!i64 {
    const base = store.clockOut(shift, brks, now);
    const l = lunch orelse return base;
    return base + l.ahead(try l.planFor(arena, shift, brks, now), now);
}

// ── Shifts ──────────────────────────────────────────────────────────────────

/// A shift's work: clock in to clock out (or `now`), less its breaks.
/// Allocated in `arena`.
pub fn work(arena: Allocator, shift: store.Shift, brks: []const store.Break, now: i64) Allocator.Error![]Span {
    const end = @max(shift.out_ts orelse now, shift.in_ts);
    const cuts = try arena.alloc(Span, brks.len);
    for (brks, cuts) |b, *c| c.* = .{ .start = b.in_ts, .end = b.out_ts orelse now };
    return subtract(arena, &.{.{ .start = shift.in_ts, .end = end }}, cuts);
}

/// Time worked on a shift, its breaks not counted.
pub fn worked(arena: Allocator, shift: store.Shift, brks: []const store.Break, now: i64) Allocator.Error!i64 {
    return total(try work(arena, shift, brks, now));
}

/// Time worked past the shift's length, or 0. Under a minute doesn't count,
/// so a shift clocked out on time doesn't read "+0m".
pub fn over(arena: Allocator, shift: store.Shift, brks: []const store.Break, now: i64) Allocator.Error!i64 {
    const o = try worked(arena, shift, brks, now) - shift.target_secs;
    return if (o >= 60) o else 0;
}

// ── The week ────────────────────────────────────────────────────────────────

pub const SheetShift = struct {
    shift: store.Shift,
    breaks: []store.Break,
};

/// Something on the timesheet you can select.
pub const Item = union(enum) {
    /// A day's header, by its index in the week.
    day: usize,
    shift: Uuid,
    entry: Uuid,
    brk: Uuid,

    pub fn eql(a: Item, b: Item) bool {
        return switch (a) {
            .day => |d| b == .day and b.day == d,
            .shift => |i| b == .shift and b.shift.eql(i),
            .entry => |i| b == .entry and b.entry.eql(i),
            .brk => |i| b == .brk and b.brk.eql(i),
        };
    }
};

/// A line under a day's shift: time tracked to a project, or a break.
pub const Row = union(enum) {
    entry: store.Entry,
    brk: struct { brk: store.Break, shift: SheetShift },

    pub fn start(r: Row) i64 {
        return switch (r) {
            .entry => |e| e.in_ts,
            .brk => |b| b.brk.in_ts,
        };
    }

    pub fn item(r: Row) Item {
        return switch (r) {
            .entry => |e| .{ .entry = e.id },
            .brk => |b| .{ .brk = b.brk.id },
        };
    }
};

pub const Week = struct {
    /// Local midnight starting each day, then the one after the last.
    days: [8]i64,
    /// The shared shifts; none when showing an organization with no shift.
    shifts: []SheetShift,
    /// The entries shown: the organization's, or all.
    entries: []store.Entry,
    names: report.Names,
    /// The organization shown; null for all.
    organization: ?Uuid = null,
    /// Every work entry, whatever's shown: what a shift's untracked time
    /// is counted against. Personal time on shift isn't work tracked.
    work_entries: []store.Entry = &.{},
    /// ISO weekdays you work: bit 0 is Monday.
    work_days: u7,
    lunch: ?Lunch,
    /// The weekly goal, if one is set.
    goal_secs: ?i64 = null,

    /// Allocated in `arena`.
    pub fn load(db: *Store, arena: Allocator, days: [8]i64) store.Error!Week {
        return loadFor(db, arena, days, null);
    }

    /// The week for one organization (null: all): its entries, and the
    /// shifts if it's on them. Allocated in `arena`.
    pub fn loadFor(db: *Store, arena: Allocator, days: [8]i64, organization: ?Uuid) store.Error!Week {
        const names: report.Names = try .load(db, arena);
        const on_shift = if (organization) |o|
            (if (names.organization(o)) |org| org.tracking == .shift else false)
        else
            true;
        const shifts = if (on_shift) try db.shiftsBetween(arena, days[0], days[7]) else &.{};
        const sheet_shifts = try arena.alloc(SheetShift, shifts.len);
        for (shifts, sheet_shifts) |s, *out| out.* = .{ .shift = s, .breaks = try db.breaks(arena, s.id) };
        const all = try db.entriesBetween(arena, days[0], days[7]);
        var work_entries: std.ArrayList(store.Entry) = .empty;
        for (all) |e| if (!names.isPersonal(e.project_id)) try work_entries.append(arena, e);
        return .{
            .days = days,
            .shifts = sheet_shifts,
            .entries = try names.only(arena, all, organization),
            .names = names,
            .organization = organization,
            .work_entries = work_entries.items,
            .work_days = try workDays(db, arena),
            .lunch = try Lunch.load(db, arena),
            .goal_secs = try weeklyGoal(db, arena),
        };
    }

    /// The day `ts` shows on; anything from before the week, its first.
    pub fn dayOf(w: Week, ts: i64) ?usize {
        const t = @max(ts, w.days[0]);
        for (0..7) |i| if (t < w.days[i + 1]) return i;
        return null;
    }

    pub fn shiftsOn(w: Week, arena: Allocator, day: usize) Allocator.Error![]SheetShift {
        var out: std.ArrayList(SheetShift) = .empty;
        for (w.shifts) |s| if (w.dayOf(s.shift.in_ts) == day) try out.append(arena, s);
        return out.items;
    }

    pub fn entriesOn(w: Week, arena: Allocator, day: usize) Allocator.Error![]store.Entry {
        var out: std.ArrayList(store.Entry) = .empty;
        for (w.entries) |e| if (w.dayOf(e.in_ts) == day) try out.append(arena, e);
        return out.items;
    }

    /// A day's entries and its shifts' breaks, in the order they started.
    pub fn rows(w: Week, arena: Allocator, day: usize) Allocator.Error![]Row {
        var out: std.ArrayList(Row) = .empty;
        for (try w.entriesOn(arena, day)) |e| try out.append(arena, .{ .entry = e });
        for (try w.shiftsOn(arena, day)) |s| for (s.breaks) |b| try out.append(arena, .{ .brk = .{ .brk = b, .shift = s } });
        std.mem.sort(Row, out.items, {}, struct {
            fn lessThan(_: void, a: Row, b: Row) bool {
                return a.start() < b.start();
            }
        }.lessThan);
        return out.items;
    }

    pub fn hasTime(w: Week, day: usize) bool {
        for (w.entries) |e| if (w.dayOf(e.in_ts) == day) return true;
        for (w.shifts) |s| if (w.dayOf(s.shift.in_ts) == day) return true;
        return false;
    }

    pub fn isWorkDay(w: Week, day: usize) bool {
        return w.work_days & (@as(u7, 1) << (isoWeekday(w.days[day] + s_per_day / 2) - 1)) != 0;
    }

    /// Days you work, and any other with time on it.
    pub fn isVisible(w: Week, day: usize) bool {
        return w.isWorkDay(day) or w.hasTime(day);
    }

    pub fn shift(w: Week, id: Uuid) ?SheetShift {
        for (w.shifts) |s| if (s.shift.id.eql(id)) return s;
        return null;
    }

    pub fn entry(w: Week, id: Uuid) ?store.Entry {
        for (w.entries) |e| if (e.id.eql(id)) return e;
        return null;
    }

    /// A break and the shift it's on.
    pub fn brk(w: Week, id: Uuid) ?struct { brk: store.Break, shift: SheetShift } {
        for (w.shifts) |s| for (s.breaks) |b| if (b.id.eql(id)) return .{ .brk = b, .shift = s };
        return null;
    }

    /// The day an item shows on.
    pub fn dayOfItem(w: Week, it: Item) ?usize {
        return switch (it) {
            .day => |d| d,
            .shift => |id| w.dayOf((w.shift(id) orelse return null).shift.in_ts),
            .entry => |id| w.dayOf((w.entry(id) orelse return null).in_ts),
            .brk => |id| w.dayOf((w.brk(id) orelse return null).brk.in_ts),
        };
    }

    /// Seconds of `e` inside the week, a running one counted up to `now`.
    pub fn seconds(w: Week, e: store.Entry, now: i64) i64 {
        const end = @min(e.out_ts orelse now, now, w.days[7]);
        return @max(0, end - @max(e.in_ts, w.days[0]));
    }

    /// Work time tracked on `day`, or the whole week with null. Personal
    /// time isn't work (see `personal`).
    pub fn tracked(w: Week, day: ?usize, now: i64) i64 {
        return w.trackedWhere(day, now, false);
    }

    /// Personal time on `day`, or the whole week with null: time on
    /// organizations with no shift.
    pub fn personal(w: Week, day: ?usize, now: i64) i64 {
        return w.trackedWhere(day, now, true);
    }

    fn trackedWhere(w: Week, day: ?usize, now: i64, personal_time: bool) i64 {
        var sum: i64 = 0;
        for (w.entries) |e| {
            if (day) |d| if (w.dayOf(e.in_ts) != d) continue;
            if (w.names.isPersonal(e.project_id) != personal_time) continue;
            sum += w.seconds(e, now);
        }
        return sum;
    }

    /// Whether `e` is personal time, not work.
    pub fn isPersonal(w: Week, e: store.Entry) bool {
        return w.names.isPersonal(e.project_id);
    }

    pub const Summary = struct {
        worked: i64 = 0,
        over: i64 = 0,
        on_break: i64 = 0,
        /// Worked time no work entry covers.
        untracked: i64 = 0,
        /// Work time tracked.
        tracked: i64 = 0,
        /// Time on organizations with no shift; never worked time.
        personal: i64 = 0,
    };

    /// Totals for `day`'s shifts, or the whole week's with null.
    pub fn summary(w: Week, arena: Allocator, day: ?usize, now: i64) Allocator.Error!Summary {
        var s: Summary = .{ .tracked = w.tracked(day, now), .personal = w.personal(day, now) };
        const cuts = try arena.alloc(Span, w.work_entries.len);
        for (w.work_entries, cuts) |e, *c| c.* = .{ .start = e.in_ts, .end = e.out_ts orelse now };
        for (w.shifts) |sh| {
            if (day) |d| if (w.dayOf(sh.shift.in_ts) != d) continue;
            const spans = try work(arena, sh.shift, sh.breaks, now);
            const done = total(spans);
            s.worked += done;
            const o = done - sh.shift.target_secs;
            if (o >= 60) s.over += o;
            s.on_break += @max(0, @max(sh.shift.out_ts orelse now, sh.shift.in_ts) - sh.shift.in_ts - done);
            s.untracked += total(try subtract(arena, spans, cuts));
        }
        return s;
    }

    /// Time per project and client this week.
    pub fn totals(w: Week, arena: Allocator, now: i64) Allocator.Error!report.Totals {
        return report.totals(arena, w.names, w.entries, w.days[0], @min(now, w.days[7]));
    }

    /// Lunch on `s`, if the window is on and the shift needs one.
    pub fn lunchOf(w: Week, arena: Allocator, s: SheetShift, now: i64) Allocator.Error!?Plan {
        const l = w.lunch orelse return null;
        return l.planFor(arena, s.shift, s.breaks, now);
    }

    /// How the week stands against the weekly goal; null without one. For
    /// the week that holds `now`, also where today's open shift leaves it.
    pub fn goal(w: Week, arena: Allocator, now: i64) Allocator.Error!?Goal {
        const secs = w.goal_secs orelse return null;
        var g: Goal = .{ .secs = secs, .worked = (try w.summary(arena, null, now)).worked };
        if (now < w.days[0] or now >= w.days[7]) return g;
        for (w.shifts) |s| {
            if (s.shift.out_ts != null) continue;
            const done = try worked(arena, s.shift, s.breaks, now);
            g.at_clock_out = g.worked + @max(0, s.shift.target_secs - done);
            if (g.left() > 0) {
                // The same shift, as long as it takes to reach the goal.
                var longer = s.shift;
                longer.target_secs = done + g.left();
                g.meets_at = try clockOut(arena, longer, s.breaks, w.lunch, now);
            }
            break;
        }
        return g;
    }

    /// When `s` is due to end: an ended shift's clock out; the open one's
    /// expected, lunch to come included.
    pub fn expectedEnd(w: Week, arena: Allocator, s: SheetShift, now: i64) Allocator.Error!i64 {
        if (s.shift.out_ts) |out| return out;
        return clockOut(arena, s.shift, s.breaks, w.lunch, now);
    }

    // ── Where new rows go ─────────────────────────────────────────────────

    /// An hour on `day` for time added after the fact: after its last
    /// entry, ending now (to the quarter hour) today, else 9 to 10.
    pub fn entrySlot(w: Week, arena: Allocator, day: usize, now: i64, utc_offset_secs: i64) Allocator.Error!Span {
        const on = try w.entriesOn(arena, day);
        if (on.len > 0) {
            const s = on[on.len - 1].out_ts orelse now;
            return .{ .start = s, .end = s + std.time.s_per_hour };
        }
        if (w.dayOf(now) == day and now < w.days[7]) {
            const end = roundedToQuarter(now, utc_offset_secs, null);
            return .{ .start = end - std.time.s_per_hour, .end = end };
        }
        const s = w.days[day] + 9 * std.time.s_per_hour;
        return .{ .start = s, .end = s + std.time.s_per_hour };
    }

    /// A shift on `day` you forgot to clock in for: around the day's tracked
    /// time, or 9 to 5. Never in the future; null for a day still to come.
    pub fn shiftSlot(w: Week, arena: Allocator, day: usize, now: i64, utc_offset_secs: i64) Allocator.Error!?Span {
        const on = try w.entriesOn(arena, day);
        var start = if (on.len > 0)
            roundedToQuarter(on[0].in_ts, utc_offset_secs, false)
        else
            w.days[day] + 9 * std.time.s_per_hour;
        var end = start + 8 * std.time.s_per_hour;
        if (on.len > 0) {
            var last: i64 = 0;
            for (on) |e| last = @max(last, e.out_ts orelse now);
            end = roundedToQuarter(last, utc_offset_secs, true);
        }
        end = @min(end, now);
        if (end <= start) {
            if (w.dayOf(now) != day) return null;
            start = now - std.time.s_per_hour;
            end = now;
        }
        return .{ .start = start, .end = end };
    }

    /// A half-hour break on `s`: at the lunch window if lunch is still to
    /// come, else halfway through the shift.
    pub fn breakSlot(w: Week, arena: Allocator, s: SheetShift, now: i64) Allocator.Error!Span {
        const off = s.shift.utc_offset_secs;
        var start: i64 = undefined;
        const p = try w.lunchOf(arena, s, now);
        if (p != null and p.?.lunch == null) {
            start = roundedToQuarter(p.?.opens, off, true);
        } else {
            const end = s.shift.out_ts orelse @max(now, s.shift.in_ts);
            start = roundedToQuarter(s.shift.in_ts + @divFloor(end - s.shift.in_ts, 2), off, null);
        }
        return .{ .start = start, .end = start + 30 * 60 };
    }
};

/// The `work_days` setting: "1,2,3,4,5" for Monday to Friday; unset is
/// every day.
pub fn workDays(db: *Store, arena: Allocator) store.Error!u7 {
    const text = try db.setting(arena, "work_days") orelse return store.BreakPreset.all_days;
    return parseWorkDays(text) orelse store.BreakPreset.all_days;
}

pub fn parseWorkDays(text: []const u8) ?u7 {
    var days: u7 = 0;
    var any = false;
    var it = std.mem.tokenizeScalar(u8, text, ',');
    while (it.next()) |part| {
        any = true;
        const d = std.fmt.parseInt(u3, std.mem.trim(u8, part, " "), 10) catch continue;
        if (d >= 1 and d <= 7) days |= @as(u7, 1) << (d - 1);
    }
    if (days == 0 and any) return null;
    return days;
}

/// The ISO weekday (1 Monday … 7 Sunday) of local time `local_ts`.
pub fn isoWeekday(local_ts: i64) u3 {
    // 1 January 1970 was a Thursday, ISO weekday 4.
    return @intCast(@mod(@divFloor(local_ts, s_per_day) + 3, 7) + 1);
}

// ── Weekly goal ─────────────────────────────────────────────────────────────

/// The setting for hours to work each week, in seconds. Unset is no goal.
pub const goal_setting = "weekly_goal_secs";
/// A week has no more hours than this.
pub const max_goal_secs = 7 * s_per_day;

/// How a week stands against the weekly goal.
pub const Goal = struct {
    secs: i64,
    /// Worked this week so far.
    worked: i64,
    /// What the week comes to once the open shift reaches its clock out;
    /// null off shift, or for another week.
    at_clock_out: ?i64 = null,
    /// When the open shift brings the week to the goal, breaks and lunch to
    /// come counted; null off shift, for another week, or once it's met.
    meets_at: ?i64 = null,

    pub fn left(g: Goal) i64 {
        return @max(0, g.secs - g.worked);
    }

    pub fn over(g: Goal) i64 {
        return @max(0, g.worked - g.secs);
    }

    pub fn isMet(g: Goal) bool {
        return g.worked >= g.secs;
    }

    /// Still to work after today's clock out, 0 if the shift gets you
    /// there; null off shift.
    pub fn leftAfterClockOut(g: Goal) ?i64 {
        const at = g.at_clock_out orelse return null;
        return @max(0, g.secs - at);
    }
};

/// The weekly goal, or null for none.
pub fn weeklyGoal(db: *Store, arena: Allocator) store.Error!?i64 {
    const text = try db.setting(arena, goal_setting) orelse return null;
    return parseGoal(text);
}

/// Seconds, up to a week's worth; null unless it's a positive number.
pub fn parseGoal(text: []const u8) ?i64 {
    const secs = std.fmt.parseInt(i64, std.mem.trim(u8, text, " "), 10) catch return null;
    if (secs <= 0) return null;
    return @min(secs, max_goal_secs);
}

/// The `week_start` setting, as an ISO weekday: the day the timesheet's
/// week starts on. Sunday unless set.
pub fn weekStartDay(db: *Store, arena: Allocator) store.Error!u3 {
    const text = try db.setting(arena, "week_start") orelse return 7;
    const d = std.fmt.parseInt(u3, std.mem.trim(u8, text, " "), 10) catch return 7;
    return if (d >= 1 and d <= 7) d else 7;
}

/// Local midnight starting the week that holds `ts`, for weeks that start
/// on ISO weekday `first`.
pub fn weekStart(ts: i64, utc_offset_secs: i64, first: u3) i64 {
    const today = fmt.dayStart(ts, utc_offset_secs);
    const back: i64 = @mod(@as(i64, isoWeekday(ts + utc_offset_secs)) - first, 7);
    return today - back * s_per_day;
}

/// Each day's local midnight from `start`, then the one after, by
/// `offsetAt` (the UTC offset at a time), so a week across a DST change
/// still splits at midnight.
pub fn weekDays(start: i64, offsetAt: *const fn (i64) i64) [8]i64 {
    var days: [8]i64 = undefined;
    for (&days, 0..) |*d, i| {
        const noon = start + @as(i64, @intCast(i)) * s_per_day + s_per_day / 2;
        d.* = fmt.dayStart(noon, offsetAt(noon));
    }
    return days;
}

// ── Times of day ────────────────────────────────────────────────────────────

/// `t` on the local day of `ref`.
pub fn onDay(ref: i64, utc_offset_secs: i64, t: Time) i64 {
    return fmt.dayStart(ref, utc_offset_secs) + t.toTs();
}

/// `t` after `start`: on its day, or the next if that's not after it, like a
/// shift past midnight.
pub fn endAfter(start: i64, utc_offset_secs: i64, t: Time) i64 {
    const end = onDay(start, utc_offset_secs, t);
    return if (end > start) end else end + s_per_day;
}

/// `t` at its first time at or after `clock_in` (to the minute), as a break
/// on that shift.
pub fn anchorAfter(clock_in: i64, utc_offset_secs: i64, t: Time) i64 {
    const at = onDay(clock_in, utc_offset_secs, t);
    const floor = clock_in - @mod(clock_in + utc_offset_secs, 60);
    return if (at < floor) at + s_per_day else at;
}

/// To the nearest quarter hour, or with `up` the one after (`true`) or
/// before (`false`).
pub fn roundedToQuarter(ts: i64, utc_offset_secs: i64, up: ?bool) i64 {
    const day = fmt.dayStart(ts, utc_offset_secs);
    const secs = ts - day;
    const exact = @divFloor(secs, 60);
    const bump: i64 = if (up) |u| (if (u) (if (@mod(secs, 60) > 0) 15 else 14) else 0) else 7;
    return day + @divFloor(exact + bump, 15) * 15 * 60;
}

pub fn validEntry(start: i64, end: i64) bool {
    return end > start and end - start <= max_entry_secs;
}

pub fn validBreak(start: i64, end: i64) bool {
    return end > start and end - start <= max_break_secs;
}

const testing = std.testing;
const h = std.time.s_per_hour;

/// 2026-11-10, a Tuesday, at local midnight in UTC-6.
const tue: i64 = 1794268800 + 6 * h;

fn fixedOffset(_: i64) i64 {
    return -6 * h;
}

fn brkAt(in_ts: i64, out_ts: ?i64) store.Break {
    return .{ .id = .v7At(@intCast(in_ts), @splat(0)), .shift_id = .v7At(0, @splat(0)), .in_ts = in_ts, .out_ts = out_ts };
}

const lunch_rule: Lunch = .{
    .preset_id = .v7At(1, @splat(0)),
    .earliest_secs = 3 * h,
    .latest_secs = 5 * h,
    .minimum_secs = 30 * 60,
    .clock_link = true,
};

test "isoWeekday and weekStart" {
    try testing.expectEqual(2, isoWeekday(tue - 6 * h));
    // Sunday weeks: back to Sunday the 8th.
    try testing.expectEqual(tue - 2 * s_per_day, weekStart(tue + 10 * h, -6 * h, 7));
    // Monday weeks: Monday the 9th.
    try testing.expectEqual(tue - s_per_day, weekStart(tue + 10 * h, -6 * h, 1));
    try testing.expectEqual(tue, weekStart(tue, -6 * h, 2));
    const days = weekDays(tue, fixedOffset);
    try testing.expectEqual(tue + 7 * s_per_day, days[7]);
}

test "parseWorkDays" {
    try testing.expectEqual(@as(?u7, 0b0011111), parseWorkDays("1,2,3,4,5"));
    try testing.expectEqual(@as(?u7, 0), parseWorkDays(""));
    try testing.expectEqual(@as(?u7, null), parseWorkDays("9,x"));
}

test "subtract" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try subtract(arena.allocator(), &.{.{ .start = 0, .end = 100 }}, &.{ .{ .start = 10, .end = 20 }, .{ .start = 90, .end = 200 } });
    try testing.expectEqualSlices(Span, &.{ .{ .start = 0, .end = 10 }, .{ .start = 20, .end = 90 } }, out);
    try testing.expectEqual(80, total(out));
}

test "lunch - plan, status, and time ahead" {
    const in = tue + 9 * h;
    // No breaks yet: the window is 12 to 2, and clock out counts 30m.
    const p = lunch_rule.plan(in, 8 * h, &.{}, in + h).?;
    try testing.expectEqual(in + 3 * h, p.opens);
    try testing.expectEqual(in + 5 * h, p.closes);
    try testing.expectEqual(Plan.Status.upcoming, p.status(in + h));
    try testing.expectEqual(Plan.Status.open, p.status(in + 4 * h));
    try testing.expectEqual(Plan.Status.missed, p.status(in + 6 * h));
    try testing.expectEqual(30 * 60, lunch_rule.ahead(p, in + h));

    // A short break first pushes the window later.
    const rest = brkAt(in + h, in + h + 10 * 60);
    const p2 = lunch_rule.plan(in, 8 * h, &.{rest}, in + 2 * h).?;
    try testing.expectEqual(in + 3 * h + 10 * 60, p2.opens);
    try testing.expectEqual(null, p2.lunch);

    // On lunch 10 minutes: 20 left to count.
    const on = brkAt(in + 4 * h, null);
    const p3 = lunch_rule.plan(in, 8 * h, &.{ rest, on }, in + 4 * h + 10 * 60).?;
    try testing.expectEqual(Plan.Status.on_lunch, p3.status(in + 4 * h + 10 * 60));
    try testing.expectEqual(20 * 60, lunch_rule.ahead(p3, in + 4 * h + 10 * 60));
    try testing.expect(p3.isLunch(in + 4 * h));

    // Done: nothing ahead; late if it started after the window closed.
    const late = brkAt(in + 6 * h, in + 6 * h + 30 * 60);
    const p4 = lunch_rule.plan(in, 8 * h, &.{late}, in + 7 * h).?;
    try testing.expectEqual(Plan.Status.late, p4.status(in + 7 * h));
    try testing.expectEqual(0, lunch_rule.ahead(p4, in + 7 * h));

    // A shift too short to need lunch.
    try testing.expectEqual(null, lunch_rule.plan(in, 4 * h, &.{}, in));
}

test "clockOut counts lunch to come" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const in = tue + 9 * h;
    const shift: store.Shift = .{ .id = .v7At(0, @splat(0)), .in_ts = in, .utc_offset_secs = -6 * h, .tz = null, .target_secs = 8 * h, .out_ts = null };
    try testing.expectEqual(in + 8 * h, try clockOut(a, shift, &.{}, null, in));
    try testing.expectEqual(in + 8 * h + 30 * 60, try clockOut(a, shift, &.{}, lunch_rule, in));
    // A 45m lunch taken: counted as itself.
    const taken = brkAt(in + 4 * h, in + 4 * h + 45 * 60);
    try testing.expectEqual(in + 8 * h + 45 * 60, try clockOut(a, shift, &.{taken}, lunch_rule, in + 5 * h));
    // Ten minutes into lunch: clock out holds at 30 minutes of it.
    const on = brkAt(in + 4 * h, null);
    try testing.expectEqual(in + 8 * h + 30 * 60, try clockOut(a, shift, &.{on}, lunch_rule, in + 4 * h + 10 * 60));
}

test "worked and over" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const in = tue + 9 * h;
    const shift: store.Shift = .{ .id = .v7At(0, @splat(0)), .in_ts = in, .utc_offset_secs = -6 * h, .tz = null, .target_secs = 8 * h, .out_ts = in + 9 * h };
    const b = brkAt(in + 4 * h, in + 4 * h + 30 * 60);
    try testing.expectEqual(8 * h + 30 * 60, try worked(a, shift, &.{b}, in + 10 * h));
    try testing.expectEqual(30 * 60, try over(a, shift, &.{b}, in + 10 * h));
}

test "times of day" {
    const off = -6 * h;
    const nine: Time = .{ .hour = 9, .min = 0 };
    const one_am: Time = .{ .hour = 1, .min = 0 };
    try testing.expectEqual(tue + 9 * h, onDay(tue + 15 * h, off, nine));
    try testing.expectEqual(tue + s_per_day + h, endAfter(tue + 22 * h, off, one_am));
    try testing.expectEqual(tue + s_per_day + 9 * h, anchorAfter(tue + 10 * h, off, nine));
    try testing.expectEqual(tue + 9 * h, anchorAfter(tue + 9 * h + 30, off, nine));
    try testing.expectEqual(tue + 9 * h + 15 * 60, roundedToQuarter(tue + 9 * h + 8 * 60, off, null));
    try testing.expectEqual(tue + 9 * h, roundedToQuarter(tue + 9 * h + 8 * 60, off, false));
    try testing.expectEqual(tue + 9 * h + 15 * 60, roundedToQuarter(tue + 9 * h + 1, off, true));
    try testing.expectEqual(tue + 9 * h, roundedToQuarter(tue + 9 * h, off, true));
}

test "Week - days, rows, summary, slots" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var db: Store = try .open(testing.io, ":memory:");
    defer db.deinit();

    const off = -6 * h;
    const days = weekDays(tue - 2 * s_per_day, fixedOffset);
    const in = tue + 9 * h;
    const stamp: core.local.Stamp = .{ .ts = in, .utc_offset_secs = off, .tz = null };
    const shift_id = try db.addShift(stamp, in + 8 * h + 30 * 60);
    try db.editShift(shift_id, .{ .target_secs = 8 * h }, in);
    _ = try db.addBreak(shift_id, in + 4 * h, in + 4 * h + 30 * 60, in);
    const web = try db.createProject(.{ .name = "web" }, in);
    _ = try db.addEntry(.{ .project_id = web, .source = .cli }, stamp, in + 2 * h);
    _ = try db.addEntry(.{ .source = .cli }, .{ .ts = in + 5 * h, .utc_offset_secs = off, .tz = null }, in + 6 * h);
    try db.setSetting("work_days", "1,2,3,4,5", in);

    const now = in + 10 * h;
    const w: Week = try .load(&db, a, days);
    try testing.expectEqual(1, w.shifts.len);
    try testing.expectEqual(2, w.dayOf(in));
    try testing.expect(!w.isVisible(0)); // Sunday, nothing on it
    try testing.expect(w.isVisible(1)); // Monday, a work day
    try testing.expect(w.hasTime(2));

    const rows = try w.rows(a, 2);
    try testing.expectEqual(3, rows.len);
    try testing.expect(rows[0] == .entry);
    try testing.expect(rows[1] == .brk);
    try testing.expect(rows[2] == .entry);

    const s = try w.summary(a, null, now);
    try testing.expectEqual(8 * h, s.worked);
    try testing.expectEqual(0, s.over);
    try testing.expectEqual(30 * 60, s.on_break);
    try testing.expectEqual(3 * h, s.tracked);
    try testing.expectEqual(5 * h, s.untracked);

    // After the day's last entry; a forgotten shift around the day's time.
    const slot = try w.entrySlot(a, 2, now, off);
    try testing.expectEqual(in + 6 * h, slot.start);
    const ss = (try w.shiftSlot(a, 1, now, off)).?;
    try testing.expectEqual(days[1] + 9 * h, ss.start);
    try testing.expectEqual(null, try w.shiftSlot(a, 5, now, off));
    // Halfway through the shift, to the quarter hour.
    const bs = try w.breakSlot(a, w.shifts[0], now);
    try testing.expectEqual(in + 4 * h + 15 * 60, bs.start);
}

test "parseGoal" {
    try testing.expectEqual(@as(?i64, 20 * h), parseGoal("72000"));
    try testing.expectEqual(@as(?i64, null), parseGoal("0"));
    try testing.expectEqual(@as(?i64, null), parseGoal("-5"));
    try testing.expectEqual(@as(?i64, null), parseGoal("20h"));
    try testing.expectEqual(@as(?i64, max_goal_secs), parseGoal("999999999"));
}

test "Week - weekly goal" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var db: Store = try .open(testing.io, ":memory:");
    defer db.deinit();

    const off = -6 * h;
    const days = weekDays(tue - 2 * s_per_day, fixedOffset);
    // Monday: 5 hours done.
    const mon = tue - s_per_day + 9 * h;
    const done = try db.addShift(.{ .ts = mon, .utc_offset_secs = off, .tz = null }, mon + 5 * h);
    try db.editShift(done, .{ .target_secs = 5 * h }, mon);

    // No goal set: nothing to show.
    const none: Week = try .load(&db, a, days);
    try testing.expectEqual(null, try none.goal(a, tue));

    try db.setSetting(goal_setting, "72000", mon); // 20h

    // Tuesday: on a 4h shift since 9, two hours in, a break at 12 to come.
    const in = tue + 9 * h;
    const now = in + 2 * h;
    const id = try db.startShift(4 * h, .{ .ts = in, .utc_offset_secs = off, .tz = null });
    _ = try db.addBreak(id, in + 3 * h, in + 3 * h + 30 * 60, in);
    const w: Week = try .load(&db, a, days);
    const g = (try w.goal(a, now)).?;
    try testing.expectEqual(20 * h, g.secs);
    try testing.expectEqual(7 * h, g.worked);
    try testing.expectEqual(13 * h, g.left());
    try testing.expectEqual(0, g.over());
    // Clock out brings the week to 9h, 11h short.
    try testing.expectEqual(9 * h, g.at_clock_out.?);
    try testing.expectEqual(11 * h, g.leftAfterClockOut().?);
    // 13 more hours, past the half-hour break.
    try testing.expectEqual(now + 13 * h + 30 * 60, g.meets_at.?);

    // Next week: no forecast for a week that isn't now.
    const later = (try w.goal(a, days[7] + h)).?;
    try testing.expectEqual(null, later.at_clock_out);
    try testing.expectEqual(null, later.meets_at);

    // A goal the week has passed.
    try db.setSetting(goal_setting, "21600", mon); // 6h
    const met = (try (try Week.load(&db, a, days)).goal(a, now)).?;
    try testing.expect(met.isMet());
    try testing.expectEqual(h, met.over());
    try testing.expectEqual(null, met.meets_at);
    try testing.expectEqual(0, met.leftAfterClockOut().?);
}

test "Week - personal time apart, and one organization at a time" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var db: Store = try .open(testing.io, ":memory:");
    defer db.deinit();

    const off = -6 * h;
    const days = weekDays(tue - 2 * s_per_day, fixedOffset);
    const in = tue + 9 * h;
    const stamp = struct {
        fn f(ts: i64) core.local.Stamp {
            return .{ .ts = ts, .utc_offset_secs = -6 * h, .tz = null };
        }
    }.f;
    _ = off;
    const orgs = try db.organizations(a);
    const work_org = orgs[0].id;
    const personal_org = orgs[1].id;
    const acme = try db.createOrganization(.{ .name = "Acme" }, in);

    // A 9 to 5 shift: two hours on web, one on Acme's api, and half an hour
    // of a side project on the clock; an evening of the side project.
    _ = try db.addShift(stamp(in), in + 8 * h);
    const web = try db.createProject(.{ .name = "web" }, in);
    const api = try db.createProject(.{ .name = "api", .organization_id = acme }, in);
    const side = try db.createProject(.{ .name = "side", .organization_id = personal_org }, in);
    _ = try db.addEntry(.{ .project_id = web, .source = .cli }, stamp(in), in + 2 * h);
    _ = try db.addEntry(.{ .project_id = api, .source = .cli }, stamp(in + 2 * h), in + 3 * h);
    _ = try db.addEntry(.{ .project_id = side, .source = .cli }, stamp(in + 3 * h), in + 3 * h + 30 * 60);
    _ = try db.addEntry(.{ .project_id = side, .source = .cli }, stamp(in + 11 * h), in + 13 * h);

    const now = in + 14 * h;
    const all: Week = try .load(&db, a, days);
    const s = try all.summary(a, null, now);
    try testing.expectEqual(8 * h, s.worked);
    try testing.expectEqual(3 * h, s.tracked);
    try testing.expectEqual(2 * h + 30 * 60, s.personal);
    // Personal time on the clock isn't work tracked.
    try testing.expectEqual(5 * h, s.untracked);
    const t = try all.totals(a, now);
    try testing.expectEqual(3 * h, t.total);
    try testing.expectEqual(2 * h + 30 * 60, t.personal);

    // One shift organization: its entries, and the shared shift.
    const mine: Week = try .loadFor(&db, a, days, work_org);
    try testing.expectEqual(1, mine.shifts.len);
    try testing.expectEqual(1, mine.entries.len);
    const ms = try mine.summary(a, null, now);
    try testing.expectEqual(2 * h, ms.tracked);
    try testing.expectEqual(5 * h, ms.untracked);
    try testing.expectEqual(1, (try Week.loadFor(&db, a, days, acme)).entries.len);

    // Personal: no shift, its time alone.
    const own: Week = try .loadFor(&db, a, days, personal_org);
    try testing.expectEqual(0, own.shifts.len);
    try testing.expectEqual(2, own.entries.len);
    const os = try own.summary(a, null, now);
    try testing.expectEqual(0, os.worked);
    try testing.expectEqual(0, os.tracked);
    try testing.expectEqual(2 * h + 30 * 60, os.personal);
}
