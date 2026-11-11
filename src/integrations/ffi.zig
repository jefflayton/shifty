//! Places and links through the C API (see shifty.h), on a store handle:
//! what the menu bar's auto-switch asks.

const std = @import("std");

const store = @import("store");
const Uuid = @FieldType(store.Target, "project_id");
const sffi = store.ffi;
const Handle = sffi.Handle;
const Id = sffi.Id;
const Result = sffi.Result;
const gpa = sffi.gpa;

const git = @import("git.zig");
const place = @import("place.zig");
const here = @import("here.zig");

/// `place.Place` for the app: what to call it and what it's linked to.
const PlaceJson = struct {
    via: ?place.Via,
    project_id: ?Uuid,
    workspace_id: ?Uuid,
    /// The Situ or git repo's top.
    root: ?[]const u8,
    remote: ?[]const u8,
    /// The linked folder that matched.
    folder: ?[]const u8,
    /// The keyword in the title that picked the project, when `via` is
    /// `keyword`.
    keyword: ?[]const u8,
    /// How many projects it could have been.
    choices: usize,
    /// Whether there's a Situ repo here with ids to link by.
    situ: bool,
};

fn writeJson(value: anytype, out: *?[*]u8, len: *usize) Result {
    const json = std.json.Stringify.valueAlloc(gpa, value, .{}) catch return .no_memory;
    out.* = json.ptr;
    len.* = json.len;
    return .ok;
}

/// Writes the place for `dir` (absolute) in the app `bundle_id`, whose
/// window is titled `title`, any possibly null, as UTF-8 JSON; release it
/// with `shifty_free`.
export fn shifty_place_json(h: *Handle, dir: ?[*:0]const u8, bundle_id: ?[*:0]const u8, title: ?[*:0]const u8, out: *?[*]u8, len: *usize) Result {
    out.* = null;
    len.* = 0;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const p = place.resolve(&h.store, h.threaded.io(), arena.allocator(), sffi.optStr(dir), sffi.optStr(bundle_id), sffi.optStr(title)) catch |e| return sffi.result(e);
    return writeJson(PlaceJson{
        .via = p.via,
        .project_id = if (p.target) |t| t.project_id else null,
        .workspace_id = if (p.target) |t| t.workspace_id else null,
        .root = p.root,
        .remote = if (p.repo) |r| r.remote else null,
        .folder = p.folder,
        .keyword = p.keyword,
        .choices = p.choices,
        .situ = if (p.marker) |m| m.project_id != null else false,
    }, out, len);
}

/// Links the repo or folder `dir` is in (see `place.linkDir`); `via` gets
/// what it linked by (`ShiftyVia`). Mismatch if the workspace isn't the
/// project's, or the Situ repo has no workspace id to link one by.
export fn shifty_link_dir(h: *Handle, dir: [*:0]const u8, project_id: Id, workspace_id: ?*const Id, now: i64, via: *i32) Result {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const target: store.Target = .{ .project_id = sffi.id(project_id), .workspace_id = sffi.optId(workspace_id) };
    const v = place.linkDir(&h.store, h.threaded.io(), arena.allocator(), std.mem.span(dir), target, now) catch |e| switch (e) {
        error.NoWorkspaceId => return .mismatch,
        else => return sffi.result(e),
    };
    via.* = @intFromEnum(v);
    return .ok;
}

export fn shifty_link_app(h: *Handle, bundle_id: [*:0]const u8, project_id: Id, workspace_id: ?*const Id, now: i64) Result {
    const target: store.Target = .{ .project_id = sffi.id(project_id), .workspace_id = sffi.optId(workspace_id) };
    place.linkApp(&h.store, std.mem.span(bundle_id), target, now) catch |e| return sffi.result(e);
    return .ok;
}

/// Links a keyword to a project: a window titled with it is that project's.
/// Mismatch if it can't be a keyword (empty, too long, a line break).
export fn shifty_link_keyword(h: *Handle, word: [*:0]const u8, project_id: Id, workspace_id: ?*const Id, now: i64) Result {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const target: store.Target = .{ .project_id = sffi.id(project_id), .workspace_id = sffi.optId(workspace_id) };
    const kept = place.linkKeyword(&h.store, arena.allocator(), std.mem.span(word), target, now) catch |e| return sffi.result(e);
    return if (kept == null) .mismatch else .ok;
}

/// Removes a link, as `shifty_links_json` names it: to `project_id`, or
/// to every project (null). NotFound if there's none.
export fn shifty_unlink(h: *Handle, provider: [*:0]const u8, kind: [*:0]const u8, external_id: [*:0]const u8, project_id: ?*const Id, now: i64) Result {
    const pid: ?Uuid = if (project_id) |p| sffi.id(p.*) else null;
    h.store.unlink(std.mem.span(provider), std.mem.span(kind), std.mem.span(external_id), pid, now) catch |e| return sffi.result(e);
    return .ok;
}

const LinkJson = struct {
    provider: []const u8,
    kind: []const u8,
    external_id: []const u8,
    project_id: Uuid,
    workspace_id: ?Uuid,
};

/// Writes every link as UTF-8 JSON; release it with `shifty_free`.
export fn shifty_links_json(h: *Handle, out: *?[*]u8, len: *usize) Result {
    out.* = null;
    len.* = 0;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const links = h.store.links(a) catch |e| return sffi.result(e);
    const rows = a.alloc(LinkJson, links.len) catch return .no_memory;
    for (links, rows) |l, *r| r.* = .{
        .provider = l.provider,
        .kind = l.kind,
        .external_id = l.external_id,
        .project_id = l.target.project_id,
        .workspace_id = l.target.workspace_id,
    };
    return writeJson(rows, out, len);
}

/// Writes the path of the shell hook's record (see here.zig) into `buf`,
/// NUL-terminated, so the app can watch it.
export fn shifty_here_path(h: *Handle, buf: [*]u8, cap: usize) Result {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const p = here.pathFor(arena.allocator(), h.path) catch return .no_memory;
    if (p.len + 1 > cap) return .no_memory;
    @memcpy(buf[0..p.len], p);
    buf[p.len] = 0;
    return .ok;
}

/// Writes the shell hook's record, newest first, as UTF-8 JSON; release it
/// with `shifty_free`.
export fn shifty_here_json(h: *Handle, out: *?[*]u8, len: *usize) Result {
    out.* = null;
    len.* = 0;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const spots = here.read(h.threaded.io(), a, here.pathFor(a, h.path) catch return .no_memory) catch return .no_memory;
    return writeJson(spots, out, len);
}

const testing = std.testing;

test "C API - place, link, unlink" {
    var hp: ?*Handle = null;
    try testing.expectEqual(Result.ok, sffi.shifty_store_open(":memory:", &hp));
    defer sffi.shifty_store_close(hp);
    const h = hp.?;

    const web = try h.store.createProject(.{ .name = "web" }, 0);
    const pid: Id = .{ .bytes = web.bytes };
    try testing.expectEqual(Result.ok, shifty_link_app(h, "com.example.chat", pid, null, 1));

    var out: ?[*]u8 = null;
    var len: usize = 0;
    try testing.expectEqual(Result.ok, shifty_place_json(h, null, "com.example.chat", null, &out, &len));
    const json = out.?[0..len];
    defer sffi.shifty_free(out, len);
    try testing.expect(std.mem.indexOf(u8, json, "\"via\":\"app\"") != null);

    var out2: ?[*]u8 = null;
    var len2: usize = 0;
    try testing.expectEqual(Result.ok, shifty_links_json(h, &out2, &len2));
    const links = out2.?[0..len2];
    defer sffi.shifty_free(out2, len2);
    try testing.expect(std.mem.indexOf(u8, links, "\"external_id\":\"com.example.chat\"") != null);

    try testing.expectEqual(Result.ok, shifty_link_keyword(h, "Chat", pid, null, 2));
    try testing.expectEqual(Result.mismatch, shifty_link_keyword(h, "  ", pid, null, 2));
    var out3: ?[*]u8 = null;
    var len3: usize = 0;
    try testing.expectEqual(Result.ok, shifty_place_json(h, null, null, "Team chat", &out3, &len3));
    const kw = out3.?[0..len3];
    defer sffi.shifty_free(out3, len3);
    try testing.expect(std.mem.indexOf(u8, kw, "\"via\":\"keyword\"") != null);
    try testing.expect(std.mem.indexOf(u8, kw, "\"keyword\":\"chat\"") != null);

    const other: Id = .{ .bytes = (try h.store.createProject(.{ .name = "other" }, 0)).bytes };
    try testing.expectEqual(Result.not_found, shifty_unlink(h, "app", "bundle", "com.example.chat", &other, 2));
    try testing.expectEqual(Result.ok, shifty_unlink(h, "app", "bundle", "com.example.chat", &pid, 2));
    try testing.expectEqual(Result.not_found, shifty_unlink(h, "app", "bundle", "com.example.chat", null, 3));

    var buf: [1024]u8 = undefined;
    try testing.expectEqual(Result.ok, shifty_here_path(h, &buf, buf.len));
    try testing.expect(std.mem.endsWith(u8, std.mem.span(@as([*:0]u8, @ptrCast(&buf))), "here.tsv"));
}
