//! Git repos, found by their `.git` and named by their origin remote, so a
//! repo links to a project the same way on every clone. Reads git's files
//! directly; never runs git.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const provider = "git";
/// A remote's URL as `normalizeRemote` writes it.
pub const kind_remote = "remote";

pub const Repo = struct {
    /// The working tree's top: the directory holding `.git`.
    root: []const u8,
    /// Its origin (or its first remote), normalized, if it has one.
    remote: ?[]const u8,
};

/// The repo at or above `dir` (an absolute path), if any. Allocated in
/// `arena`.
pub fn find(io: Io, arena: Allocator, dir: []const u8) Allocator.Error!?Repo {
    var cur: ?[]const u8 = dir;
    while (cur) |d| : (cur = std.fs.path.dirname(d)) {
        const dot_git = try std.fs.path.join(arena, &.{ d, ".git" });
        const stat = Io.Dir.cwd().statFile(io, dot_git, .{}) catch continue;
        const git_dir = switch (stat.kind) {
            .directory => dot_git,
            // A worktree or submodule: `gitdir: <path>`.
            .file => try pointedTo(io, arena, d, dot_git, "gitdir:") orelse continue,
            else => continue,
        };
        // A worktree keeps its config in the main repo's git dir.
        const common = try pointedTo(io, arena, git_dir, try std.fs.path.join(arena, &.{ git_dir, "commondir" }), "") orelse git_dir;
        const config_path = try std.fs.path.join(arena, &.{ common, "config" });
        const config = Io.Dir.cwd().readFileAlloc(io, config_path, arena, .limited(256 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => "",
        };
        const remote = if (remoteUrl(config)) |url| try normalizeRemote(arena, url) else null;
        return .{ .root = d, .remote = remote };
    }
    return null;
}

/// The path a one-line pointer file names after `prefix`, resolved against
/// `base`. Null if the file can't be read.
fn pointedTo(io: Io, arena: Allocator, base: []const u8, file: []const u8, prefix: []const u8) Allocator.Error!?[]const u8 {
    const text = Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(4096)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const line = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const p = std.mem.trim(u8, line[prefix.len..], " \t");
    if (p.len == 0) return null;
    return try std.fs.path.resolve(arena, &.{ base, p });
}

/// The URL of `[remote "origin"]` in a git config, else of the first remote.
pub fn remoteUrl(config: []const u8) ?[]const u8 {
    var first: ?[]const u8 = null;
    var section: enum { other, origin, remote } = .other;
    var lines = std.mem.splitScalar(u8, config, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            section = if (std.mem.startsWith(u8, line, "[remote \"origin\"]"))
                .origin
            else if (std.mem.startsWith(u8, line, "[remote "))
                .remote
            else
                .other;
            continue;
        }
        if (section == .other) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), "url")) continue;
        const url = std.mem.trim(u8, line[eq + 1 ..], " \t\"");
        if (url.len == 0) continue;
        if (section == .origin) return url;
        if (first == null) first = url;
    }
    return first;
}

/// `host/path` with no scheme, user, port, or `.git`, and the host in lower
/// case, so the SSH and HTTPS URLs of a repo match:
/// `git@github.com:o/r.git` and `https://github.com/o/r` are both
/// `github.com/o/r`. A local path stays as it is.
pub fn normalizeRemote(arena: Allocator, url: []const u8) Allocator.Error![]const u8 {
    var rest = url;
    var scp = false;
    if (std.mem.indexOf(u8, rest, "://")) |i| {
        if (std.mem.eql(u8, rest[0..i], "file")) return arena.dupe(u8, rest[i + 3 ..]);
        rest = rest[i + 3 ..];
    } else if (rest.len > 0 and (rest[0] == '/' or rest[0] == '.')) {
        return arena.dupe(u8, rest);
    } else scp = true;

    // user@
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    if (std.mem.lastIndexOfScalar(u8, rest[0..slash], '@')) |at| rest = rest[at + 1 ..];

    // host, then `:port/`, or scp-like `host:path`
    const host_end = std.mem.indexOfAny(u8, rest, ":/") orelse rest.len;
    const host = rest[0..host_end];
    var path = rest[host_end..];
    if (path.len > 0 and path[0] == ':') {
        path = path[1..];
        if (!scp) {
            const digits = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
            path = path[digits..];
        }
    }
    path = std.mem.trim(u8, path, "/");
    if (std.mem.endsWith(u8, path, ".git")) path = path[0 .. path.len - 4];
    path = std.mem.trimEnd(u8, path, "/");

    const out = try std.fmt.allocPrint(arena, "{s}/{s}", .{ host, path });
    for (out[0..host.len]) |*ch| ch.* = std.ascii.toLower(ch.*);
    return out;
}

const testing = std.testing;

test "normalizeRemote - SSH and HTTPS agree" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const want = "github.com/jefflayton/shifty";
    for ([_][]const u8{
        "git@github.com:jefflayton/shifty.git",
        "https://github.com/jefflayton/shifty",
        "https://github.com/jefflayton/shifty.git/",
        "https://user:token@GitHub.com/jefflayton/shifty.git",
        "ssh://git@github.com:22/jefflayton/shifty.git",
        "ssh://github.com/jefflayton/shifty",
        "github.com:jefflayton/shifty",
    }) |url| try testing.expectEqualStrings(want, try normalizeRemote(a, url));
    try testing.expectEqualStrings("/srv/repos/x.git", try normalizeRemote(a, "/srv/repos/x.git"));
    try testing.expectEqualStrings("/srv/x", try normalizeRemote(a, "file:///srv/x"));
}

test "remoteUrl - origin first, else the first remote" {
    try testing.expectEqualStrings("git@h:o/r.git", remoteUrl(
        \\[core]
        \\    bare = false
        \\[remote "upstream"]
        \\    url = https://h/up/r
        \\[remote "origin"]
        \\    url = git@h:o/r.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
    ).?);
    try testing.expectEqualStrings("https://h/up/r", remoteUrl(
        \\[remote "upstream"]
        \\    url = https://h/up/r
        \\[branch "main"]
        \\    url = not-a-remote
    ).?);
    try testing.expectEqual(null, remoteUrl("[core]\n\tbare = false\n"));
}

test "find - repo, worktree, no remote" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/.git");
    try tmp.dir.createDirPath(io, "repo/src/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.git/config", .data = "[remote \"origin\"]\n\turl = git@github.com:o/r.git\n" });
    // A worktree of it, elsewhere.
    try tmp.dir.createDirPath(io, "repo/.git/worktrees/wt");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.git/worktrees/wt/commondir", .data = "../..\n" });
    try tmp.dir.createDirPath(io, "wt/sub");
    // A repo with no remote.
    try tmp.dir.createDirPath(io, "local/.git");

    const base = try std.process.currentPathAlloc(io, a);
    const top = try std.fs.path.join(a, &.{ base, ".zig-cache/tmp", &tmp.sub_path });
    const wt_git = try std.fs.path.join(a, &.{ top, "repo/.git/worktrees/wt" });
    try tmp.dir.writeFile(io, .{ .sub_path = "wt/.git", .data = try std.fmt.allocPrint(a, "gitdir: {s}\n", .{wt_git}) });

    const r = (try find(io, a, try std.fs.path.join(a, &.{ top, "repo/src/deep" }))).?;
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ top, "repo" }), r.root);
    try testing.expectEqualStrings("github.com/o/r", r.remote.?);

    const w = (try find(io, a, try std.fs.path.join(a, &.{ top, "wt/sub" }))).?;
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ top, "wt" }), w.root);
    try testing.expectEqualStrings("github.com/o/r", w.remote.?);

    const l = (try find(io, a, try std.fs.path.join(a, &.{ top, "local" }))).?;
    try testing.expectEqual(null, l.remote);
}
