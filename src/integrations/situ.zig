//! Situ marks a repo with a committed `situ.toml` naming its project and
//! workspace. Shifty reads only those two ids and never depends on Situ:
//! they are looked up in the store's `links` table under this provider.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const provider = "situ";
pub const file_name = "situ.toml";

pub const Marker = struct {
    /// The directory holding `situ.toml`.
    root: []const u8,
    project_id: ?[]const u8 = null,
    workspace_id: ?[]const u8 = null,
};

/// The nearest `situ.toml` at or above `dir` (an absolute path), if any.
/// Allocated in `arena`.
pub fn find(io: Io, arena: Allocator, dir: []const u8) Allocator.Error!?Marker {
    var cur: ?[]const u8 = dir;
    while (cur) |d| : (cur = std.fs.path.dirname(d)) {
        const path = try std.fs.path.join(arena, &.{ d, file_name });
        const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        var m = parse(text);
        m.root = d;
        return m;
    }
    return null;
}

/// Reads top-level `project_id = "..."` and `workspace_id = "..."`. Just
/// enough TOML for those: anything under a `[table]` is someone else's.
pub fn parse(text: []const u8) Marker {
    var m: Marker = .{ .root = "" };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') break;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = stringValue(std.mem.trim(u8, line[eq + 1 ..], " \t")) orelse continue;
        if (std.mem.eql(u8, key, "project_id")) m.project_id = value;
        if (std.mem.eql(u8, key, "workspace_id")) m.workspace_id = value;
    }
    return m;
}

/// The contents of a basic or literal TOML string with no escapes, followed
/// by an optional comment.
fn stringValue(s: []const u8) ?[]const u8 {
    if (s.len < 2 or (s[0] != '"' and s[0] != '\'')) return null;
    const end = std.mem.indexOfScalarPos(u8, s, 1, s[0]) orelse return null;
    const value = s[1..end];
    if (value.len == 0 or std.mem.indexOfScalar(u8, value, '\\') != null) return null;
    const rest = std.mem.trim(u8, s[end + 1 ..], " \t");
    if (rest.len != 0 and rest[0] != '#') return null;
    return value;
}

const testing = std.testing;

test "parse - Situ's marker" {
    const m = parse(
        \\project_id = "01A0F5C4929E71CA888CD75111AC0F15"
        \\workspace_id = "01A0F5C4A1EE733BA7DC1D755BBA5662"
        \\
    );
    try testing.expectEqualStrings("01A0F5C4929E71CA888CD75111AC0F15", m.project_id.?);
    try testing.expectEqualStrings("01A0F5C4A1EE733BA7DC1D755BBA5662", m.workspace_id.?);
}

test "parse - comments, quoting, tables" {
    const m = parse(
        \\# a comment
        \\project_id='abc'   # trailing
        \\
        \\[visibility]
        \\workspace_id = "not top level"
    );
    try testing.expectEqualStrings("abc", m.project_id.?);
    try testing.expectEqual(null, m.workspace_id);
}

test "parse - ignores what it can't read" {
    const m = parse(
        \\project_id = 42
        \\workspace_id = "a\"b"
    );
    try testing.expectEqual(null, m.project_id);
    try testing.expectEqual(null, m.workspace_id);
}

test "find - walks up to the marker" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/src/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/situ.toml", .data = "project_id = \"p\"\n" });

    const base = try std.process.currentPathAlloc(io, a);
    const repo = try std.fs.path.join(a, &.{ base, ".zig-cache/tmp", &tmp.sub_path, "repo" });
    const deep = try std.fs.path.join(a, &.{ repo, "src/deep" });

    const m = (try find(io, a, deep)).?;
    try testing.expectEqualStrings(repo, m.root);
    try testing.expectEqualStrings("p", m.project_id.?);
}
