//! Where you're working, and which project that means: a directory (a Situ
//! repo, a git repo, or any folder), the app it's open in, and the title of
//! that app's window. Every frontend asks this, so `shifty start` in a repo
//! and the menu bar's auto-switch agree. Places nothing links to mean
//! nothing: no project, no change.
//!
//! One place can link to several projects (a repo two projects work in).
//! Then a keyword in the window's title picks, else the one you tracked
//! most recently, a running timer first.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const store = @import("store");
const situ = @import("situ.zig");
const git = @import("git.zig");

/// What linked a place to its project. Keep the order: the C API passes it
/// as a number.
pub const Via = enum { situ, git, folder, app, keyword };

pub const folder_provider = "folder";
pub const folder_kind = "path";
pub const app_provider = "app";
pub const app_kind = "bundle";
pub const keyword_provider = "keyword";
pub const keyword_kind = "word";

/// Keywords longer than this aren't names.
pub const max_keyword = 64;

pub const Place = struct {
    /// The Situ repo or git repo `dir` is in, if any.
    marker: ?situ.Marker = null,
    repo: ?git.Repo = null,
    /// The repo's top, else null: what to name it by.
    root: ?[]const u8 = null,
    /// What it's linked to, and how.
    target: ?store.Target = null,
    via: ?Via = null,
    /// The folder link that matched, when it was a folder's.
    folder: ?[]const u8 = null,
    /// The keyword in the title that picked `target`, when `via` is
    /// `keyword`.
    keyword: ?[]const u8 = null,
    /// How many projects it could have been: more than one when a place
    /// links to several.
    choices: usize = 0,
};

/// The project for working in `dir` (an absolute path) in the app with
/// bundle id `app`, whose window is titled `title`; any may be unknown.
///
/// The place's links, most specific first: the Situ repo's, the git
/// remote's, the nearest linked folder at or above `dir`, then the app's.
/// A keyword in `title` beats them all, and where both a keyword and the
/// place link to several projects, the ones both name win.
pub fn resolve(db: *store.Store, io: Io, arena: Allocator, dir: ?[]const u8, app: ?[]const u8, title: ?[]const u8) store.Error!Place {
    var p: Place = .{};
    var links: []const store.Target = &.{};
    var via: ?Via = null;
    if (dir) |d| found: {
        p.marker = try situ.find(io, arena, d);
        p.repo = try git.find(io, arena, d);
        p.root = if (p.marker) |m| m.root else if (p.repo) |r| r.root else null;

        if (p.marker) |m| {
            links = try situ.linked(db, arena, m);
            if (links.len > 0) {
                via = .situ;
                break :found;
            }
        }
        if (p.repo) |r| if (r.remote) |remote| {
            links = try db.resolveLinks(arena, git.provider, git.kind_remote, remote);
            if (links.len > 0) {
                via = .git;
                break :found;
            }
        };
        var cur: ?[]const u8 = std.mem.trimEnd(u8, d, "/");
        while (cur) |c| : (cur = std.fs.path.dirname(c)) {
            const key = if (c.len == 0) "/" else c;
            links = try db.resolveLinks(arena, folder_provider, folder_kind, key);
            if (links.len > 0) {
                p.folder = key;
                via = .folder;
                break :found;
            }
            if (c.len == 0) break;
        }
    }
    if (via == null) if (app) |a| if (a.len > 0) {
        links = try db.resolveLinks(arena, app_provider, app_kind, a);
        if (links.len > 0) via = .app;
    };

    if (title) |t| if (t.len > 0) {
        const named = try keywordsIn(db, arena, t);
        if (named.len > 0) {
            var both: std.ArrayList(Named) = .empty;
            for (named) |n| if (has(links, n.target)) try both.append(arena, n);
            const pick = if (both.items.len > 0) both.items else named;
            const targets = try arena.alloc(store.Target, pick.len);
            for (pick, targets) |n, *out| out.* = n.target;
            var out = try choose(db, p, targets, .keyword);
            for (pick) |n| if (eql(n.target, out.target.?)) {
                out.keyword = n.word;
                break;
            };
            return out;
        }
    };
    if (via) |v| return choose(db, p, links, v);
    return p;
}

/// A keyword in a title, and the project it names.
const Named = struct { word: []const u8, target: store.Target };

/// The keywords `title` has, each with what it links to, longest first.
fn keywordsIn(db: *store.Store, arena: Allocator, title: []const u8) store.Error![]Named {
    var out: std.ArrayList(Named) = .empty;
    for (try db.links(arena)) |l| {
        if (!std.mem.eql(u8, l.provider, keyword_provider) or !std.mem.eql(u8, l.kind, keyword_kind)) continue;
        if (!titleHas(title, l.external_id)) continue;
        const dup = for (out.items) |n| {
            if (eql(n.target, l.target)) break true;
        } else false;
        if (dup) continue;
        try out.append(arena, .{ .word = l.external_id, .target = l.target });
    }
    std.mem.sort(Named, out.items, {}, struct {
        fn lessThan(_: void, a: Named, b: Named) bool {
            return a.word.len > b.word.len;
        }
    }.lessThan);
    return out.items;
}

fn has(set: []const store.Target, t: store.Target) bool {
    for (set) |s| if (eql(s, t)) return true;
    return false;
}

fn eql(a: store.Target, b: store.Target) bool {
    if (!a.project_id.eql(b.project_id)) return false;
    if (a.workspace_id) |aw| return if (b.workspace_id) |bw| aw.eql(bw) else false;
    return b.workspace_id == null;
}

/// Of `choices` (at least one), the one tracked most recently, a running
/// timer's first; never-tracked ones go by which was linked first.
fn choose(db: *store.Store, p: Place, choices: []const store.Target, via: Via) store.Error!Place {
    var out = p;
    out.via = via;
    out.choices = choices.len;
    var best = choices[0];
    var best_ts: ?i64 = null;
    if (choices.len > 1) for (choices) |c| {
        const ts = try db.lastTracked(c) orelse continue;
        if (best_ts == null or ts > best_ts.?) {
            best = c;
            best_ts = ts;
        }
    };
    out.target = best;
    return out;
}

/// Whether `title` has `word` (lowercase) in it, as a whole word or
/// phrase: not inside a longer word. Case doesn't matter, and neither do
/// the spaces and dashes between words: "stand up" finds "Standup",
/// "Stand-up", and "Stand  up", and "standup" finds "Stand up", since
/// meeting and session names spell them every way.
pub fn titleHas(title: []const u8, word: []const u8) bool {
    if (word.len == 0) return false;
    var i: usize = 0;
    while (i < title.len) : (i += 1) {
        if (i > 0 and isWordByte(title[i - 1])) continue;
        const end = matchAt(title, i, word) orelse continue;
        if (end == title.len or !isWordByte(title[end])) return true;
    }
    return false;
}

/// Where `word` ends if it starts at `title[at]`, skipping separators on
/// either side between its letters; null if it isn't there. It never
/// starts or ends on a separator.
fn matchAt(title: []const u8, at: usize, word: []const u8) ?usize {
    var t = at;
    var w: usize = 0;
    while (w < word.len) {
        if (sepLen(word, w)) |n| {
            w += n;
            continue;
        }
        // Separators between two of the word's letters, not before the
        // first.
        if (w > 0) {
            while (sepLen(title, t)) |n| t += n;
        }
        if (t >= title.len or std.ascii.toLower(title[t]) != std.ascii.toLower(word[w])) return null;
        t += 1;
        w += 1;
    }
    return t;
}

/// The length of the separator at `s[i]`: a space, tab, dash, underscore,
/// or a no-break space; null if there isn't one.
fn sepLen(s: []const u8, i: usize) ?usize {
    if (i >= s.len) return null;
    return switch (s[i]) {
        ' ', '\t', '-', '_' => 1,
        // U+00A0 no-break space, U+2011 non-breaking hyphen, U+2013 en dash
        0xC2 => if (i + 1 < s.len and s[i + 1] == 0xA0) 2 else null,
        0xE2 => if (i + 2 < s.len and s[i + 1] == 0x80 and (s[i + 2] == 0x91 or s[i + 2] == 0x93)) 3 else null,
        else => null,
    };
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// `raw` as a keyword is kept: trimmed, lowercase. Null if it can't be one:
/// empty, too long, or with a tab or line break.
pub fn keyword(arena: Allocator, raw: []const u8) Allocator.Error!?[]const u8 {
    const word = std.mem.trim(u8, raw, " \t\r\n");
    if (word.len == 0 or word.len > max_keyword) return null;
    if (std.mem.indexOfAny(u8, word, "\t\r\n") != null) return null;
    return try std.ascii.allocLowerString(arena, word);
}

pub const LinkError = store.Error || Allocator.Error || error{NoWorkspaceId};

/// Links the place `dir` is in to `target`, by the sturdiest id it has: its
/// Situ ids, else its git remote, else the folder (the repo's top, or `dir`
/// itself). Returns which. A place already linked to other projects stays
/// linked to them too.
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

/// Links a keyword (see `keyword`) to `target`: a window titled with it is
/// that project's. Returns the keyword as kept, or null if `raw` can't be
/// one.
pub fn linkKeyword(db: *store.Store, arena: Allocator, raw: []const u8, target: store.Target, now: i64) store.Error!?[]const u8 {
    const word = try keyword(arena, raw) orelse return null;
    try db.link(keyword_provider, keyword_kind, word, target, now);
    return word;
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
    var p = try resolve(&db, io, a, web_src, "com.example.editor", null);
    try testing.expectEqual(null, p.target);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ top, "web" }), p.root.?);

    try testing.expectEqual(Via.git, try linkDir(&db, io, a, web_src, .{ .project_id = web }, 1));
    try testing.expectEqual(Via.folder, try linkDir(&db, io, a, local_b, .{ .project_id = notes }, 1));
    try linkApp(&db, "com.example.chat", .{ .project_id = chat }, 1);

    p = try resolve(&db, io, a, web_src, "com.example.chat", null);
    try testing.expectEqual(Via.git, p.via.?);
    try testing.expect(p.target.?.project_id.eql(web));

    // A repo without a remote links by its top, from anywhere inside.
    p = try resolve(&db, io, a, try std.fs.path.join(a, &.{ top, "local/a" }), null, null);
    try testing.expectEqual(Via.folder, p.via.?);
    try testing.expect(p.target.?.project_id.eql(notes));
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ top, "local" }), p.folder.?);

    // No directory, or one nothing links: the app decides.
    p = try resolve(&db, io, a, null, "com.example.chat", null);
    try testing.expectEqual(Via.app, p.via.?);
    try testing.expect(p.target.?.project_id.eql(chat));
    p = try resolve(&db, io, a, null, "com.example.browser", null);
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
    try testing.expect((try resolve(&db, io, a, r, null, null)).target.?.project_id.eql(other));

    try testing.expectEqual(Via.situ, try linkDir(&db, io, a, r, .{ .project_id = web }, 1));
    const p = try resolve(&db, io, a, r, null, null);
    try testing.expectEqual(Via.situ, p.via.?);
    try testing.expect(p.target.?.project_id.eql(web));
}

test "resolve - a repo two projects share: the last tracked, a running one first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var db: store.Store = try .open(io, ":memory:");
    defer db.deinit();
    const core = try db.createProject(.{ .name = "core" }, 0);
    const app = try db.createProject(.{ .name = "app" }, 0);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "lib/.git");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/.git/config", .data = "[remote \"origin\"]\n\turl = git@github.com:o/lib.git\n" });
    const base = try std.process.currentPathAlloc(io, a);
    const lib = try std.fs.path.join(a, &.{ base, ".zig-cache/tmp", &tmp.sub_path, "lib" });

    // Linking it to a second project keeps the first.
    try testing.expectEqual(Via.git, try linkDir(&db, io, a, lib, .{ .project_id = core }, 1));
    try testing.expectEqual(Via.git, try linkDir(&db, io, a, lib, .{ .project_id = app }, 2));
    var p = try resolve(&db, io, a, lib, null, null);
    try testing.expectEqual(2, p.choices);
    // Neither tracked yet: the first linked.
    try testing.expect(p.target.?.project_id.eql(core));

    _ = try db.startEntry(.{ .project_id = app, .source = .cli }, .{ .ts = 100, .utc_offset_secs = 0, .tz = null });
    _ = try db.stopEntry(200);
    p = try resolve(&db, io, a, lib, null, null);
    try testing.expect(p.target.?.project_id.eql(app));

    // Running beats any stopped one, however late.
    _ = try db.startEntry(.{ .project_id = core, .source = .cli }, .{ .ts = 300, .utc_offset_secs = 0, .tz = null });
    p = try resolve(&db, io, a, lib, null, null);
    try testing.expect(p.target.?.project_id.eql(core));

    // Unlinking one project leaves the other.
    try db.unlink(git.provider, git.kind_remote, "github.com/o/lib", core, 400);
    p = try resolve(&db, io, a, lib, null, null);
    try testing.expectEqual(1, p.choices);
    try testing.expect(p.target.?.project_id.eql(app));
}

test "resolve - a keyword in the title wins, and picks among a shared repo's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var db: store.Store = try .open(io, ":memory:");
    defer db.deinit();
    const core = try db.createProject(.{ .name = "core" }, 0);
    const app = try db.createProject(.{ .name = "app" }, 0);
    const notes = try db.createProject(.{ .name = "notes" }, 0);

    try db.link(folder_provider, folder_kind, "/dev/lib", .{ .project_id = core }, 0);
    try db.link(folder_provider, folder_kind, "/dev/lib", .{ .project_id = app }, 0);
    try testing.expectEqualStrings("store galore", (try linkKeyword(&db, a, "  Store Galore ", .{ .project_id = app }, 1)).?);
    _ = try linkKeyword(&db, a, "notes", .{ .project_id = notes }, 1);
    try testing.expectEqual(null, try linkKeyword(&db, a, " \t", .{ .project_id = app }, 1));
    _ = try db.startEntry(.{ .project_id = core, .source = .cli }, .{ .ts = 10, .utc_offset_secs = 0, .tz = null });

    // Without a keyword, the running project.
    var p = try resolve(&db, io, a, "/dev/lib/src", "com.superlogical.rex", "shy-orchard — zsh");
    try testing.expect(p.target.?.project_id.eql(core));
    try testing.expectEqual(Via.folder, p.via.?);

    // A Rex session named for the project.
    p = try resolve(&db, io, a, "/dev/lib/src", "com.superlogical.rex", "Store Galore — nvim");
    try testing.expectEqual(Via.keyword, p.via.?);
    try testing.expect(p.target.?.project_id.eql(app));
    try testing.expectEqualStrings("store galore", p.keyword.?);
    try testing.expectEqualStrings("/dev/lib", p.folder.?);

    // Not a word of a longer one.
    p = try resolve(&db, io, a, null, "com.superlogical.rex", "footnotes — zsh");
    try testing.expectEqual(null, p.target);

    // Two keywords: the one the place also links to.
    p = try resolve(&db, io, a, "/dev/lib", null, "notes for store galore");
    try testing.expect(p.target.?.project_id.eql(app));
    // Nowhere linked: the keyword alone.
    p = try resolve(&db, io, a, "/tmp", null, "Notes");
    try testing.expect(p.target.?.project_id.eql(notes));
    try testing.expectEqual(Via.keyword, p.via.?);
}

test "titleHas - whole words, any case" {
    try testing.expect(titleHas("Shifty — main.zig", "shifty"));
    try testing.expect(titleHas("rex: store galore", "store galore"));
    try testing.expect(titleHas("api", "api"));
    try testing.expect(!titleHas("rapid", "api"));
    try testing.expect(!titleHas("api_v2", "api"));
    try testing.expect(titleHas("api-v2", "api"));
    try testing.expect(!titleHas("", "api"));
}

test "titleHas - spaces and dashes between words don't matter" {
    // A keyword "Stand up" and a meeting spelled any way.
    try testing.expect(titleHas("Stand up | Microsoft Teams", "stand up"));
    try testing.expect(titleHas("Daily Standup | Microsoft Teams", "stand up"));
    try testing.expect(titleHas("Stand-up | Microsoft Teams", "stand up"));
    try testing.expect(titleHas("Stand  Up", "stand up"));
    try testing.expect(titleHas("Stand\u{a0}up | Microsoft Teams", "stand up"));
    try testing.expect(titleHas("Stand\u{2013}up", "stand up"));
    try testing.expect(titleHas("Stand up | Microsoft Teams", "standup"));
    try testing.expect(titleHas("Team stand-up", "standup"));
    try testing.expect(titleHas("store_galore", "store galore"));
    // Still whole words.
    try testing.expect(!titleHas("Standups", "stand up"));
    try testing.expect(!titleHas("Withstand up", "stand up"));
    try testing.expect(!titleHas("api_v2", "api"));
    try testing.expect(!titleHas("Stand by", "stand up"));
    // Not a word followed by a separator and more letters.
    try testing.expect(!titleHas("Stand-upkeep", "stand up"));
    try testing.expect(titleHas("Stand up — notes", "stand up"));
}
