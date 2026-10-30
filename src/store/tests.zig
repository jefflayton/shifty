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
