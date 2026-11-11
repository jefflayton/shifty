//! Which Rex tab and session you're on, for when the window can't say: a
//! Rex session on a remote host runs its shells there, so the prompt hook
//! (`here.zig`) never reaches this Mac, and switching side tabs prints no
//! prompt anyway.
//!
//! A Lua script run with `rex do` (see `script`) listens to a Rex server's
//! events. `rex do` runs a script where the `rex` CLI is, so run on this Mac
//! it hears a remote host's tab and session changes and calls this Mac's
//! `shifty rex`, which records them here. The menu bar app matches keywords
//! in what it records, as it does in window titles.
//!
//! The record is `rex.tsv` next to the database: one line,
//! `ts \t server \t session \t window`, the session's and the tab's labels.
//! A missing field is empty.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const file_name = "rex.tsv";

/// A record older than this says nothing: whatever wrote it has stopped.
pub const keep_secs = 24 * std.time.s_per_hour;

/// Rex's app, whose windows this is about.
pub const bundle_id = "com.superlogical.rex";

pub const Focus = struct {
    ts: i64,
    /// The host's label from `rex hosts`, or empty for this Mac's server.
    server: []const u8 = "",
    /// The session's label and the tab's (Rex calls a tab a window).
    session: []const u8 = "",
    window: []const u8 = "",
};

/// `rex.tsv` beside the database at `db_path`.
pub fn pathFor(arena: Allocator, db_path: []const u8) Allocator.Error![]const u8 {
    const dir = std.fs.path.dirname(db_path) orelse ".";
    return std.fs.path.join(arena, &.{ dir, file_name });
}

/// The record's line, or null if it has none it can read.
pub fn parse(text: []const u8) ?Focus {
    const line = std.mem.trimEnd(u8, text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len], "\r");
    var f = std.mem.splitScalar(u8, line, '\t');
    const ts = std.fmt.parseInt(i64, f.next() orelse return null, 10) catch return null;
    const server = f.next() orelse return null;
    const session = f.next() orelse return null;
    const window = f.rest();
    if (session.len == 0 and window.len == 0) return null;
    return .{ .ts = ts, .server = server, .session = session, .window = window };
}

pub fn format(arena: Allocator, focus: Focus) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{d}\t{s}\t{s}\t{s}\n", .{ focus.ts, focus.server, focus.session, focus.window });
}

/// Reads the record at `path`; null if there's none.
pub fn read(io: Io, arena: Allocator, path: []const u8) Allocator.Error!?Focus {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return parse(text);
}

/// The record at `path` if it's from the last `keep_secs` before `now`.
pub fn current(io: Io, arena: Allocator, path: []const u8, now: i64) Allocator.Error!?Focus {
    const f = try read(io, arena, path) orelse return null;
    if (now - f.ts > keep_secs) return null;
    return f;
}

/// `s` as it can go in the record: tabs and line breaks become spaces.
fn clean(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    const out = try arena.dupe(u8, s);
    for (out) |*c| if (c.* == '\t' or c.* == '\n' or c.* == '\r') {
        c.* = ' ';
    };
    return std.mem.trim(u8, out, " ");
}

/// Records `new` at `path`, replacing the file in one step so a reader
/// never sees half of it.
pub fn record(io: Io, arena: Allocator, path: []const u8, new: Focus) !void {
    const text = try format(arena, .{
        .ts = new.ts,
        .server = try clean(arena, new.server),
        .session = try clean(arena, new.session),
        .window = try clean(arena, new.window),
    });
    if (std.fs.path.dirname(path)) |d| try Io.Dir.cwd().createDirPath(io, d);
    const tmp = try std.fmt.allocPrint(arena, "{s}.{d}.tmp", .{ path, std.c.getpid() });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = text });
    errdefer Io.Dir.cwd().deleteFile(io, tmp) catch {};
    try Io.Dir.cwd().rename(tmp, .cwd(), path, io);
}

/// What Rex's own title would say, "tab - session", to match keywords in.
/// Either may be missing.
pub fn title(arena: Allocator, focus: Focus) Allocator.Error![]const u8 {
    if (focus.window.len == 0) return arena.dupe(u8, focus.session);
    if (focus.session.len == 0) return arena.dupe(u8, focus.window);
    return std.fmt.allocPrint(arena, "{s} - {s}", .{ focus.window, focus.session });
}

/// The Lua script for `rex do`, calling `exe rex` whenever the tab or
/// session you're on changes. Run it on this Mac, once for each Rex server:
///
///     rex do shifty.lua --all
///     rex -S <host> do shifty.lua --all server=<host>
///
/// `--all` hears every session, sessions made later too. A tab you switch
/// to is the session's active window (`active_window_changed`); a session
/// you switch to gets the app as a client (`client_connected`). Labels
/// changing count too. It tells Shifty only when what it would say changes.
pub fn script(arena: Allocator, exe: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena,
        \\-- Tells Shifty which Rex tab and session you're on, so auto switch
        \\-- can follow them, even on a remote host. Run it on your Mac (rex do
        \\-- runs scripts where the rex command is), once for each server:
        \\--   rex do shifty.lua --all
        \\--   rex -S <host> do shifty.lua --all server=<host>
        \\-- The Shifty menu bar app runs these for you when "Follow Rex tabs"
        \\-- is on in its Auto Switch settings.
        \\
        \\local shifty = rex.args.shifty or '{0s}'
        \\local server = rex.args.server or ""
        \\local said
        \\
        \\local function session_label(session_id)
        \\  local list = rex.call("session.list")
        \\  for _, s in ipairs((list and list.sessions) or {{}}) do
        \\    if s.session_id == session_id then return s.label or "" end
        \\  end
        \\  return ""
        \\end
        \\
        \\local function tell(session_id, window_id)
        \\  if not session_id then return end
        \\  local view = rex.session.view({{ session_id = session_id }})
        \\  if not view then return end
        \\  window_id = window_id or view.active_window_id
        \\  local window = ""
        \\  for _, w in ipairs(view.windows or {{}}) do
        \\    if w.window_id == window_id then window = w.label or "" end
        \\  end
        \\  local session = session_label(session_id)
        \\  local say = session .. "\t" .. window
        \\  if say == said then return end
        \\  said = say
        \\  rex.exec({{ shifty, "rex", "--server", server, "--session", session, "--window", window }})
        \\end
        \\
        \\rex.on("active_window_changed", function(ctx, ev) tell(ctx.session_id, ev.window_id) end)
        \\rex.on("client_connected", function(ctx) tell(ctx.session_id) end)
        \\rex.on("window_label_changed", function(ctx, ev)
        \\  local view = rex.session.view({{ session_id = ctx.session_id }})
        \\  if view and view.active_window_id == ev.window_id then said = nil; tell(ctx.session_id) end
        \\end)
        \\rex.on("session_label_changed", function(ctx) said = nil; tell(ctx.session_id) end)
        \\
    , .{exe});
}

const testing = std.testing;

test "format / parse - round trip; empty or junk is nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try format(a, .{ .ts = 5, .server = "devbox", .session = "Store Galore", .window = "api" });
    const f = parse(text).?;
    try testing.expectEqual(5, f.ts);
    try testing.expectEqualStrings("devbox", f.server);
    try testing.expectEqualStrings("Store Galore", f.session);
    try testing.expectEqualStrings("api", f.window);
    try testing.expectEqual(null, parse("junk\n"));
    try testing.expectEqual(null, parse("7\t\t\t\n"));
    try testing.expectEqual(null, parse(""));
    try testing.expectEqualStrings("", parse("7\t\tshifty\t\n").?.window);
}

test "title - the tab, then the session, as Rex titles its window" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("api - Store Galore", try title(a, .{ .ts = 0, .session = "Store Galore", .window = "api" }));
    try testing.expectEqualStrings("Store Galore", try title(a, .{ .ts = 0, .session = "Store Galore" }));
    try testing.expectEqualStrings("api", try title(a, .{ .ts = 0, .window = "api" }));
}

test "record / current - replaces the line, cleans fields, goes stale" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.process.currentPathAlloc(io, a);
    const path = try std.fs.path.join(a, &.{ base, ".zig-cache/tmp", &tmp.sub_path, "Shifty", file_name });

    try testing.expectEqual(null, try current(io, a, path, 0));
    try record(io, a, path, .{ .ts = 1, .server = "devbox", .session = "one", .window = "a" });
    try record(io, a, path, .{ .ts = 2, .server = "devbox", .session = "two\tparts", .window = " b\n" });
    const f = (try current(io, a, path, 3)).?;
    try testing.expectEqual(2, f.ts);
    try testing.expectEqualStrings("two parts", f.session);
    try testing.expectEqualStrings("b", f.window);
    try testing.expectEqual(null, try current(io, a, path, 3 + keep_secs));
}

test "script - names the executable and the events it follows" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try script(arena.allocator(), "/opt/bin/shifty");
    try testing.expect(std.mem.indexOf(u8, s, "'/opt/bin/shifty'") != null);
    try testing.expect(std.mem.indexOf(u8, s, "rex.on(\"active_window_changed\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "rex.on(\"client_connected\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"rex\", \"--server\"") != null);
}
