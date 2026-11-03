const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const io = testing.io;

const core = @import("core");
const Stamp = core.local.Stamp;

const store = @import("root.zig");
const Store = store.Store;

fn at(ts: i64) Stamp {
    return .{ .ts = ts, .utc_offset_secs = -5 * 3600, .tz = "America/Chicago" };
}

/// A file-backed store in a fresh tmp dir; the WAL tests need a real file.
const TmpDb = struct {
    tmp: testing.TmpDir,
    path: [:0]u8,

    fn init() !TmpDb {
        const tmp = testing.tmpDir(.{});
        const path = try std.fmt.allocPrintSentinel(testing.allocator, ".zig-cache/tmp/{s}/data/shifty.db", .{tmp.sub_path}, 0);
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *TmpDb) void {
        testing.allocator.free(self.path);
        self.tmp.cleanup();
    }
};

test "open - creates parent dirs, migrates once, keeps replica id" {
    var tmp: TmpDb = try .init();
    defer tmp.deinit();

    var a: Store = try .open(io, tmp.path);
    const replica = try a.replicaId();
    a.deinit();

    var b: Store = try .open(io, tmp.path);
    defer b.deinit();
    try testing.expect(replica.eql(try b.replicaId()));
    var stmt = try b.db.prepare("PRAGMA user_version");
    defer stmt.deinit();
    try testing.expect(try stmt.step());
    try testing.expectEqual(3, stmt.int(0));
}

test "open - lunch alarms migration keeps existing rules" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp: TmpDb = try .init();
    defer tmp.deinit();

    // A database as the first schema left it, with a rule in it.
    std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(tmp.path).?) catch {};
    const db: store.sqlite.Db = try .open(tmp.path);
    try db.execScript(@embedFile("migrations/0001_init.sql"));
    try db.execScript("PRAGMA user_version = 1");
    try db.execScript(
        \\INSERT INTO alarm_rules (id, kind, minutes, enabled, created_ts, updated_ts)
        \\VALUES (x'0102030405060708090a0b0c0d0e0f10', 'before_clock_out', 15, 0, 1, 1)
    );
    db.close();

    var s: Store = try .open(io, tmp.path);
    defer s.deinit();
    const rules = try s.alarmRules(arena.allocator());
    try testing.expectEqual(1, rules.len);
    try testing.expectEqual(15, rules[0].trigger.before_clock_out);
    try testing.expect(!rules[0].enabled);
    _ = try s.addAlarmRule(.{ .before_break = 5 }, 2);
}

/// A database as migration 0002 left it.
fn v2Db(path: [:0]const u8) !store.sqlite.Db {
    std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?) catch {};
    const db: store.sqlite.Db = try .open(path);
    try db.execScript(@embedFile("migrations/0001_init.sql"));
    try db.execScript(@embedFile("migrations/0002_lunch_alarms.sql"));
    try db.execScript("PRAGMA user_version = 2");
    return db;
}

test "open - break presets migration moves lunch into a window preset" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp: TmpDb = try .init();
    defer tmp.deinit();

    const db = try v2Db(tmp.path);
    try db.execScript(
        \\INSERT INTO settings (key, value, updated_ts)
        \\VALUES ('lunch', '{"enabled":true,"earliest_mins":120,"latest_mins":240,"minimum_mins":45}', 7);
        \\INSERT INTO alarm_rules (id, kind, minutes, enabled, created_ts, updated_ts)
        \\VALUES (x'01010101010101010101010101010101', 'before_clock_out', 15, 1, 1, 1),
        \\       (x'02020202020202020202020202020202', 'lunch_opens', NULL, 1, 2, 2),
        \\       (x'03030303030303030303030303030303', 'before_lunch_closes', 10, 0, 3, 3);
    );
    db.close();

    var s: Store = try .open(io, tmp.path);
    defer s.deinit();
    const presets = try s.breakPresets(a);
    try testing.expectEqual(1, presets.len);
    const lunch = presets[0];
    try testing.expectEqualStrings("Lunch", lunch.name);
    try testing.expect(lunch.enabled);
    try testing.expectEqual(store.BreakPreset.all_days, lunch.weekdays);
    try testing.expectEqual(2 * h, lunch.rule.window.earliest_secs);
    try testing.expectEqual(4 * h, lunch.rule.window.latest_secs);
    try testing.expectEqual(45 * 60, lunch.rule.window.minimum_secs);
    try testing.expectEqual(null, try s.setting(a, "lunch"));

    const rules = try s.alarmRules(a);
    try testing.expectEqual(3, rules.len);
    try testing.expectEqual(15, rules[0].trigger.before_clock_out);
    try testing.expect(rules[1].trigger.window_opens.eql(lunch.id));
    try testing.expectEqual(10, rules[2].trigger.before_window_closes.minutes);
    try testing.expect(rules[2].trigger.before_window_closes.preset_id.eql(lunch.id));
    try testing.expect(!rules[2].enabled);
}

test "open - break presets migration without a lunch setting adds lunch, off" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp: TmpDb = try .init();
    defer tmp.deinit();

    const db = try v2Db(tmp.path);
    db.close();

    var s: Store = try .open(io, tmp.path);
    defer s.deinit();
    const presets = try s.breakPresets(arena.allocator());
    try testing.expectEqual(1, presets.len);
    try testing.expect(!presets[0].enabled);
    try testing.expectEqual(3 * h, presets[0].rule.window.earliest_secs);
    try testing.expectEqual(5 * h, presets[0].rule.window.latest_secs);
    try testing.expectEqual(30 * 60, presets[0].rule.window.minimum_secs);
}

test "open - refuses a database from a newer Shifty" {
    var tmp: TmpDb = try .init();
    defer tmp.deinit();

    var a: Store = try .open(io, tmp.path);
    try a.db.execScript("PRAGMA user_version = 99");
    a.deinit();

    try testing.expectError(error.SchemaTooNew, Store.open(io, tmp.path));
}

test "organization - clients, projects, workspaces" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    const acme = try s.createClient("Acme", 100);
    const web = try s.createProject(.{ .name = "web", .client_id = acme, .color = "#ff8800" }, 100);
    _ = try s.createProject(.{ .name = "Admin" }, 100);
    _ = try s.createWorkspace(web, "main", 100);
    _ = try s.createWorkspace(web, "billing", 100);

    const cs = try s.clients(arena.allocator());
    try testing.expectEqual(1, cs.len);
    try testing.expectEqualStrings("Acme", cs[0].name);

    const ps = try s.projects(arena.allocator());
    try testing.expectEqual(2, ps.len);
    try testing.expectEqualStrings("Admin", ps[0].name);
    try testing.expectEqual(null, ps[0].client_id);
    try testing.expectEqualStrings("web", ps[1].name);
    try testing.expect(ps[1].client_id.?.eql(acme));
    try testing.expectEqualStrings("#ff8800", ps[1].color.?);

    const ws = try s.workspaces(arena.allocator(), web);
    try testing.expectEqual(2, ws.len);
    try testing.expectEqualStrings("billing", ws[0].name);
}

test "organization - dangling client is rejected" {
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();
    const ghost: core.Uuid = .v7(io);
    try testing.expectError(error.Conflict, s.createProject(.{ .name = "x", .client_id = ghost }, 100));
}

test "entries - start stops the running one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    const p = try s.createProject(.{ .name = "web" }, 0);
    const first = try s.startEntry(.{ .project_id = p, .source = .tui }, at(1000));
    const second = try s.startEntry(.{ .source = .menubar, .note = "standup" }, at(1600));

    const running = (try s.runningEntry(arena.allocator())).?;
    try testing.expect(running.id.eql(second));
    try testing.expectEqual(null, running.project_id);
    try testing.expectEqual(.menubar, running.source);
    try testing.expectEqualStrings("standup", running.note.?);
    try testing.expectEqualStrings("America/Chicago", running.tz.?);
    try testing.expectEqual(-5 * 3600, running.utc_offset_secs);

    try testing.expect((try s.stopEntry(2000)).?.eql(second));
    try testing.expectEqual(null, try s.runningEntry(arena.allocator()));
    try testing.expectEqual(null, try s.stopEntry(2100));

    const day = try s.entriesBetween(arena.allocator(), 0, 10_000);
    try testing.expectEqual(2, day.len);
    try testing.expect(day[0].id.eql(first));
    try testing.expectEqual(1600, day[0].out_ts.?);
    try testing.expect(day[0].project_id.?.eql(p));
    try testing.expectEqual(2000, day[1].out_ts.?);
}

test "entries - workspace implies its project" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    const web = try s.createProject(.{ .name = "web" }, 0);
    const other = try s.createProject(.{ .name = "other" }, 0);
    const main = try s.createWorkspace(web, "main", 0);

    _ = try s.startEntry(.{ .workspace_id = main, .source = .cli }, at(100));
    const e = (try s.runningEntry(arena.allocator())).?;
    try testing.expect(e.project_id.?.eql(web));
    try testing.expect(e.workspace_id.?.eql(main));

    try testing.expectError(error.Mismatch, s.startEntry(.{ .project_id = other, .workspace_id = main, .source = .cli }, at(200)));
    // The failed start rolled back: the first entry is still running.
    try testing.expect((try s.runningEntry(arena.allocator())).?.id.eql(e.id));
}

test "entries - stopped the second it started is dropped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    _ = try s.startEntry(.{ .source = .tui }, at(500));
    try testing.expectEqual(null, try s.stopEntry(500));
    try testing.expectEqual(0, (try s.entriesBetween(arena.allocator(), 0, 1000)).len);
}

test "entries - entriesBetween is an overlap query" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    _ = try s.startEntry(.{ .source = .tui }, at(100));
    _ = try s.startEntry(.{ .source = .tui }, at(200));
    _ = try s.startEntry(.{ .source = .tui }, at(300)); // still running

    const a = arena.allocator();
    try testing.expectEqual(3, (try s.entriesBetween(a, 0, 1000)).len);
    try testing.expectEqual(2, (try s.entriesBetween(a, 150, 250)).len);
    try testing.expectEqual(1, (try s.entriesBetween(a, 250, 260)).len);
    try testing.expectEqual(1, (try s.entriesBetween(a, 5000, 6000)).len); // running
    try testing.expectEqual(0, (try s.entriesBetween(a, 0, 100)).len);
}

test "schema - only one running entry, even bypassing startEntry" {
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    _ = try s.startEntry(.{ .source = .tui }, at(100));
    const id: core.Uuid = .v7(io);
    const insert = s.db.exec(
        \\INSERT INTO entries (id, in_ts, utc_offset_secs, source, created_ts, updated_ts)
        \\VALUES (?, 200, 0, 'cli', 200, 200)
    , .{store.sqlite.Blob{ .bytes = &id.bytes }});
    try testing.expectError(error.Conflict, insert);
}

test "shared file - a second connection sees the running entry" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp: TmpDb = try .init();
    defer tmp.deinit();

    var tui: Store = try .open(io, tmp.path);
    defer tui.deinit();
    var app: Store = try .open(io, tmp.path);
    defer app.deinit();

    const id = try tui.startEntry(.{ .source = .tui }, at(100));
    try testing.expect((try app.runningEntry(arena.allocator())).?.id.eql(id));

    _ = try app.stopEntry(200);
    try testing.expectEqual(null, try tui.runningEntry(arena.allocator()));
}

test "defaultPath" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    const gpa = testing.allocator;

    try testing.expectError(error.NoHome, store.pathFor(gpa, &env, .release));

    try env.put("HOME", "/home/jeff");
    const home = try store.pathFor(gpa, &env, .release);
    defer gpa.free(home);
    const want = if (builtin.os.tag == .macos)
        "/home/jeff/Library/Application Support/Shifty/shifty.db"
    else
        "/home/jeff/.local/share/shifty/shifty.db";
    try testing.expectEqualStrings(want, home);

    // Builds that aren't releases keep off the real database.
    const dev = try store.pathFor(gpa, &env, .dev);
    defer gpa.free(dev);
    const want_dev = if (builtin.os.tag == .macos)
        "/home/jeff/Library/Application Support/Shifty Dev/shifty.db"
    else
        "/home/jeff/.local/share/shifty-dev/shifty.db";
    try testing.expectEqualStrings(want_dev, dev);

    try env.put("SHIFTY_DB", "/tmp/dev.db");
    const override = try store.pathFor(gpa, &env, .release);
    defer gpa.free(override);
    try testing.expectEqualStrings("/tmp/dev.db", override);
}

// ── Shifts and breaks ───────────────────────────────────────────────────────

const h = std.time.s_per_hour;

test "shifts - clock in, break, clock out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    const shift_id = try s.startShift(8 * h, at(0));
    try testing.expectError(error.Conflict, s.startShift(8 * h, at(10)));

    const shift = (try s.currentShift(a)).?;
    try testing.expect(shift.id.eql(shift_id));
    try testing.expectEqualStrings("America/Chicago", shift.tz.?);
    try testing.expectEqual(8 * h, store.clockOut(shift, &.{}, 0));

    // A running break pushes clock out as it goes.
    _ = try s.startBreak(4 * h);
    try testing.expectError(error.Conflict, s.startBreak(4 * h + 10));
    try testing.expectEqual(8 * h + 600, store.clockOut(shift, try s.breaks(a, shift_id), 4 * h + 600));
    _ = (try s.endBreak(5 * h)).?;
    try testing.expectEqual(9 * h, store.clockOut(shift, try s.breaks(a, shift_id), 6 * h));

    try testing.expect((try s.endShift(9 * h)).?.eql(shift_id));
    try testing.expectEqual(null, try s.currentShift(a));
    try testing.expectError(error.NotFound, s.startBreak(10 * h));

    // Clocked out, so a new shift can start.
    _ = try s.startShift(8 * h, at(24 * h));
}

test "shifts - break shorter than a minute is dropped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    const shift_id = try s.startShift(8 * h, at(0));
    _ = try s.startBreak(100);
    try testing.expectEqual(null, try s.endBreak(159));
    try testing.expectEqual(0, (try s.breaks(arena.allocator(), shift_id)).len);
}

test "shifts - break and clock out stop the running entry" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    _ = try s.startShift(8 * h, at(0));
    _ = try s.startEntry(.{ .source = .tui }, at(0));
    _ = try s.startBreak(2 * h);
    try testing.expectEqual(null, try s.runningEntry(a));
    _ = try s.endBreak(3 * h);

    _ = try s.startEntry(.{ .source = .tui }, at(3 * h));
    _ = try s.startBreak(5 * h); // left running
    _ = try s.endShift(9 * h);
    try testing.expectEqual(null, try s.runningEntry(a));

    const entries = try s.entriesBetween(a, 0, 24 * h);
    try testing.expectEqual(2, entries.len);
    try testing.expectEqual(2 * h, entries[0].out_ts.?);
    try testing.expectEqual(5 * h, entries[1].out_ts.?);
}

test "shifts - edit, planned breaks, delete" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    const shift_id = try s.startShift(8 * h, at(9 * h));
    try s.editShift(shift_id, .{ .in_ts = 8 * h }, 9 * h);
    try s.editShift(shift_id, .{ .target_secs = 7 * h }, 9 * h);
    const shift = (try s.currentShift(a)).?;
    try testing.expectEqual(8 * h, shift.in_ts);
    try testing.expectEqual(7 * h, shift.target_secs);
    try testing.expectError(error.NotFound, s.editShift(.v7(io), .{ .target_secs = h }, 0));

    const lunch = try s.addBreak(shift_id, 12 * h, 13 * h, 9 * h);
    try testing.expectError(error.Conflict, s.addBreak(shift_id, 14 * h, 13 * h, 9 * h));
    try testing.expectEqual(16 * h, store.clockOut(shift, try s.breaks(a, shift_id), 9 * h));

    try s.editBreak(lunch, 12 * h, 12 * h + 1800, 9 * h);
    try testing.expectEqual(15 * h + 1800, store.clockOut(shift, try s.breaks(a, shift_id), 9 * h));

    try s.deleteBreak(lunch, 9 * h);
    try testing.expectError(error.NotFound, s.deleteBreak(lunch, 9 * h));
    try testing.expectEqual(0, (try s.breaks(a, shift_id)).len);
}

test "shifts - add after the fact, move, delete" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    try testing.expectError(error.Conflict, s.addShift(at(17 * h), 9 * h));
    const past = try s.addShift(at(9 * h), 17 * h);
    _ = try s.addBreak(past, 12 * h, 12 * h + 1800, 18 * h);
    var shifts = try s.shiftsBetween(a, 0, 24 * h);
    try testing.expectEqual(1, shifts.len);
    try testing.expectEqual(8 * h, shifts[0].target_secs);
    try testing.expectEqual(17 * h, shifts[0].out_ts.?);
    // Adding one doesn't clock you in.
    try testing.expectEqual(null, try s.currentShift(a));

    try s.setShiftTimes(past, 8 * h, 16 * h, 18 * h);
    shifts = try s.shiftsBetween(a, 0, 24 * h);
    try testing.expectEqual(8 * h, shifts[0].in_ts);
    try testing.expectEqual(16 * h, shifts[0].out_ts.?);
    try testing.expectError(error.Conflict, s.setShiftTimes(past, 16 * h, 8 * h, 18 * h));

    // The open shift's clock out isn't known, so it can't be moved.
    const open = try s.startShift(8 * h, at(30 * h));
    try testing.expectError(error.NotFound, s.setShiftTimes(open, 30 * h, 31 * h, 31 * h));

    try s.deleteShift(past, 18 * h);
    try testing.expectError(error.NotFound, s.deleteShift(past, 18 * h));
    try testing.expectEqual(0, (try s.shiftsBetween(a, 0, 24 * h)).len);
    try testing.expectEqual(0, (try s.breaks(a, past)).len);

    try s.deleteShift(open, 31 * h);
    try testing.expectEqual(null, try s.currentShift(a));
}

test "shifts - a forgotten shift closes at its clock out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    const shift_id = try s.startShift(8 * h, at(0));
    _ = try s.startBreak(4 * h); // forgotten

    // Not stale yet: the running break still counts, so clock out is "now".
    try testing.expect(!try s.closeStaleShift(a, 10 * h));
    try testing.expect((try s.currentShift(a)) != null);

    // 12h after the forgotten break started it's dropped, but the shift's
    // plain 8h clock out isn't 12h past yet.
    try testing.expect(!try s.closeStaleShift(a, 16 * h + 1));
    try testing.expectEqual(0, (try s.breaks(a, shift_id)).len);
    try testing.expect((try s.currentShift(a)) != null);

    try testing.expect(try s.closeStaleShift(a, 20 * h + 1));
    try testing.expectEqual(null, try s.currentShift(a));
    const ended = try s.shiftsBetween(a, 0, 24 * h);
    try testing.expectEqual(1, ended.len);
    try testing.expectEqual(8 * h, ended[0].out_ts.?);

    try testing.expect(!try s.closeStaleShift(a, 40 * h));
}

// ── Break presets ──────────────────────────────────────────────────────────

/// Local midnight starting Tuesday, 6 January 1970, in `at`'s zone (UTC-5).
const tue = 5 * 24 * h + 5 * h;
const tue_thu = 0b0001010;

fn class(id: core.Uuid, weekdays: u7, start: i64, end: i64) store.BreakPreset {
    return .{
        .id = id,
        .name = "Class",
        .weekdays = weekdays,
        .rule = .{ .scheduled = .{ .start_secs = start, .end_secs = end } },
    };
}

test "break presets - put, list, edit, delete" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    // A new store has the lunch window, off.
    var presets = try s.breakPresets(a);
    try testing.expectEqual(1, presets.len);
    try testing.expectEqualStrings("Lunch", presets[0].name);
    try testing.expect(!presets[0].enabled);
    const lunch_id = presets[0].id;

    const id: core.Uuid = .v7(io);
    try s.putBreakPreset(class(id, tue_thu, 11 * h, 14 * h), 1);
    var lunch = presets[0];
    lunch.enabled = true;
    lunch.rule.window.latest_secs = 6 * h;
    try s.putBreakPreset(lunch, 1);

    presets = try s.breakPresets(a);
    try testing.expectEqual(2, presets.len);
    try testing.expect(presets[0].id.eql(lunch_id));
    try testing.expect(presets[0].enabled);
    try testing.expectEqual(6 * h, presets[0].rule.window.latest_secs);
    try testing.expectEqualStrings("Class", presets[1].name);
    try testing.expectEqual(tue_thu, presets[1].weekdays);
    try testing.expectEqual(11 * h, presets[1].rule.scheduled.start_secs);
    try testing.expectEqual(14 * h, presets[1].rule.scheduled.end_secs);

    // Ends before it starts; a window that closes before it opens.
    try testing.expectError(error.Conflict, s.putBreakPreset(class(.v7(io), tue_thu, 14 * h, 11 * h), 2));
    lunch.rule.window.latest_secs = h;
    try testing.expectError(error.Conflict, s.putBreakPreset(lunch, 2));

    // Deleting a window deletes its alarms.
    const alarm = try s.addAlarmRule(.{ .window_opens = lunch_id }, 2);
    try s.deleteBreakPreset(lunch_id, 3);
    try testing.expectError(error.NotFound, s.deleteBreakPreset(lunch_id, 3));
    try testing.expectError(error.NotFound, s.setAlarmEnabled(alarm, false, 3));
    try s.deleteBreakPreset(id, 3);
    try testing.expectEqual(0, (try s.breakPresets(a)).len);
}

test "break presets - clocking in adds the day's scheduled breaks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    try s.putBreakPreset(class(.v7(io), tue_thu, 11 * h, 14 * h), 0);
    var off = class(.v7(io), tue_thu, 15 * h, 15 * h + 900);
    off.enabled = false;
    try s.putBreakPreset(off, 0);
    // Turned on, but a window adds no break.
    var lunch = (try s.breakPresets(a))[0];
    lunch.enabled = true;
    try s.putBreakPreset(lunch, 0);

    // Tuesday at 9: class goes on the shift, and clock out moves to 8pm.
    const tuesday = try s.startShift(8 * h, at(tue + 9 * h));
    const brks = try s.breaks(a, tuesday);
    try testing.expectEqual(1, brks.len);
    try testing.expectEqual(tue + 11 * h, brks[0].in_ts);
    try testing.expectEqual(tue + 14 * h, brks[0].out_ts.?);
    const shift = (try s.currentShift(a)).?;
    try testing.expectEqual(tue + 20 * h, store.clockOut(shift, brks, tue + 9 * h));
    _ = try s.endShift(tue + 20 * h);

    // Wednesday: no class.
    const wednesday = try s.startShift(8 * h, at(tue + 24 * h + 9 * h));
    try testing.expectEqual(0, (try s.breaks(a, wednesday)).len);
    _ = try s.endShift(tue + 24 * h + 17 * h);

    // An empty shift, for a frontend that brings its own breaks.
    const bare = try s.startEmptyShift(8 * h, at(tue + 2 * 24 * h + 9 * h));
    try testing.expectEqual(0, (try s.breaks(a, bare)).len);
}

test "break presets - the day's breaks are cut to the shift" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    try s.putBreakPreset(class(.v7(io), tue_thu, 11 * h, 14 * h), 0);
    try s.putBreakPreset(class(.v7(io), tue_thu, 8 * h, 9 * h), 0);
    // After a 4h shift starting at noon (with the rest of class) ends.
    try s.putBreakPreset(class(.v7(io), tue_thu, 19 * h, 20 * h), 0);

    // Clocking in at noon: class counts from noon, the 8am one is over.
    const planned = try s.scheduledBreaks(a, at(tue + 12 * h), 4 * h);
    try testing.expectEqual(1, planned.len);
    try testing.expectEqual(tue + 12 * h, planned[0].in_ts);
    try testing.expectEqual(tue + 14 * h, planned[0].out_ts);
}

test "break presets - a planned break stops the timer where it starts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    try s.putBreakPreset(class(.v7(io), tue_thu, 11 * h, 14 * h), 0);
    _ = try s.startShift(8 * h, at(tue + 9 * h));
    const work = try s.startEntry(.{ .source = .tui }, at(tue + 9 * h));

    // Before class nothing happens.
    try testing.expectEqual(null, try s.stopForBreaks(a, tue + 10 * h));
    // Looked at again mid-class, it ended when class began.
    try testing.expect((try s.stopForBreaks(a, tue + 12 * h)).?.eql(work));
    try testing.expectEqual(null, try s.runningEntry(a));
    try testing.expectEqual(tue + 11 * h, (try s.entriesBetween(a, tue, tue + 24 * h))[0].out_ts.?);

    // Started during class: you're working anyway, so it keeps running.
    _ = try s.startEntry(.{ .source = .tui }, at(tue + 12 * h));
    try testing.expectEqual(null, try s.stopForBreaks(a, tue + 13 * h));

    // Housekeeping does it too, for the CLI and TUI.
    _ = try s.stopEntry(tue + 13 * h);
    _ = try s.startEntry(.{ .source = .tui }, at(tue + 14 * h));
    _ = try s.addBreak((try s.currentShift(a)).?.id, tue + 15 * h, tue + 15 * h + 900, tue + 14 * h);
    _ = try s.closeStaleShift(a, tue + 15 * h + 60);
    try testing.expectEqual(null, try s.runningEntry(a));
}

// ── Alarms, settings, links ─────────────────────────────────────────────────

test "alarm rules" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    const ten = try s.addAlarmRule(.{ .before_clock_out = 10 }, 0);
    const lunch = try s.addAlarmRule(.{ .at_time = 12 * h }, 0);
    try testing.expectError(error.Conflict, s.addAlarmRule(.{ .at_time = 25 * h }, 0));
    try testing.expectError(error.Conflict, s.addAlarmRule(.{ .before_clock_out = -1 }, 0));

    try s.setAlarmEnabled(lunch, false, 1);
    var rules = try s.alarmRules(a);
    try testing.expectEqual(2, rules.len);
    try testing.expect(rules[0].id.eql(ten));
    try testing.expectEqual(10, rules[0].trigger.before_clock_out);
    try testing.expect(rules[0].enabled);
    try testing.expectEqual(12 * h, rules[1].trigger.at_time);
    try testing.expect(!rules[1].enabled);

    const lunch_id = (try s.breakPresets(a))[0].id;
    const opens = try s.addAlarmRule(.{ .window_opens = lunch_id }, 1);
    const closing = try s.addAlarmRule(.{ .before_window_closes = .{ .minutes = 30, .preset_id = lunch_id } }, 1);
    try testing.expectError(error.Conflict, s.addAlarmRule(.{ .before_window_closes = .{ .minutes = -5, .preset_id = lunch_id } }, 1));
    // A window that isn't there.
    try testing.expectError(error.Conflict, s.addAlarmRule(.{ .window_opens = .v7(io) }, 1));
    rules = try s.alarmRules(a);
    try testing.expectEqual(4, rules.len);
    try testing.expect(rules[2].id.eql(opens));
    try testing.expect(rules[2].trigger.window_opens.eql(lunch_id));
    try testing.expectEqual(30, rules[3].trigger.before_window_closes.minutes);
    try s.putAlarmRule(.{ .id = closing, .trigger = .{ .before_window_closes = .{ .minutes = 15, .preset_id = lunch_id } }, .enabled = true }, 2);
    try testing.expectEqual(15, (try s.alarmRules(a))[3].trigger.before_window_closes.minutes);
    try s.deleteAlarmRule(opens, 2);
    try s.deleteAlarmRule(closing, 2);

    const before = try s.addAlarmRule(.{ .before_break = 10 }, 2);
    const back = try s.addAlarmRule(.{ .before_break_ends = 0 }, 2);
    try testing.expectError(error.Conflict, s.addAlarmRule(.{ .before_break = -1 }, 2));
    rules = try s.alarmRules(a);
    try testing.expectEqual(10, rules[2].trigger.before_break);
    try testing.expectEqual(0, rules[3].trigger.before_break_ends);
    try s.deleteAlarmRule(before, 2);
    try s.deleteAlarmRule(back, 2);

    try s.deleteAlarmRule(ten, 2);
    rules = try s.alarmRules(a);
    try testing.expectEqual(1, rules.len);
    try testing.expectError(error.NotFound, s.setAlarmEnabled(ten, true, 3));
}

test "settings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    try testing.expectEqual(null, try s.setting(a, "clock_out_link"));
    try s.setSetting("clock_out_link", "https://example.com", 0);
    try s.setSetting("clock_out_link", "https://example.com/clock", 1);
    try testing.expectEqualStrings("https://example.com/clock", (try s.setting(a, "clock_out_link")).?);
    try s.setSetting("clock_out_link", null, 2);
    try testing.expectEqual(null, try s.setting(a, "clock_out_link"));
}

test "links - resolve, re-point, validate" {
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    const web = try s.createProject(.{ .name = "web" }, 0);
    const api = try s.createProject(.{ .name = "api" }, 0);
    const main = try s.createWorkspace(web, "main", 0);
    const situ_id = "01A0F5C4929E71CA888CD75111AC0F15";

    try testing.expectEqual(null, try s.resolveLink("situ", "project", situ_id));
    try s.link("situ", "project", situ_id, .{ .project_id = web, .workspace_id = main }, 0);
    var t = (try s.resolveLink("situ", "project", situ_id)).?;
    try testing.expect(t.project_id.eql(web));
    try testing.expect(t.workspace_id.?.eql(main));

    try s.link("situ", "project", situ_id, .{ .project_id = api }, 1);
    t = (try s.resolveLink("situ", "project", situ_id)).?;
    try testing.expect(t.project_id.eql(api));
    try testing.expectEqual(null, t.workspace_id);

    try testing.expectError(error.Mismatch, s.link("situ", "workspace", "x", .{ .project_id = api, .workspace_id = main }, 2));
    try testing.expectEqual(null, try s.resolveLink("situ", "workspace", "x"));
}

test "entries - set and clear a note" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    const e = try s.startEntry(.{ .source = .tui }, at(0));
    try s.setEntryNote(e, "pairing", 10);
    try testing.expectEqualStrings("pairing", (try s.runningEntry(a)).?.note.?);
    try s.setEntryNote(e, null, 20);
    try testing.expectEqual(null, (try s.runningEntry(a)).?.note);
    try testing.expectError(error.NotFound, s.setEntryNote(.v7(io), "x", 30));
}

test "shifts - starting an entry ends the break" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    const shift_id = try s.startShift(8 * h, at(0));
    _ = try s.startBreak(2 * h);
    _ = try s.startEntry(.{ .source = .cli }, at(3 * h));
    const brks = try s.breaks(a, shift_id);
    try testing.expectEqual(1, brks.len);
    try testing.expectEqual(3 * h, brks[0].out_ts.?);
}

test "putBreak / putAlarmRule - caller's ids, insert then replace" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    const shift_id = try s.startShift(8 * h, at(0));
    const b: core.Uuid = .v7At(5, @splat(1));
    try s.putBreak(b, shift_id, 2 * h, null, 0);
    try testing.expect((try s.breaks(a, shift_id))[0].out_ts == null);
    try testing.expectError(error.Conflict, s.putBreak(.v7At(6, @splat(1)), shift_id, 3 * h, null, 0));
    try s.putBreak(b, shift_id, 2 * h, 3 * h, 1);
    var brks = try s.breaks(a, shift_id);
    try testing.expectEqual(1, brks.len);
    try testing.expect(brks[0].id.eql(b));
    try testing.expectEqual(3 * h, brks[0].out_ts.?);

    // A deleted break put again comes back.
    try s.deleteBreak(b, 2);
    try s.putBreak(b, shift_id, 2 * h, 4 * h, 3);
    brks = try s.breaks(a, shift_id);
    try testing.expectEqual(4 * h, brks[0].out_ts.?);

    const r: core.Uuid = .v7At(7, @splat(2));
    try s.putAlarmRule(.{ .id = r, .trigger = .{ .before_clock_out = 10 }, .enabled = true }, 0);
    try s.putAlarmRule(.{ .id = r, .trigger = .{ .at_time = 9 * h }, .enabled = false }, 1);
    const rules = try s.alarmRules(a);
    try testing.expectEqual(1, rules.len);
    try testing.expectEqual(9 * h, rules[0].trigger.at_time);
    try testing.expect(!rules[0].enabled);
}

test "dataVersion - moves when another connection commits" {
    var tmp: TmpDb = try .init();
    defer tmp.deinit();
    var app: Store = try .open(io, tmp.path);
    defer app.deinit();
    var tui: Store = try .open(io, tmp.path);
    defer tui.deinit();

    const v0 = try app.dataVersion();
    _ = try app.createClient("own write", 0);
    try testing.expectEqual(v0, try app.dataVersion());
    _ = try tui.createClient("their write", 0);
    try testing.expect(try app.dataVersion() != v0);
}

test "entries - add after the fact, edit, delete" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    const web = try s.createProject(.{ .name = "web" }, 0);
    const main = try s.createWorkspace(web, "main", 0);
    const other = try s.createProject(.{ .name = "other" }, 0);

    const running = try s.startEntry(.{ .source = .tui }, at(5 * h));
    const meeting = try s.addEntry(.{ .project_id = web, .source = .manual, .note = "standup" }, at(h), 2 * h);
    try testing.expect((try s.runningEntry(a)).?.id.eql(running));

    try s.editEntry(meeting, .{ .project_id = null, .workspace_id = main, .in_ts = h, .out_ts = 3 * h, .note = null }, 10);
    var day = try s.entriesBetween(a, 0, 24 * h);
    try testing.expectEqual(2, day.len);
    try testing.expect(day[0].project_id.?.eql(web));
    try testing.expect(day[0].workspace_id.?.eql(main));
    try testing.expectEqual(3 * h, day[0].out_ts.?);
    try testing.expectEqual(null, day[0].note);
    try testing.expectEqual(.manual, day[0].source);

    try testing.expectError(error.Mismatch, s.editEntry(meeting, .{ .project_id = other, .workspace_id = main, .in_ts = h, .out_ts = 3 * h, .note = null }, 11));
    try testing.expectError(error.Conflict, s.editEntry(meeting, .{ .project_id = web, .workspace_id = null, .in_ts = 3 * h, .out_ts = 2 * h, .note = null }, 11));
    try testing.expectError(error.Conflict, s.addEntry(.{ .source = .manual }, at(4 * h), 4 * h));

    // Giving the running entry an end stops it.
    try s.editEntry(running, .{ .project_id = other, .workspace_id = null, .in_ts = 5 * h, .out_ts = 6 * h, .note = null }, 12);
    try testing.expectEqual(null, try s.runningEntry(a));

    try s.deleteEntry(meeting, 13);
    try testing.expectError(error.NotFound, s.deleteEntry(meeting, 14));
    day = try s.entriesBetween(a, 0, 24 * h);
    try testing.expectEqual(1, day.len);
}

test "projects - rename, recolor, delete keeps the time" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Store = try .open(io, ":memory:");
    defer s.deinit();

    const acme = try s.createClient("Acme", 0);
    const web = try s.createProject(.{ .name = "web" }, 0);
    const main = try s.createWorkspace(web, "main", 0);
    const other = try s.createProject(.{ .name = "other" }, 0);
    try s.link("situ", "workspace", "w1", .{ .project_id = web, .workspace_id = main }, 0);

    _ = try s.addEntry(.{ .workspace_id = main, .source = .manual }, at(h), 2 * h);
    _ = try s.addEntry(.{ .project_id = web, .source = .manual }, at(3 * h), 5 * h);
    _ = try s.startEntry(.{ .project_id = web, .source = .tui }, at(6 * h));
    _ = try s.addEntry(.{ .project_id = other, .source = .manual }, at(h), 90 * 60);

    var usage = try s.projectUsage(a, 7 * h);
    try testing.expectEqual(2, usage.len);
    const web_usage = if (usage[0].project_id.eql(web)) usage[0] else usage[1];
    try testing.expectEqual(3, web_usage.entries);
    try testing.expectEqual(4 * h, web_usage.seconds);
    try testing.expectEqual(6 * h, web_usage.last_ts);

    try s.editProject(web, .{ .name = "Website", .client_id = acme, .color = "#3b82f6" }, 10);
    var ps = try s.projects(a);
    try testing.expectEqualStrings("Website", ps[1].name);
    try testing.expectEqualStrings("#3b82f6", ps[1].color.?);
    try testing.expect(ps[1].client_id.?.eql(acme));

    try s.deleteProject(web, 20);
    try testing.expectError(error.NotFound, s.deleteProject(web, 21));
    try testing.expectError(error.NotFound, s.editProject(web, .{ .name = "x" }, 21));
    ps = try s.projects(a);
    try testing.expectEqual(1, ps.len);
    try testing.expectEqual(0, (try s.workspaces(a, web)).len);
    try testing.expectEqual(null, try s.resolveLink("situ", "workspace", "w1"));

    // Its time is still there, unassigned; the running entry keeps running.
    const day = try s.entriesBetween(a, 0, 24 * h);
    try testing.expectEqual(4, day.len);
    var unassigned: usize = 0;
    for (day) |e| {
        if (e.project_id == null) {
            try testing.expectEqual(null, e.workspace_id);
            unassigned += 1;
        }
    }
    try testing.expectEqual(3, unassigned);
    try testing.expectEqual(null, (try s.runningEntry(a)).?.out_ts);
    usage = try s.projectUsage(a, 7 * h);
    try testing.expectEqual(1, usage.len);
}
