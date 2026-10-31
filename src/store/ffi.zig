//! The store's C API, for the macOS app (see shifty.h). Calls return a
//! `ShiftyResult`; reads fill caller-owned structs. Not thread-safe: use a
//! handle from one thread at a time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const core = @import("core");
const Uuid = core.Uuid;
const local = core.local;
const store = @import("root.zig");
const Store = store.Store;

pub const Result = enum(c_int) {
    ok = 0,
    /// A read found nothing (no open shift, no such setting).
    none = 1,
    busy = -1,
    conflict = -2,
    not_found = -3,
    mismatch = -4,
    corrupt = -5,
    too_new = -6,
    no_memory = -7,
    io = -8,
};

fn result(err: anyerror) Result {
    return switch (err) {
        error.Busy => .busy,
        error.Conflict => .conflict,
        error.NotFound => .not_found,
        error.Mismatch => .mismatch,
        error.Corrupt => .corrupt,
        error.SchemaTooNew => .too_new,
        error.OutOfMemory => .no_memory,
        else => .io,
    };
}

pub const Id = extern struct { bytes: [16]u8 };

pub const Shift = extern struct {
    id: Id,
    in_ts: i64,
    target_secs: i64,
};

pub const Break = extern struct {
    id: Id,
    in_ts: i64,
    out_ts: i64,
    /// Nonzero for the break in progress; `out_ts` is then meaningless.
    running: i32,
};

pub const AlarmKind = enum(i32) { before_clock_out = 0, at_time = 1, _ };

pub const AlarmRule = extern struct {
    id: Id,
    kind: AlarmKind,
    enabled: i32,
    /// Minutes before clock out, or seconds since local midnight.
    value: i64,
};

const gpa = std.heap.c_allocator;

const Handle = struct {
    threaded: Io.Threaded,
    store: Store,
};

fn id(i: Id) Uuid {
    return .{ .bytes = i.bytes };
}

/// Opens the store at `path`, or the shared default (`$SHIFTY_DB`, else
/// `~/Library/Application Support/Shifty/shifty.db`) when `path` is null.
export fn shifty_store_open(path: ?[*:0]const u8, out: *?*Handle) Result {
    out.* = null;
    const h = gpa.create(Handle) catch return .no_memory;
    h.threaded = .init_single_threaded;
    const io = h.threaded.io();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const p: [:0]const u8 = if (path) |p| std.mem.span(p) else defaultPath(arena.allocator()) catch |e| {
        gpa.destroy(h);
        return result(e);
    };
    h.store = Store.open(io, p) catch |e| {
        gpa.destroy(h);
        return result(e);
    };
    out.* = h;
    return .ok;
}

fn defaultPath(arena: Allocator) ![:0]u8 {
    var env: std.process.Environ.Map = .init(arena);
    for ([_][:0]const u8{ "HOME", "SHIFTY_DB", "XDG_DATA_HOME" }) |key| {
        if (std.c.getenv(key)) |v| try env.put(key, std.mem.span(v));
    }
    return store.defaultPath(arena, &env);
}

export fn shifty_store_close(h: ?*Handle) void {
    const handle = h orelse return;
    handle.store.deinit();
    gpa.destroy(handle);
}

/// Changes when another process writes; see `Store.dataVersion`.
export fn shifty_data_version(h: *Handle, out: *i64) Result {
    out.* = h.store.dataVersion() catch |e| return result(e);
    return .ok;
}

// ── Shifts ──────────────────────────────────────────────────────────────────

/// The open shift, or `none`.
export fn shifty_current_shift(h: *Handle, out: *Shift) Result {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const s = (h.store.currentShift(arena.allocator()) catch |e| return result(e)) orelse return .none;
    out.* = .{ .id = .{ .bytes = s.id.bytes }, .in_ts = s.in_ts, .target_secs = s.target_secs };
    return .ok;
}

/// Clocks in at `in_ts`, recorded in the local zone. `conflict` if a shift
/// is already open.
export fn shifty_start_shift(h: *Handle, in_ts: i64, target_secs: i64, out: *Id) Result {
    var tz_buf: local.TzBuf = undefined;
    const tz = local.tzName(h.threaded.io(), if (std.c.getenv("TZ")) |v| std.mem.span(v) else null, &tz_buf);
    const new = h.store.startShift(target_secs, .{ .ts = in_ts, .utc_offset_secs = local.utcOffset(in_ts), .tz = tz }) catch |e| return result(e);
    out.* = .{ .bytes = new.bytes };
    return .ok;
}

export fn shifty_edit_shift(h: *Handle, shift_id: Id, in_ts: i64, target_secs: i64, now: i64) Result {
    h.store.editShift(id(shift_id), .{ .in_ts = in_ts, .target_secs = target_secs }, now) catch |e| return result(e);
    return .ok;
}

/// Clocks out at `now`; `none` if no shift was open.
export fn shifty_end_shift(h: *Handle, now: i64) Result {
    const ended = h.store.endShift(now) catch |e| return result(e);
    return if (ended == null) .none else .ok;
}

/// `ok` if a forgotten shift was closed, `none` if there was nothing to do.
export fn shifty_close_stale_shift(h: *Handle, now: i64) Result {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const closed = h.store.closeStaleShift(arena.allocator(), now) catch |e| return result(e);
    return if (closed) .ok else .none;
}

// ── Breaks ──────────────────────────────────────────────────────────────────

/// Fills up to `cap` of a shift's breaks into `out`, oldest first, and sets
/// `count` to how many there are, which may be more than `cap`.
export fn shifty_breaks(h: *Handle, shift_id: Id, out: [*]Break, cap: usize, count: *usize) Result {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const brks = h.store.breaks(arena.allocator(), id(shift_id)) catch |e| return result(e);
    count.* = brks.len;
    for (brks[0..@min(brks.len, cap)], out) |b, *o| o.* = .{
        .id = .{ .bytes = b.id.bytes },
        .in_ts = b.in_ts,
        .out_ts = b.out_ts orelse 0,
        .running = @intFromBool(b.out_ts == null),
    };
    return .ok;
}

/// Creates or replaces a break; `running` nonzero leaves it open.
export fn shifty_put_break(h: *Handle, break_id: Id, shift_id: Id, in_ts: i64, out_ts: i64, running: i32, now: i64) Result {
    h.store.putBreak(id(break_id), id(shift_id), in_ts, if (running != 0) null else out_ts, now) catch |e| return result(e);
    return .ok;
}

export fn shifty_delete_break(h: *Handle, break_id: Id, now: i64) Result {
    h.store.deleteBreak(id(break_id), now) catch |e| return result(e);
    return .ok;
}

// ── Alarms and settings ─────────────────────────────────────────────────────

/// Like `shifty_breaks`, for alarm rules.
export fn shifty_alarm_rules(h: *Handle, out: [*]AlarmRule, cap: usize, count: *usize) Result {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const rules = h.store.alarmRules(arena.allocator()) catch |e| return result(e);
    count.* = rules.len;
    for (rules[0..@min(rules.len, cap)], out) |r, *o| o.* = switch (r.trigger) {
        .before_clock_out => |m| .{ .id = .{ .bytes = r.id.bytes }, .kind = .before_clock_out, .enabled = @intFromBool(r.enabled), .value = m },
        .at_time => |t| .{ .id = .{ .bytes = r.id.bytes }, .kind = .at_time, .enabled = @intFromBool(r.enabled), .value = t },
    };
    return .ok;
}

export fn shifty_put_alarm_rule(h: *Handle, rule: AlarmRule, now: i64) Result {
    const trigger: store.AlarmRule.Trigger = switch (rule.kind) {
        .before_clock_out => .{ .before_clock_out = rule.value },
        .at_time => .{ .at_time = rule.value },
        _ => return .conflict,
    };
    h.store.putAlarmRule(.{ .id = id(rule.id), .trigger = trigger, .enabled = rule.enabled != 0 }, now) catch |e| return result(e);
    return .ok;
}

export fn shifty_delete_alarm_rule(h: *Handle, rule_id: Id, now: i64) Result {
    h.store.deleteAlarmRule(id(rule_id), now) catch |e| return result(e);
    return .ok;
}

/// Copies a setting into `buf` (not NUL-terminated) and sets `len` to its
/// full length, which may exceed `cap`. `none` if unset.
export fn shifty_setting(h: *Handle, key: [*:0]const u8, buf: [*]u8, cap: usize, len: *usize) Result {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const v = (h.store.setting(arena.allocator(), std.mem.span(key)) catch |e| return result(e)) orelse return .none;
    len.* = v.len;
    @memcpy(buf[0..@min(v.len, cap)], v[0..@min(v.len, cap)]);
    return .ok;
}

/// Sets a setting; a null `value` removes it.
export fn shifty_set_setting(h: *Handle, key: [*:0]const u8, value: ?[*:0]const u8, now: i64) Result {
    h.store.setSetting(std.mem.span(key), if (value) |v| std.mem.span(v) else null, now) catch |e| return result(e);
    return .ok;
}

const testing = std.testing;

test "C API - shift, breaks, alarms, settings" {
    var h: ?*Handle = null;
    try testing.expectEqual(Result.ok, shifty_store_open(":memory:", &h));
    defer shifty_store_close(h);
    const s = h.?;

    var shift: Shift = undefined;
    try testing.expectEqual(Result.none, shifty_current_shift(s, &shift));
    var shift_id: Id = undefined;
    try testing.expectEqual(Result.ok, shifty_start_shift(s, 1000, 8 * 3600, &shift_id));
    try testing.expectEqual(Result.conflict, shifty_start_shift(s, 1000, 8 * 3600, &shift_id));
    try testing.expectEqual(Result.ok, shifty_edit_shift(s, shift_id, 900, 7 * 3600, 1001));
    try testing.expectEqual(Result.ok, shifty_current_shift(s, &shift));
    try testing.expectEqual(900, shift.in_ts);
    try testing.expectEqual(7 * 3600, shift.target_secs);

    const b: Id = .{ .bytes = @splat(7) };
    try testing.expectEqual(Result.ok, shifty_put_break(s, b, shift_id, 2000, 0, 1, 2000));
    var brks: [1]Break = undefined;
    var n: usize = 0;
    try testing.expectEqual(Result.ok, shifty_breaks(s, shift_id, &brks, 0, &n));
    try testing.expectEqual(1, n);
    try testing.expectEqual(Result.ok, shifty_breaks(s, shift_id, &brks, 1, &n));
    try testing.expectEqual(1, brks[0].running);

    const rule: AlarmRule = .{ .id = .{ .bytes = @splat(9) }, .kind = .at_time, .enabled = 1, .value = 3600 };
    try testing.expectEqual(Result.ok, shifty_put_alarm_rule(s, rule, 0));
    var rules: [2]AlarmRule = undefined;
    try testing.expectEqual(Result.ok, shifty_alarm_rules(s, &rules, 2, &n));
    try testing.expectEqual(1, n);
    try testing.expectEqual(AlarmKind.at_time, rules[0].kind);
    try testing.expectEqual(Result.ok, shifty_delete_alarm_rule(s, rule.id, 1));
    try testing.expectEqual(Result.not_found, shifty_delete_alarm_rule(s, rule.id, 2));

    var buf: [4]u8 = undefined;
    try testing.expectEqual(Result.none, shifty_setting(s, "clock_out_link", &buf, buf.len, &n));
    try testing.expectEqual(Result.ok, shifty_set_setting(s, "clock_out_link", "https://x.y", 0));
    try testing.expectEqual(Result.ok, shifty_setting(s, "clock_out_link", &buf, buf.len, &n));
    try testing.expectEqual(11, n);
    try testing.expectEqualStrings("http", &buf);

    try testing.expectEqual(Result.ok, shifty_end_shift(s, 5000));
    try testing.expectEqual(Result.none, shifty_end_shift(s, 5001));
}
