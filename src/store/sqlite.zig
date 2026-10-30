//! A thin layer over the SQLite C API: just what the store uses. Failures
//! come back as errors and never get logged, so a frontend decides what to
//! show (a TUI can't have stray lines on stderr).

const std = @import("std");
const c = @import("c");

pub const Error = error{ Busy, Conflict, Corrupt, OutOfMemory, Io };

pub fn check(rc: c_int) Error!void {
    return switch (rc & 0xff) {
        c.SQLITE_OK, c.SQLITE_ROW, c.SQLITE_DONE => {},
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.Busy,
        c.SQLITE_CONSTRAINT => error.Conflict,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB => error.Corrupt,
        c.SQLITE_NOMEM => error.OutOfMemory,
        else => error.Io,
    };
}

/// Binds as a BLOB; a plain `[]const u8` binds as TEXT.
pub const Blob = struct { bytes: []const u8 };

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn open(path: [:0]const u8) Error!Db {
        var handle: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX;
        const rc = c.sqlite3_open_v2(path, &handle, flags, null);
        // A handle comes back even on failure, and must still be closed.
        errdefer _ = c.sqlite3_close(handle);
        try check(rc);
        return .{ .handle = handle orelse return error.OutOfMemory };
    }

    pub fn close(db: Db) void {
        _ = c.sqlite3_close(db.handle);
    }

    /// Runs one or more statements that take no parameters.
    pub fn execScript(db: Db, sql: [:0]const u8) Error!void {
        try check(c.sqlite3_exec(db.handle, sql, null, null, null));
    }

    /// Runs one statement to completion, binding `values` (a tuple) in order.
    pub fn exec(db: Db, sql: []const u8, values: anytype) Error!void {
        var stmt = try db.prepare(sql);
        defer stmt.deinit();
        try stmt.bindAll(values);
        while (try stmt.step()) {}
    }

    pub fn prepare(db: Db, sql: []const u8) Error!Stmt {
        var handle: ?*c.sqlite3_stmt = null;
        try check(c.sqlite3_prepare_v2(db.handle, sql.ptr, @intCast(sql.len), &handle, null));
        return .{ .handle = handle orelse return error.Io };
    }

    pub fn errmsg(db: Db) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(db.handle));
    }
};

pub const Stmt = struct {
    handle: *c.sqlite3_stmt,

    pub fn deinit(stmt: Stmt) void {
        _ = c.sqlite3_finalize(stmt.handle);
    }

    /// Binds a tuple of i64-ish ints, `[]const u8` (TEXT), `Blob`, optionals
    /// of those, and `null`. Bound data must outlive the statement's steps.
    pub fn bindAll(stmt: Stmt, values: anytype) Error!void {
        inline for (values, 1..) |v, i| try stmt.bind(i, v);
    }

    fn bind(stmt: Stmt, i: c_int, v: anytype) Error!void {
        const T = @TypeOf(v);
        const rc = switch (@typeInfo(T)) {
            .null => c.sqlite3_bind_null(stmt.handle, i),
            .optional => return if (v) |inner| stmt.bind(i, inner) else stmt.bind(i, null),
            .int, .comptime_int => c.sqlite3_bind_int64(stmt.handle, i, @intCast(v)),
            .bool => c.sqlite3_bind_int64(stmt.handle, i, @intFromBool(v)),
            else => if (T == Blob)
                c.sqlite3_bind_blob(stmt.handle, i, v.bytes.ptr, @intCast(v.bytes.len), null)
            else if (comptime isText(T)) blk: {
                const s: []const u8 = v;
                break :blk c.sqlite3_bind_text(stmt.handle, i, s.ptr, @intCast(s.len), null);
            } else @compileError("cannot bind " ++ @typeName(T)),
        };
        try check(rc);
    }

    fn isText(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .pointer => |p| switch (p.size) {
                .slice => p.child == u8,
                .one => switch (@typeInfo(p.child)) {
                    .array => |a| a.child == u8,
                    else => false,
                },
                else => false,
            },
            else => false,
        };
    }

    /// Advances to the next row; false once there are none.
    pub fn step(stmt: Stmt) Error!bool {
        const rc = c.sqlite3_step(stmt.handle);
        try check(rc);
        return rc == c.SQLITE_ROW;
    }

    pub fn isNull(stmt: Stmt, col: c_int) bool {
        return c.sqlite3_column_type(stmt.handle, col) == c.SQLITE_NULL;
    }

    pub fn int(stmt: Stmt, col: c_int) i64 {
        return c.sqlite3_column_int64(stmt.handle, col);
    }

    pub fn optInt(stmt: Stmt, col: c_int) ?i64 {
        return if (stmt.isNull(col)) null else stmt.int(col);
    }

    /// Valid until the next `step` or `deinit`; copy it to keep it.
    pub fn bytes(stmt: Stmt, col: c_int) []const u8 {
        // Ask for the pointer before the length, as SQLite documents.
        const ptr: ?[*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt.handle, col));
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt.handle, col));
        return if (ptr) |p| p[0..len] else "";
    }

    pub fn text(stmt: Stmt, gpa: std.mem.Allocator, col: c_int) error{OutOfMemory}![]const u8 {
        return gpa.dupe(u8, stmt.bytes(col));
    }

    pub fn optText(stmt: Stmt, gpa: std.mem.Allocator, col: c_int) error{OutOfMemory}!?[]const u8 {
        return if (stmt.isNull(col)) null else try stmt.text(gpa, col);
    }
};
