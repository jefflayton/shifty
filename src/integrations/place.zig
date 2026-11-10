//! Where you're working, and which project that means: a directory (a Situ
//! repo, a git repo, or any folder) and the app it's open in. Every frontend
//! asks this, so `shifty start` in a repo and the menu bar's auto-switch
//! agree. Places nothing links to mean nothing: no project, no change.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const store = @import("store");
const situ = @import("situ.zig");
const git = @import("git.zig");

/// What linked a place to its project, most specific first.
pub const Via = enum { situ, git, folder, app };

pub const folder_provider = "folder";
pub const folder_kind = "path";
pub const app_provider = "app";
pub const app_kind = "bundle";

pub const Place = struct {
    /// The Situ repo or git repo `dir` is in, if any.
    marker: ?situ.Marker = null,
    repo: ?git.Repo = null,
    /// The repo's top, else null: what to name it by.
    root: ?[]const u8 = null,
    /// What it's linked to, and how.
    target: ?store.Target = null,
    via: ?Via = null,
    /// The folder link that matched, when `via` is `folder`.
    folder: ?[]const u8 = null,
};

/// The project for working in `dir` (an absolute path) in the app with
/// bundle id `app`, either of which may be unknown. In order: the Situ
/// repo's link, the git remote's, the nearest linked folder at or above
/// `dir`, then the app's.
pub fn resolve(db: *store.Store, io: Io, arena: Allocator, dir: ?[]const u8, app: ?[]const u8) store.Error!Place {
    var p: Place = .{};
    if (dir) |d| {
        p.marker = try situ.find(io, arena, d);
        p.repo = try git.find(io, arena, d);
        p.root = if (p.marker) |m| m.root else if (p.repo) |r| r.root else null;

        if (p.marker) |m| if (try situ.linked(db, m)) |t| return found(p, t, .situ);
        if (p.repo) |r| if (r.remote) |remote| {
            if (try db.resolveLink(git.provider, git.kind_remote, remote)) |t| return found(p, t, .git);
        };
        var cur: ?[]const u8 = std.mem.trimEnd(u8, d, "/");
        while (cur) |c| : (cur = std.fs.path.dirname(c)) {
            const key = if (c.len == 0) "/" else c;
            if (try db.resolveLink(folder_provider, folder_kind, key)) |t| {
                p.folder = key;
                return found(p, t, .folder);
            }
            if (c.len == 0) break;
        }
    }
    if (app) |a| if (a.len > 0) {
        if (try db.resolveLink(app_provider, app_kind, a)) |t| return found(p, t, .app);
    };
    return p;
}

fn found(p: Place, t: store.Target, via: Via) Place {
    var out = p;
    out.target = t;
    out.via = via;
    return out;
}

pub const LinkError = store.Error || Allocator.Error || error{NoWorkspaceId};

/// Links the place `dir` is in to `target`, by the sturdiest id it has: its
/// Situ ids, else its git remote, else the folder (the repo's top, or `dir`
/// itself). Returns which.
pub fn linkDir(db: *store.Store, io: Io, arena: Allocator, dir: []const u8, target: store.Target, now: i64) LinkError!Via {
    if (try situ.find(io, arena, dir)) |m| if (m.project_id != null) {
        situ.link(db, m, target, now) catch |e| switch (e) {
            error.NoProjectId => unreachable,
            else => |other| return other,
        };
        return .situ;
    };
    const repo = try git.find(io, arena, dir);
    if (repo) |r| if (r.remote) |remote| {
        try db.link(git.provider, git.kind_remote, remote, target, now);
        return .git;
    };
    const path = if (repo) |r| r.root else std.mem.trimEnd(u8, dir, "/");
    try db.link(folder_provider, folder_kind, if (path.len == 0) "/" else path, target, now);
    return .folder;
}

/// Links an app, by bundle id, to `target`.
pub fn linkApp(db: *store.Store, bundle_id: []const u8, target: store.Target, now: i64) store.Error!void {
    try db.link(app_provider, app_kind, bundle_id, target, now);
}

const testing = std.testing;

test "resolve / linkDir - remote, folder, app, nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var db: store.Store = try .open(io, ":memory:");
    defer db.deinit();
    const web = try db.createProject(.{ .name = "web" }, 0);
    const notes = try db.createProject(.{ .name = "notes" }, 0);
    const chat = try db.createProject(.{ .name = "chat" }, 0);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "web/.git");
    try tmp.dir.createDirPath(io, "web/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "web/.git/config", .data = "[remote \"origin\"]\n\turl = https://github.com/o/web.git\n" });
    try tmp.dir.createDirPath(io, "local/.git");
    try tmp.dir.createDirPath(io, "local/a/b");
    const base = try std.process.currentPathAlloc(io, a);
    const top = try std.fs.path.join(a, &.{ base, ".zig-cache/tmp", &tmp.sub_path });
    const web_src = try std.fs.path.join(a, &.{ top, "web/src" });
    const local_b = try std.fs.path.join(a, &.{ top, "local/a/b" });

    // Nothing linked: the repo is known, the project isn't.
    var p = try resolve(&db, io, a, web_src, "com.example.editor");
    try testing.expectEqual(null, p.target);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ top, "web" }), p.root.?);

    try testing.expectEqual(Via.git, try linkDir(&db, io, a, web_src, .{ .project_id = web }, 1));
    try testing.expectEqual(Via.folder, try linkDir(&db, io, a, local_b, .{ .project_id = notes }, 1));
    try linkApp(&db, "com.example.chat", .{ .project_id = chat }, 1);

    p = try resolve(&db, io, a, web_src, "com.example.chat");
    try testing.expectEqual(Via.git, p.via.?);
    try testing.expect(p.target.?.project_id.eql(web));

    // A repo without a remote links by its top, from anywhere inside.
    p = try resolve(&db, io, a, try std.fs.path.join(a, &.{ top, "local/a" }), null);
    try testing.expectEqual(Via.folder, p.via.?);
    try testing.expect(p.target.?.project_id.eql(notes));
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ top, "local" }), p.folder.?);

    // No directory, or one nothing links: the app decides.
    p = try resolve(&db, io, a, null, "com.example.chat");
    try testing.expectEqual(Via.app, p.via.?);
    try testing.expect(p.target.?.project_id.eql(chat));
    p = try resolve(&db, io, a, null, "com.example.browser");
    try testing.expectEqual(null, p.target);
}

test "resolve - a linked Situ repo beats its git remote" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var db: store.Store = try .open(io, ":memory:");
    defer db.deinit();
    const web = try db.createProject(.{ .name = "web" }, 0);
    const other = try db.createProject(.{ .name = "other" }, 0);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "r/.git");
    try tmp.dir.writeFile(io, .{ .sub_path = "r/.git/config", .data = "[remote \"origin\"]\n\turl = git@h:o/r\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "r/situ.toml", .data = "project_id = \"P\"\n" });
    const base = try std.process.currentPathAlloc(io, a);
    const r = try std.fs.path.join(a, &.{ base, ".zig-cache/tmp", &tmp.sub_path, "r" });

    try db.link(git.provider, git.kind_remote, "h/o/r", .{ .project_id = other }, 0);
    try testing.expect((try resolve(&db, io, a, r, null)).target.?.project_id.eql(other));

    try testing.expectEqual(Via.situ, try linkDir(&db, io, a, r, .{ .project_id = web }, 1));
    const p = try resolve(&db, io, a, r, null);
    try testing.expectEqual(Via.situ, p.via.?);
    try testing.expect(p.target.?.project_id.eql(web));
}
