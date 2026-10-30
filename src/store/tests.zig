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
    try testing.expectEqual(1, stmt.int(0));
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

    try testing.expectError(error.NoHome, store.defaultPath(gpa, &env));

    try env.put("HOME", "/home/jeff");
    const home = try store.defaultPath(gpa, &env);
    defer gpa.free(home);
    const want = if (builtin.os.tag == .macos)
        "/home/jeff/Library/Application Support/Shifty/shifty.db"
    else
        "/home/jeff/.local/share/shifty/shifty.db";
    try testing.expectEqualStrings(want, home);

    try env.put("SHIFTY_DB", "/tmp/dev.db");
    const override = try store.defaultPath(gpa, &env);
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
