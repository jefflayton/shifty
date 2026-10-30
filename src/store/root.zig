//! The local database every frontend shares: the TUI, CLI, and macOS app
//! can all have it open at once (WAL mode, busy timeout). Running state
//! (the current shift, break, entry) lives here too, so starting a timer in
//! one shows up in the others.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const core = @import("core");
const Uuid = core.Uuid;
const Stamp = core.local.Stamp;

pub const sqlite = @import("sqlite.zig");
const Blob = sqlite.Blob;

pub const Error = error{
    /// Another connection held the lock past the busy timeout.
    Busy,
    /// A constraint failed: e.g. a second running entry, or a dangling id.
    Conflict,
    /// A workspace was given with a project it doesn't belong to.
    Mismatch,
    NotFound,
    Corrupt,
    /// The database was written by a newer Shifty.
    SchemaTooNew,
    OutOfMemory,
    Io,
};

pub const Source = enum { manual, menubar, tui, cli, editor, calendar };

pub const Client = struct {
    id: Uuid,
    name: []const u8,
};

pub const Project = struct {
    id: Uuid,
    client_id: ?Uuid,
    name: []const u8,
    color: ?[]const u8,
};

pub const Workspace = struct {
    id: Uuid,
    project_id: Uuid,
    name: []const u8,
};

pub const Entry = struct {
    id: Uuid,
    project_id: ?Uuid,
    workspace_id: ?Uuid,
    in_ts: i64,
    utc_offset_secs: i64,
    tz: ?[]const u8,
    /// null while running.
    out_ts: ?i64,
    source: Source,
    note: ?[]const u8,
};

pub const NewProject = struct {
    name: []const u8,
    client_id: ?Uuid = null,
    color: ?[]const u8 = null,
};

pub const NewEntry = struct {
    /// Implied by `workspace_id` when null.
    project_id: ?Uuid = null,
    workspace_id: ?Uuid = null,
    source: Source,
    note: ?[]const u8 = null,
};

const migrations = [_][:0]const u8{
    @embedFile("migrations/0001_init.sql"),
};

pub const Store = struct {
    db: sqlite.Db,
    io: Io,

    /// Opens (creating if needed) the database at `path` and migrates it.
    /// `:memory:` gives a private in-memory database, for tests.
    pub fn open(io: Io, path: [:0]const u8) Error!Store {
        const memory = std.mem.eql(u8, path, ":memory:");
        if (!memory) {
            if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch return error.Io;
        }

        const db: sqlite.Db = try .open(path);
        errdefer db.close();
        var self: Store = .{ .db = db, .io = io };

        // The TUI and the app may write at the same moment; wait, don't fail.
        try db.execScript("PRAGMA busy_timeout = 5000; PRAGMA foreign_keys = on;");
        if (!memory) {
            try db.execScript("PRAGMA journal_mode = wal; PRAGMA synchronous = normal;");
            var stmt = try db.prepare("PRAGMA journal_mode");
            defer stmt.deinit();
            if (!try stmt.step() or !std.mem.eql(u8, stmt.bytes(0), "wal")) return error.Io;
        }

        try self.migrate();
        return self;
    }

    pub fn deinit(self: *Store) void {
        self.db.close();
    }

    /// SQLite's message for the last failed call, for logs.
    pub fn errmsg(self: *Store) []const u8 {
        return self.db.errmsg();
    }

    fn migrate(self: *Store) Error!void {
        try self.begin();
        errdefer self.rollback();

        const current: usize = @intCast(try self.oneInt("PRAGMA user_version", .{}) orelse 0);
        if (current > migrations.len) return error.SchemaTooNew;
        for (migrations[current..], current + 1..) |sql, version| {
            try self.db.execScript(sql);
            var buf: [32]u8 = undefined;
            const set = std.fmt.bufPrintSentinel(&buf, "PRAGMA user_version = {d}", .{version}, 0) catch unreachable;
            try self.db.execScript(set);
        }

        const replica: Uuid = .v7(self.io);
        try self.db.exec("INSERT OR IGNORE INTO meta (id, replica_id) VALUES (1, ?)", .{blob(&replica)});

        try self.commit();
    }

    // IMMEDIATE takes the write lock up front, so a read-then-write
    // transaction can't deadlock against another process doing the same.
    fn begin(self: *Store) Error!void {
        try self.db.execScript("BEGIN IMMEDIATE");
    }

    fn commit(self: *Store) Error!void {
        try self.db.execScript("COMMIT");
    }

    fn rollback(self: *Store) void {
        self.db.execScript("ROLLBACK") catch {};
    }

    fn oneInt(self: *Store, sql: []const u8, values: anytype) Error!?i64 {
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();
        try stmt.bindAll(values);
        return if (try stmt.step()) stmt.optInt(0) else null;
    }

    fn oneId(self: *Store, sql: []const u8, values: anytype) Error!?Uuid {
        var stmt = try self.db.prepare(sql);
        defer stmt.deinit();
        try stmt.bindAll(values);
        return if (try stmt.step()) try optId(stmt, 0) else null;
    }

    pub fn replicaId(self: *Store) Error!Uuid {
        return try self.oneId("SELECT replica_id FROM meta WHERE id = 1", .{}) orelse error.Corrupt;
    }

    // ── Organization ──────────────────────────────────────────────────────

    pub fn createClient(self: *Store, name: []const u8, now: i64) Error!Uuid {
        const new: Uuid = .v7(self.io);
        try self.db.exec(
            \\INSERT INTO clients (id, name, created_ts, updated_ts) VALUES (?, ?, ?, ?)
        , .{ blob(&new), name, now, now });
        return new;
    }

    /// Clients not archived or deleted, by name. Allocated in `arena`.
    pub fn clients(self: *Store, arena: Allocator) Error![]Client {
        var stmt = try self.db.prepare(
            \\SELECT id, name FROM clients
            \\WHERE archived_ts IS NULL AND deleted_ts IS NULL
            \\ORDER BY name COLLATE NOCASE
        );
        defer stmt.deinit();
        var out: std.ArrayList(Client) = .empty;
        while (try stmt.step()) try out.append(arena, .{
            .id = try id(stmt, 0),
            .name = try stmt.text(arena, 1),
        });
        return out.items;
    }

    pub fn createProject(self: *Store, p: NewProject, now: i64) Error!Uuid {
        const new: Uuid = .v7(self.io);
        try self.db.exec(
            \\INSERT INTO projects (id, client_id, name, color, created_ts, updated_ts)
            \\VALUES (?, ?, ?, ?, ?, ?)
        , .{ blob(&new), optBlob(&p.client_id), p.name, p.color, now, now });
        return new;
    }

    /// Projects not archived or deleted, by name. Allocated in `arena`.
    pub fn projects(self: *Store, arena: Allocator) Error![]Project {
        var stmt = try self.db.prepare(
            \\SELECT id, client_id, name, color FROM projects
            \\WHERE archived_ts IS NULL AND deleted_ts IS NULL
            \\ORDER BY name COLLATE NOCASE
        );
        defer stmt.deinit();
        var out: std.ArrayList(Project) = .empty;
        while (try stmt.step()) try out.append(arena, .{
            .id = try id(stmt, 0),
            .client_id = try optId(stmt, 1),
            .name = try stmt.text(arena, 2),
            .color = try stmt.optText(arena, 3),
        });
        return out.items;
    }

    pub fn createWorkspace(self: *Store, project_id: Uuid, name: []const u8, now: i64) Error!Uuid {
        const new: Uuid = .v7(self.io);
        try self.db.exec(
            \\INSERT INTO workspaces (id, project_id, name, created_ts, updated_ts)
            \\VALUES (?, ?, ?, ?, ?)
        , .{ blob(&new), blob(&project_id), name, now, now });
        return new;
    }

    /// A project's workspaces not archived or deleted, by name. Allocated in
    /// `arena`.
    pub fn workspaces(self: *Store, arena: Allocator, project_id: Uuid) Error![]Workspace {
        var stmt = try self.db.prepare(
            \\SELECT id, name FROM workspaces
            \\WHERE project_id = ? AND archived_ts IS NULL AND deleted_ts IS NULL
            \\ORDER BY name COLLATE NOCASE
        );
        defer stmt.deinit();
        try stmt.bindAll(.{blob(&project_id)});
        var out: std.ArrayList(Workspace) = .empty;
        while (try stmt.step()) try out.append(arena, .{
            .id = try id(stmt, 0),
            .project_id = project_id,
            .name = try stmt.text(arena, 1),
        });
        return out.items;
    }

    // ── Entries ───────────────────────────────────────────────────────────

    /// Stops the running entry, if any, and starts a new one at `at`.
    pub fn startEntry(self: *Store, e: NewEntry, at: Stamp) Error!Uuid {
        try self.begin();
        errdefer self.rollback();

        var project_id = e.project_id;
        if (e.workspace_id) |ws| {
            const owner = try self.oneId("SELECT project_id FROM workspaces WHERE id = ?", .{blob(&ws)}) orelse
                return error.NotFound;
            if (project_id) |p| {
                if (!p.eql(owner)) return error.Mismatch;
            } else project_id = owner;
        }

        _ = try self.closeRunning(at.ts);

        const new: Uuid = .v7(self.io);
        try self.db.exec(
            \\INSERT INTO entries (id, project_id, workspace_id, in_ts, utc_offset_secs, tz,
            \\                     source, note, created_ts, updated_ts)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        , .{
            blob(&new),         optBlob(&project_id), optBlob(&e.workspace_id),
            at.ts,              at.utc_offset_secs,   at.tz,
            @tagName(e.source), e.note,               at.ts,
            at.ts,
        });

        try self.commit();
        return new;
    }

    /// Stops the running entry at `now`. Returns its id, or null if nothing
    /// was running or it was dropped for ending the second it started.
    pub fn stopEntry(self: *Store, now: i64) Error!?Uuid {
        try self.begin();
        errdefer self.rollback();
        const stopped = try self.closeRunning(now);
        try self.commit();
        return stopped;
    }

    /// An entry that would end at or before it started (stopped the same
    /// second, or a clock jump) is soft-deleted rather than violating
    /// `out_ts > in_ts`.
    fn closeRunning(self: *Store, now: i64) Error!?Uuid {
        var stmt = try self.db.prepare(
            \\SELECT id, in_ts FROM entries WHERE out_ts IS NULL AND deleted_ts IS NULL
        );
        defer stmt.deinit();
        if (!try stmt.step()) return null;
        const running = try id(stmt, 0);
        const in_ts = stmt.int(1);

        if (now > in_ts) {
            try self.db.exec("UPDATE entries SET out_ts = ?, updated_ts = ? WHERE id = ?", .{ now, now, blob(&running) });
            return running;
        }
        try self.db.exec("UPDATE entries SET deleted_ts = ?, updated_ts = ? WHERE id = ?", .{ now, now, blob(&running) });
        return null;
    }

    /// The running entry, if any. Allocated in `arena`.
    pub fn runningEntry(self: *Store, arena: Allocator) Error!?Entry {
        const rows = try self.queryEntries(arena,
            \\WHERE out_ts IS NULL AND deleted_ts IS NULL
        , .{});
        return if (rows.len == 0) null else rows[0];
    }

    /// Entries overlapping `[from, to)`, running ones included, oldest first.
    /// Allocated in `arena`.
    pub fn entriesBetween(self: *Store, arena: Allocator, from: i64, to: i64) Error![]Entry {
        return self.queryEntries(arena,
            \\WHERE deleted_ts IS NULL AND in_ts < ? AND (out_ts IS NULL OR out_ts > ?)
            \\ORDER BY in_ts
        , .{ to, from });
    }

    fn queryEntries(self: *Store, arena: Allocator, comptime where: []const u8, values: anytype) Error![]Entry {
        var stmt = try self.db.prepare(
            \\SELECT id, project_id, workspace_id, in_ts, utc_offset_secs, tz, out_ts, source, note
            \\FROM entries
        ++ "\n" ++ where);
        defer stmt.deinit();
        try stmt.bindAll(values);
        var out: std.ArrayList(Entry) = .empty;
        while (try stmt.step()) try out.append(arena, .{
            .id = try id(stmt, 0),
            .project_id = try optId(stmt, 1),
            .workspace_id = try optId(stmt, 2),
            .in_ts = stmt.int(3),
            .utc_offset_secs = stmt.int(4),
            .tz = try stmt.optText(arena, 5),
            .out_ts = stmt.optInt(6),
            .source = std.meta.stringToEnum(Source, stmt.bytes(7)) orelse return error.Corrupt,
            .note = try stmt.optText(arena, 8),
        });
        return out.items;
    }
};

/// Where the shared database lives: `$SHIFTY_DB` if set, else
/// `~/Library/Application Support/Shifty/shifty.db` on macOS and
/// `$XDG_DATA_HOME/shifty/shifty.db` elsewhere.
pub fn defaultPath(gpa: Allocator, env: *const std.process.Environ.Map) error{ OutOfMemory, NoHome }![:0]u8 {
    if (env.get("SHIFTY_DB")) |p| return gpa.dupeZ(u8, p);
    const home = env.get("HOME") orelse return error.NoHome;
    if (builtin.os.tag == .macos) {
        return std.fmt.allocPrintSentinel(gpa, "{s}/Library/Application Support/Shifty/shifty.db", .{home}, 0);
    }
    if (env.get("XDG_DATA_HOME")) |data| {
        if (data.len > 0) return std.fmt.allocPrintSentinel(gpa, "{s}/shifty/shifty.db", .{data}, 0);
    }
    return std.fmt.allocPrintSentinel(gpa, "{s}/.local/share/shifty/shifty.db", .{home}, 0);
}

fn blob(u: *const Uuid) Blob {
    return .{ .bytes = &u.bytes };
}

fn optBlob(u: *const ?Uuid) ?Blob {
    return if (u.*) |*inner| blob(inner) else null;
}

fn id(stmt: sqlite.Stmt, col: c_int) Error!Uuid {
    const b = stmt.bytes(col);
    if (b.len != 16) return error.Corrupt;
    return .{ .bytes = b[0..16].* };
}

fn optId(stmt: sqlite.Stmt, col: c_int) Error!?Uuid {
    return if (stmt.isNull(col)) null else try id(stmt, col);
}

test {
    _ = @import("tests.zig");
}
