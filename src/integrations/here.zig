//! Which directory each shell is in, for apps that can't tell: a terminal's
//! window doesn't say what folder it's in. A shell hook runs `shifty here`
//! at every prompt (see `hook`), which records the shell, its directory, and
//! the terminal; the menu bar app reads the record for the terminal in
//! front.
//!
//! The record is `here.tsv` next to the database: one line per shell,
//! newest first, `ts \t pid \t bundle \t term \t dir`. `pid` is the shell's
//! (or Neovim's): the app walks up from it to the app that owns it. `bundle`
//! is `$__CFBundleIdentifier` and `term` is `$TERM_PROGRAM`, for when it
//! can't (in tmux, say). A missing field is empty.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const file_name = "here.tsv";

/// Shells quiet for this long drop off the record.
pub const keep_secs = 24 * std.time.s_per_hour;
/// And it never holds more than this many.
pub const max_spots = 32;

pub const Spot = struct {
    ts: i64,
    pid: i32,
    bundle: []const u8 = "",
    term: []const u8 = "",
    dir: []const u8,
};

/// `here.tsv` beside the database at `db_path`.
pub fn pathFor(arena: Allocator, db_path: []const u8) Allocator.Error![]const u8 {
    const dir = std.fs.path.dirname(db_path) orelse ".";
    return std.fs.path.join(arena, &.{ dir, file_name });
}

/// The record's lines, newest first. Skips lines it can't read.
pub fn parse(arena: Allocator, text: []const u8) Allocator.Error![]Spot {
    var out: std.ArrayList(Spot) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, '\t');
        const ts = std.fmt.parseInt(i64, f.next() orelse continue, 10) catch continue;
        const pid = std.fmt.parseInt(i32, f.next() orelse continue, 10) catch continue;
        const bundle = f.next() orelse continue;
        const term = f.next() orelse continue;
        const dir = f.rest();
        if (dir.len == 0) continue;
        try out.append(arena, .{ .ts = ts, .pid = pid, .bundle = bundle, .term = term, .dir = dir });
    }
    return out.toOwnedSlice(arena);
}

/// Reads the record at `path`; empty if there's none.
pub fn read(io: Io, arena: Allocator, path: []const u8) Allocator.Error![]Spot {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    return parse(arena, text);
}

/// `spots` with `new` in front, in place of its shell's old line, without
/// stale or excess lines.
pub fn updated(arena: Allocator, spots: []const Spot, new: Spot) Allocator.Error![]Spot {
    var out: std.ArrayList(Spot) = .empty;
    try out.append(arena, new);
    for (spots) |s| {
        if (out.items.len == max_spots) break;
        if (s.pid == new.pid or new.ts - s.ts > keep_secs) continue;
        try out.append(arena, s);
    }
    return out.toOwnedSlice(arena);
}

pub fn format(arena: Allocator, spots: []const Spot) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (spots) |s| out.writer.print("{d}\t{d}\t{s}\t{s}\t{s}\n", .{ s.ts, s.pid, s.bundle, s.term, s.dir }) catch return error.OutOfMemory;
    return out.written();
}

/// Whether a field can go in the record as is.
pub fn fits(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "\t\n\r") == null;
}

/// Records `new` in the record at `path`, replacing the file in one step so
/// a reader never sees half of it. Fields that don't fit are left out.
pub fn record(io: Io, arena: Allocator, path: []const u8, new: Spot) !void {
    if (!fits(new.dir) or new.dir.len == 0) return;
    var clean = new;
    if (!fits(clean.bundle)) clean.bundle = "";
    if (!fits(clean.term)) clean.term = "";

    const text = try format(arena, try updated(arena, try read(io, arena, path), clean));
    if (std.fs.path.dirname(path)) |d| try Io.Dir.cwd().createDirPath(io, d);
    const tmp = try std.fmt.allocPrint(arena, "{s}.{d}.tmp", .{ path, new.pid });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = text });
    errdefer Io.Dir.cwd().deleteFile(io, tmp) catch {};
    try Io.Dir.cwd().rename(tmp, .cwd(), path, io);
}

pub const Shell = enum { fish, zsh, bash, nvim };

/// The lines to add to a shell's config so it runs `exe here` at every
/// prompt, in the background so a prompt never waits on it. Neovim's runs it
/// for the file you're in, so switching buffers between repos counts.
pub fn hook(arena: Allocator, shell: Shell, exe: []const u8) Allocator.Error![]const u8 {
    return switch (shell) {
        .fish => std.fmt.allocPrint(arena,
            \\function __shifty_here --on-event fish_prompt
            \\    command '{0s}' here --pid $fish_pid &>/dev/null &
            \\    disown 2>/dev/null
            \\end
            \\
        , .{exe}),
        .zsh => std.fmt.allocPrint(arena,
            \\__shifty_here() {{ ( '{0s}' here --pid $$ &>/dev/null & ) }}
            \\typeset -ag precmd_functions
            \\(( ${{precmd_functions[(I)__shifty_here]}} )) || precmd_functions+=(__shifty_here)
            \\
        , .{exe}),
        .bash => std.fmt.allocPrint(arena,
            \\__shifty_here() {{ ( '{0s}' here --pid $$ &>/dev/null & ) }}
            \\[[ ";${{PROMPT_COMMAND[*]}};" == *";__shifty_here;"* ]] || PROMPT_COMMAND="__shifty_here${{PROMPT_COMMAND:+;$PROMPT_COMMAND}}"
            \\
        , .{exe}),
        .nvim => std.fmt.allocPrint(arena,
            \\vim.api.nvim_create_autocmd({{ "VimEnter", "BufEnter", "DirChanged", "FocusGained" }}, {{
            \\  group = vim.api.nvim_create_augroup("shifty_here", {{ clear = true }}),
            \\  callback = function()
            \\    local dir = vim.fn.expand("%:p:h")
            \\    if vim.bo.buftype ~= "" or vim.fn.isdirectory(dir) == 0 then dir = vim.fn.getcwd() end
            \\    vim.fn.jobstart({{ '{0s}', "here", "--pid", tostring(vim.fn.getpid()), dir }}, {{ detach = true }})
            \\  end,
            \\}})
            \\
        , .{exe}),
    };
}

const testing = std.testing;

test "updated - newest first, one line per shell, stale ones dropped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = [_]Spot{
        .{ .ts = 100, .pid = 2, .dir = "/b" },
        .{ .ts = 90, .pid = 1, .dir = "/a" },
        .{ .ts = 100 - keep_secs, .pid = 3, .dir = "/stale" },
    };
    const now = try updated(a, &old, .{ .ts = 110, .pid = 1, .dir = "/a2" });
    try testing.expectEqual(2, now.len);
    try testing.expectEqualStrings("/a2", now[0].dir);
    try testing.expectEqualStrings("/b", now[1].dir);
}

test "format / parse - round trip, bad lines skipped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try format(a, &.{
        .{ .ts = 5, .pid = 42, .bundle = "com.mitchellh.ghostty", .term = "ghostty", .dir = "/Users/me/dev/web" },
        .{ .ts = 4, .pid = 43, .dir = "/tmp" },
    });
    const spots = try parse(a, try std.mem.concat(a, u8, &.{ text, "junk\n7\tx\t\t\t/d\n" }));
    try testing.expectEqual(2, spots.len);
    try testing.expectEqual(42, spots[0].pid);
    try testing.expectEqualStrings("com.mitchellh.ghostty", spots[0].bundle);
    try testing.expectEqualStrings("/Users/me/dev/web", spots[0].dir);
    try testing.expectEqualStrings("", spots[1].term);
}

test "record - creates, then replaces the shell's line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.process.currentPathAlloc(io, a);
    const path = try std.fs.path.join(a, &.{ base, ".zig-cache/tmp", &tmp.sub_path, "Shifty", file_name });

    try record(io, a, path, .{ .ts = 1, .pid = 7, .term = "rex", .dir = "/one" });
    try record(io, a, path, .{ .ts = 2, .pid = 8, .dir = "/two" });
    try record(io, a, path, .{ .ts = 3, .pid = 7, .term = "rex", .dir = "/three" });
    try record(io, a, path, .{ .ts = 4, .pid = 9, .dir = "/no\ttabs" });
    const spots = try read(io, a, path);
    try testing.expectEqual(2, spots.len);
    try testing.expectEqualStrings("/three", spots[0].dir);
    try testing.expectEqualStrings("rex", spots[0].term);
    try testing.expectEqualStrings("/two", spots[1].dir);
}

test "hook - names the executable" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]Shell{ .fish, .zsh, .bash, .nvim }) |sh| {
        const h = try hook(a, sh, "/opt/bin/shifty");
        try testing.expect(std.mem.indexOf(u8, h, "'/opt/bin/shifty'") != null);
    }
}
