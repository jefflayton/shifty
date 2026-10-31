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
pub const report = @import("report.zig");
pub const ffi = @import("ffi.zig");
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

pub const Shift = struct {
    id: Uuid,
    in_ts: i64,
    utc_offset_secs: i64,
    tz: ?[]const u8,
    /// Worked time the shift is for, e.g. 8h; breaks push clock out later.
    target_secs: i64,
    /// When you actually clocked out; null while on shift.
    out_ts: ?i64,
};

pub const Break = struct {
    id: Uuid,
    shift_id: Uuid,
    in_ts: i64,
    /// null while on it.
    out_ts: ?i64,
};

pub const AlarmRule = struct {
    id: Uuid,
    trigger: Trigger,
    enabled: bool,

    pub const Trigger = union(enum) {
        /// Rings this many minutes before clock out; 0 rings at clock out.
        before_clock_out: i64,
        /// Rings at this local time of day, in seconds since midnight.
        at_time: i64,
    };
};

/// What a link (or an entry) points at.
pub const Target = struct {
    project_id: Uuid,
    workspace_id: ?Uuid = null,
};

/// A shift's expected clock out: `target_secs` of work after clock in, pushed
/// later by breaks. A break in progress counts as ending at `now`.
pub fn clockOut(shift: Shift, brks: []const Break, now: i64) i64 {
    // A shift with more breaks than this isn't a shift.
    var buf: [64]core.shift.Interval = undefined;
    var n: usize = 0;
    for (brks) |b| {
        if (n == buf.len) break;
        buf[n] = .{ .in_ts = b.in_ts, .out_ts = b.out_ts orelse @max(now, b.in_ts) };
        n += 1;
    }
    return core.shift.clockIn(shift.target_secs, shift.in_ts, buf[0..n]);
}

/// A break shorter than this was a mis-click, not a break.
pub const min_break_secs = 60;

/// A shift whose clock out is this far past is over, and a break running
/// this long was forgotten.
pub const stale_after_secs = 12 * std.time.s_per_hour;

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

    /// Changes when another connection commits, not this one: poll it to
    /// notice the TUI or CLI writing while an app keeps the store open.
    pub fn dataVersion(self: *Store) Error!i64 {
        return try self.oneInt("PRAGMA data_version", .{}) orelse 0;
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

    /// Every active workspace, by project then name. Allocated in `arena`.
    pub fn allWorkspaces(self: *Store, arena: Allocator) Error![]Workspace {
        var stmt = try self.db.prepare(
            \\SELECT id, project_id, name FROM workspaces
            \\WHERE archived_ts IS NULL AND deleted_ts IS NULL
            \\ORDER BY project_id, name COLLATE NOCASE
        );
        defer stmt.deinit();
        var out: std.ArrayList(Workspace) = .empty;
        while (try stmt.step()) try out.append(arena, .{
            .id = try id(stmt, 0),
            .project_id = try id(stmt, 1),
            .name = try stmt.text(arena, 2),
        });
        return out.items;
    }

    /// Renames a project, moves it to another client, or changes its color
    /// (`#rrggbb`; null for none).
    pub fn editProject(self: *Store, project_id: Uuid, edit: NewProject, now: i64) Error!void {
        try self.db.exec(
            \\UPDATE projects SET name = ?, client_id = ?, color = ?, updated_ts = ?
            \\WHERE id = ? AND deleted_ts IS NULL
        , .{ edit.name, optBlob(&edit.client_id), edit.color, now, blob(&project_id) });
        if (self.db.changes() == 0) return error.NotFound;
    }

    /// Deletes a project and its workspaces. Its time stays, unassigned, so
    /// deleting a project never loses hours.
    pub fn deleteProject(self: *Store, project_id: Uuid, now: i64) Error!void {
        try self.begin();
        errdefer self.rollback();
        try self.db.exec(
            \\UPDATE projects SET deleted_ts = ?, updated_ts = ?1 WHERE id = ? AND deleted_ts IS NULL
        , .{ now, blob(&project_id) });
        if (self.db.changes() == 0) return error.NotFound;
        try self.db.exec(
            \\UPDATE workspaces SET deleted_ts = ?, updated_ts = ?1
            \\WHERE project_id = ? AND deleted_ts IS NULL
        , .{ now, blob(&project_id) });
        try self.db.exec(
            \\UPDATE entries SET project_id = NULL, workspace_id = NULL, updated_ts = ?
            \\WHERE project_id = ? AND deleted_ts IS NULL
        , .{ now, blob(&project_id) });
        try self.commit();
    }

    pub const ProjectUsage = struct {
        project_id: Uuid,
        entries: i64,
        /// All time, a running entry counted up to `now`.
        seconds: i64,
        /// When its latest entry started.
        last_ts: i64,
    };

    /// How much each active project has been used, for projects with any
    /// time. Allocated in `arena`.
    pub fn projectUsage(self: *Store, arena: Allocator, now: i64) Error![]ProjectUsage {
        var stmt = try self.db.prepare(
            \\SELECT e.project_id, count(*), sum(max(0, coalesce(e.out_ts, ?) - e.in_ts)), max(e.in_ts)
            \\FROM entries e JOIN projects p ON p.id = e.project_id
            \\WHERE e.deleted_ts IS NULL AND p.deleted_ts IS NULL
            \\GROUP BY e.project_id
        );
        defer stmt.deinit();
        try stmt.bindAll(.{now});
        var out: std.ArrayList(ProjectUsage) = .empty;
        while (try stmt.step()) try out.append(arena, .{
            .project_id = try id(stmt, 0),
            .entries = stmt.int(1),
            .seconds = stmt.int(2),
            .last_ts = stmt.int(3),
        });
        return out.items;
    }

    // ── Entries ───────────────────────────────────────────────────────────

    /// Stops the running entry, if any, and starts a new one at `at`.
    /// Starting work ends a break in progress.
    pub fn startEntry(self: *Store, e: NewEntry, at: Stamp) Error!Uuid {
        try self.begin();
        errdefer self.rollback();

        const project_id = try self.projectFor(e.project_id, e.workspace_id);
        _ = try self.closeRunning(at.ts);
        _ = try self.closeBreak(at.ts);

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

    /// Records time after the fact, like a meeting: an entry with both ends,
    /// which leaves the running entry alone. `at` is when it started.
    pub fn addEntry(self: *Store, e: NewEntry, at: Stamp, out_ts: i64) Error!Uuid {
        try self.begin();
        errdefer self.rollback();
        const project_id = try self.projectFor(e.project_id, e.workspace_id);
        const new: Uuid = .v7(self.io);
        try self.db.exec(
            \\INSERT INTO entries (id, project_id, workspace_id, in_ts, utc_offset_secs, tz, out_ts,
            \\                     source, note, created_ts, updated_ts)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?10, ?10)
        , .{
            blob(&new),   optBlob(&project_id), optBlob(&e.workspace_id),
            at.ts,        at.utc_offset_secs,   at.tz,
            out_ts,       @tagName(e.source),   e.note,
            self.nowTs(),
        });
        try self.commit();
        return new;
    }

    /// Everything about an entry a timesheet can change.
    pub const EntryEdit = struct {
        /// Implied by `workspace_id` when null.
        project_id: ?Uuid,
        workspace_id: ?Uuid,
        in_ts: i64,
        /// null keeps a running entry running; a running entry given an end
        /// stops.
        out_ts: ?i64,
        note: ?[]const u8,
    };

    /// Replaces an entry's project, times, and note. `Conflict` if it would
    /// end before it starts.
    pub fn editEntry(self: *Store, entry_id: Uuid, edit: EntryEdit, now: i64) Error!void {
        try self.begin();
        errdefer self.rollback();
        const project_id = try self.projectFor(edit.project_id, edit.workspace_id);
        try self.db.exec(
            \\UPDATE entries SET project_id = ?, workspace_id = ?, in_ts = ?, out_ts = ?, note = ?,
            \\                   updated_ts = ?
            \\WHERE id = ? AND deleted_ts IS NULL
        , .{ optBlob(&project_id), optBlob(&edit.workspace_id), edit.in_ts, edit.out_ts, edit.note, now, blob(&entry_id) });
        if (self.db.changes() == 0) return error.NotFound;
        try self.commit();
    }

    pub fn deleteEntry(self: *Store, entry_id: Uuid, now: i64) Error!void {
        try self.db.exec(
            \\UPDATE entries SET deleted_ts = ?, updated_ts = ?1 WHERE id = ? AND deleted_ts IS NULL
        , .{ now, blob(&entry_id) });
        if (self.db.changes() == 0) return error.NotFound;
    }

    fn nowTs(self: *Store) i64 {
        return Io.Clock.real.now(self.io).toSeconds();
    }

    /// Replaces an entry's note; null clears it.
    pub fn setEntryNote(self: *Store, entry_id: Uuid, note: ?[]const u8, now: i64) Error!void {
        try self.db.exec(
            \\UPDATE entries SET note = ?, updated_ts = ? WHERE id = ? AND deleted_ts IS NULL
        , .{ note, now, blob(&entry_id) });
        if (self.db.changes() == 0) return error.NotFound;
    }

    /// The project `workspace_id` belongs to, checked against `project_id`
    /// if both are given.
    fn projectFor(self: *Store, project_id: ?Uuid, workspace_id: ?Uuid) Error!?Uuid {
        const ws = workspace_id orelse return project_id;
        const owner = try self.oneId("SELECT project_id FROM workspaces WHERE id = ?", .{blob(&ws)}) orelse
            return error.NotFound;
        if (project_id) |p| if (!p.eql(owner)) return error.Mismatch;
        return owner;
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

    // ── Shifts and breaks ─────────────────────────────────────────────────

    /// Clocks in. Fails with `Conflict` if a shift is already open.
    pub fn startShift(self: *Store, target_secs: i64, at: Stamp) Error!Uuid {
        const new: Uuid = .v7(self.io);
        try self.db.exec(
            \\INSERT INTO shifts (id, in_ts, utc_offset_secs, tz, target_secs, created_ts, updated_ts)
            \\VALUES (?, ?, ?, ?, ?, ?, ?)
        , .{ blob(&new), at.ts, at.utc_offset_secs, at.tz, target_secs, at.ts, at.ts });
        return new;
    }

    /// The open shift, if any. Allocated in `arena`.
    pub fn currentShift(self: *Store, arena: Allocator) Error!?Shift {
        const rows = try self.queryShifts(arena,
            \\WHERE out_ts IS NULL AND deleted_ts IS NULL
        , .{});
        return if (rows.len == 0) null else rows[0];
    }

    /// Shifts overlapping `[from, to)`, the open one included, oldest first.
    /// Allocated in `arena`.
    pub fn shiftsBetween(self: *Store, arena: Allocator, from: i64, to: i64) Error![]Shift {
        return self.queryShifts(arena,
            \\WHERE deleted_ts IS NULL AND in_ts < ? AND (out_ts IS NULL OR out_ts > ?)
            \\ORDER BY in_ts
        , .{ to, from });
    }

    fn queryShifts(self: *Store, arena: Allocator, comptime where: []const u8, values: anytype) Error![]Shift {
        var stmt = try self.db.prepare(
            \\SELECT id, in_ts, utc_offset_secs, tz, target_secs, out_ts FROM shifts
        ++ "\n" ++ where);
        defer stmt.deinit();
        try stmt.bindAll(values);
        var out: std.ArrayList(Shift) = .empty;
        while (try stmt.step()) try out.append(arena, .{
            .id = try id(stmt, 0),
            .in_ts = stmt.int(1),
            .utc_offset_secs = stmt.int(2),
            .tz = try stmt.optText(arena, 3),
            .target_secs = stmt.int(4),
            .out_ts = stmt.optInt(5),
        });
        return out.items;
    }

    /// Edits a shift's clock in or length; null fields are left alone.
    pub fn editShift(self: *Store, shift_id: Uuid, edit: struct { in_ts: ?i64 = null, target_secs: ?i64 = null }, now: i64) Error!void {
        try self.db.exec(
            \\UPDATE shifts SET in_ts = coalesce(?, in_ts), target_secs = coalesce(?, target_secs),
            \\                  updated_ts = ?
            \\WHERE id = ? AND deleted_ts IS NULL
        , .{ edit.in_ts, edit.target_secs, now, blob(&shift_id) });
        if (self.db.changes() == 0) return error.NotFound;
    }

    /// Clocks out of the open shift at `now`, ending the running break and
    /// entry with it. Returns the shift's id, or null if none was open.
    pub fn endShift(self: *Store, now: i64) Error!?Uuid {
        try self.begin();
        errdefer self.rollback();
        const ended = try self.closeShift(now);
        try self.commit();
        return ended;
    }

    fn closeShift(self: *Store, out_ts: i64) Error!?Uuid {
        var stmt = try self.db.prepare(
            \\SELECT id, in_ts FROM shifts WHERE out_ts IS NULL AND deleted_ts IS NULL
        );
        defer stmt.deinit();
        if (!try stmt.step()) return null;
        const shift_id = try id(stmt, 0);
        const in_ts = stmt.int(1);

        _ = try self.closeBreak(out_ts);
        _ = try self.closeRunning(out_ts);
        // Clocked out the second it started: nothing to keep.
        const sql = if (out_ts > in_ts)
            "UPDATE shifts SET out_ts = ?, updated_ts = ?1 WHERE id = ?"
        else
            "UPDATE shifts SET deleted_ts = ?, updated_ts = ?1 WHERE id = ?";
        try self.db.exec(sql, .{ out_ts, blob(&shift_id) });
        return shift_id;
    }

    /// Housekeeping for a shift nobody clocked out of: once its expected
    /// clock out is `stale_after_secs` past, it ends there. A break running
    /// that long was forgotten, not taken, so it's dropped first. Returns
    /// whether a shift was closed.
    pub fn closeStaleShift(self: *Store, arena: Allocator, now: i64) Error!bool {
        try self.begin();
        errdefer self.rollback();

        try self.db.exec(
            \\UPDATE breaks SET deleted_ts = ?1, updated_ts = ?1
            \\WHERE out_ts IS NULL AND deleted_ts IS NULL AND in_ts < ?1 - ?2
        , .{ now, stale_after_secs });

        const shift = try self.currentShift(arena) orelse {
            try self.commit();
            return false;
        };
        const out = clockOut(shift, try self.breaks(arena, shift.id), now);
        const stale = out < now - stale_after_secs;
        if (stale) _ = try self.closeShift(out);
        try self.commit();
        return stale;
    }

    /// A shift's breaks, oldest first. Allocated in `arena`.
    pub fn breaks(self: *Store, arena: Allocator, shift_id: Uuid) Error![]Break {
        var stmt = try self.db.prepare(
            \\SELECT id, in_ts, out_ts FROM breaks
            \\WHERE shift_id = ? AND deleted_ts IS NULL
            \\ORDER BY in_ts
        );
        defer stmt.deinit();
        try stmt.bindAll(.{blob(&shift_id)});
        var out: std.ArrayList(Break) = .empty;
        while (try stmt.step()) try out.append(arena, .{
            .id = try id(stmt, 0),
            .shift_id = shift_id,
            .in_ts = stmt.int(1),
            .out_ts = stmt.optInt(2),
        });
        return out.items;
    }

    /// Goes on break from the open shift, stopping the running entry.
    /// `NotFound` if off shift, `Conflict` if already on break.
    pub fn startBreak(self: *Store, now: i64) Error!Uuid {
        try self.begin();
        errdefer self.rollback();

        const shift_id = try self.oneId(
            \\SELECT id FROM shifts WHERE out_ts IS NULL AND deleted_ts IS NULL
        , .{}) orelse return error.NotFound;
        _ = try self.closeRunning(now);

        const new: Uuid = .v7(self.io);
        try self.db.exec(
            \\INSERT INTO breaks (id, shift_id, in_ts, created_ts, updated_ts) VALUES (?, ?, ?, ?3, ?3)
        , .{ blob(&new), blob(&shift_id), now });
        try self.commit();
        return new;
    }

    /// Ends the running break. Returns its id, or null if none was running
    /// or it was shorter than `min_break_secs` and dropped.
    pub fn endBreak(self: *Store, now: i64) Error!?Uuid {
        try self.begin();
        errdefer self.rollback();
        const ended = try self.closeBreak(now);
        try self.commit();
        return ended;
    }

    fn closeBreak(self: *Store, now: i64) Error!?Uuid {
        var stmt = try self.db.prepare(
            \\SELECT id, in_ts FROM breaks WHERE out_ts IS NULL AND deleted_ts IS NULL
        );
        defer stmt.deinit();
        if (!try stmt.step()) return null;
        const brk = try id(stmt, 0);
        const in_ts = stmt.int(1);

        if (now - in_ts >= min_break_secs) {
            try self.db.exec("UPDATE breaks SET out_ts = ?, updated_ts = ?1 WHERE id = ?", .{ now, blob(&brk) });
            return brk;
        }
        try self.db.exec("UPDATE breaks SET deleted_ts = ?, updated_ts = ?1 WHERE id = ?", .{ now, blob(&brk) });
        return null;
    }

    /// Records a break with both ends, e.g. a planned lunch. `Conflict` if
    /// it ends before it starts.
    pub fn addBreak(self: *Store, shift_id: Uuid, in_ts: i64, out_ts: i64, now: i64) Error!Uuid {
        const new: Uuid = .v7(self.io);
        try self.db.exec(
            \\INSERT INTO breaks (id, shift_id, in_ts, out_ts, created_ts, updated_ts)
            \\VALUES (?, ?, ?, ?, ?5, ?5)
        , .{ blob(&new), blob(&shift_id), in_ts, out_ts, now });
        return new;
    }

    /// Creates or replaces a break under an id the caller chose, so a UI's
    /// own ids for breaks carry through. `out_ts` null is the running break,
    /// which stops the running entry, as `startBreak` does.
    pub fn putBreak(self: *Store, break_id: Uuid, shift_id: Uuid, in_ts: i64, out_ts: ?i64, now: i64) Error!void {
        try self.begin();
        errdefer self.rollback();
        if (out_ts == null) _ = try self.closeRunning(@max(in_ts, now));
        try self.db.exec(
            \\INSERT INTO breaks (id, shift_id, in_ts, out_ts, created_ts, updated_ts)
            \\VALUES (?, ?, ?, ?, ?5, ?5)
            \\ON CONFLICT (id) DO UPDATE SET
            \\    shift_id = excluded.shift_id, in_ts = excluded.in_ts, out_ts = excluded.out_ts,
            \\    updated_ts = excluded.updated_ts, deleted_ts = NULL
        , .{ blob(&break_id), blob(&shift_id), in_ts, out_ts, now });
        try self.commit();
    }

    pub fn editBreak(self: *Store, break_id: Uuid, in_ts: i64, out_ts: i64, now: i64) Error!void {
        try self.db.exec(
            \\UPDATE breaks SET in_ts = ?, out_ts = ?, updated_ts = ? WHERE id = ? AND deleted_ts IS NULL
        , .{ in_ts, out_ts, now, blob(&break_id) });
        if (self.db.changes() == 0) return error.NotFound;
    }

    pub fn deleteBreak(self: *Store, break_id: Uuid, now: i64) Error!void {
        try self.db.exec(
            \\UPDATE breaks SET deleted_ts = ?, updated_ts = ?1 WHERE id = ? AND deleted_ts IS NULL
        , .{ now, blob(&break_id) });
        if (self.db.changes() == 0) return error.NotFound;
    }

    // ── Alarms and settings ───────────────────────────────────────────────

    pub fn addAlarmRule(self: *Store, trigger: AlarmRule.Trigger, now: i64) Error!Uuid {
        const new: Uuid = .v7(self.io);
        const minutes: ?i64, const tod: ?i64 = switch (trigger) {
            .before_clock_out => |m| .{ m, null },
            .at_time => |t| .{ null, t },
        };
        try self.db.exec(
            \\INSERT INTO alarm_rules (id, kind, minutes, time_of_day_secs, created_ts, updated_ts)
            \\VALUES (?, ?, ?, ?, ?5, ?5)
        , .{ blob(&new), @tagName(trigger), minutes, tod, now });
        return new;
    }

    /// All alarm rules, enabled or not, oldest first. Allocated in `arena`.
    pub fn alarmRules(self: *Store, arena: Allocator) Error![]AlarmRule {
        var stmt = try self.db.prepare(
            \\SELECT id, kind, minutes, time_of_day_secs, enabled FROM alarm_rules
            \\WHERE deleted_ts IS NULL ORDER BY created_ts, rowid
        );
        defer stmt.deinit();
        var out: std.ArrayList(AlarmRule) = .empty;
        while (try stmt.step()) {
            const Kind = @typeInfo(AlarmRule.Trigger).@"union".tag_type.?;
            const kind = std.meta.stringToEnum(Kind, stmt.bytes(1)) orelse return error.Corrupt;
            try out.append(arena, .{
                .id = try id(stmt, 0),
                .trigger = switch (kind) {
                    .before_clock_out => .{ .before_clock_out = stmt.int(2) },
                    .at_time => .{ .at_time = stmt.int(3) },
                },
                .enabled = stmt.int(4) != 0,
            });
        }
        return out.items;
    }

    /// Creates or replaces an alarm rule under an id the caller chose.
    pub fn putAlarmRule(self: *Store, rule: AlarmRule, now: i64) Error!void {
        const minutes: ?i64, const tod: ?i64 = switch (rule.trigger) {
            .before_clock_out => |m| .{ m, null },
            .at_time => |t| .{ null, t },
        };
        try self.db.exec(
            \\INSERT INTO alarm_rules (id, kind, minutes, time_of_day_secs, enabled, created_ts, updated_ts)
            \\VALUES (?, ?, ?, ?, ?, ?6, ?6)
            \\ON CONFLICT (id) DO UPDATE SET
            \\    kind = excluded.kind, minutes = excluded.minutes,
            \\    time_of_day_secs = excluded.time_of_day_secs, enabled = excluded.enabled,
            \\    updated_ts = excluded.updated_ts, deleted_ts = NULL
        , .{ blob(&rule.id), @tagName(rule.trigger), minutes, tod, rule.enabled, now });
    }

    pub fn setAlarmEnabled(self: *Store, rule_id: Uuid, enabled: bool, now: i64) Error!void {
        try self.db.exec(
            \\UPDATE alarm_rules SET enabled = ?, updated_ts = ? WHERE id = ? AND deleted_ts IS NULL
        , .{ enabled, now, blob(&rule_id) });
        if (self.db.changes() == 0) return error.NotFound;
    }

    pub fn deleteAlarmRule(self: *Store, rule_id: Uuid, now: i64) Error!void {
        try self.db.exec(
            \\UPDATE alarm_rules SET deleted_ts = ?, updated_ts = ?1 WHERE id = ? AND deleted_ts IS NULL
        , .{ now, blob(&rule_id) });
        if (self.db.changes() == 0) return error.NotFound;
    }

    /// A shared setting (`default_shift_secs`, `clock_out_link`, ...), if set.
    /// Allocated in `arena`.
    pub fn setting(self: *Store, arena: Allocator, key: []const u8) Error!?[]const u8 {
        var stmt = try self.db.prepare("SELECT value FROM settings WHERE key = ?");
        defer stmt.deinit();
        try stmt.bindAll(.{key});
        return if (try stmt.step()) try stmt.text(arena, 0) else null;
    }

    /// Sets a shared setting; null removes it.
    pub fn setSetting(self: *Store, key: []const u8, value: ?[]const u8, now: i64) Error!void {
        if (value) |v| try self.db.exec(
            \\INSERT INTO settings (key, value, updated_ts) VALUES (?, ?, ?)
            \\ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_ts = excluded.updated_ts
        , .{ key, v, now }) else try self.db.exec("DELETE FROM settings WHERE key = ?", .{key});
    }

    // ── Links to other tools ──────────────────────────────────────────────

    /// Points another tool's id (e.g. Situ's `project_id`) at a project, or
    /// re-points it if already linked.
    pub fn link(self: *Store, provider: []const u8, kind: []const u8, external_id: []const u8, target: Target, now: i64) Error!void {
        try self.begin();
        errdefer self.rollback();
        _ = try self.projectFor(target.project_id, target.workspace_id);

        const new: Uuid = .v7(self.io);
        try self.db.exec(
            \\INSERT INTO links (id, provider, kind, external_id, project_id, workspace_id,
            \\                   created_ts, updated_ts)
            \\VALUES (?, ?, ?, ?, ?, ?, ?7, ?7)
            \\ON CONFLICT (provider, kind, external_id) DO UPDATE SET
            \\    project_id = excluded.project_id, workspace_id = excluded.workspace_id,
            \\    updated_ts = excluded.updated_ts
        , .{ blob(&new), provider, kind, external_id, blob(&target.project_id), optBlob(&target.workspace_id), now });
        try self.commit();
    }

    /// What another tool's id is linked to, if anything.
    pub fn resolveLink(self: *Store, provider: []const u8, kind: []const u8, external_id: []const u8) Error!?Target {
        var stmt = try self.db.prepare(
            \\SELECT l.project_id, l.workspace_id FROM links l
            \\JOIN projects p ON p.id = l.project_id
            \\LEFT JOIN workspaces w ON w.id = l.workspace_id
            \\WHERE l.provider = ? AND l.kind = ? AND l.external_id = ?
            \\  AND p.deleted_ts IS NULL AND w.deleted_ts IS NULL
        );
        defer stmt.deinit();
        try stmt.bindAll(.{ provider, kind, external_id });
        if (!try stmt.step()) return null;
        return .{ .project_id = try id(stmt, 0), .workspace_id = try optId(stmt, 1) };
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
    _ = @import("ffi.zig");
    _ = @import("report.zig");
    _ = @import("tests.zig");
}
