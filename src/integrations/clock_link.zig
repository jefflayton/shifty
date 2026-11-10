//! The clock links: your timeclock's pages, which clocking in and out (and
//! lunch, if it's set to) offer to open, so you can punch it too. The menu
//! bar's Settings keeps them in the shared settings.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const store = @import("store");

pub const Which = enum {
    /// Clocking in, and back from lunch.
    in,
    /// Clocking out, and going to lunch.
    out,
};

/// The link to open, if one is set. Clocking in uses the clock-out link
/// unless a separate clock-in link is set. Allocated in `arena`.
pub fn get(db: *store.Store, arena: Allocator, which: Which) store.Error!?[]const u8 {
    if (which == .in) {
        if (try db.setting(arena, "clock_in_link")) |l| if (l.len > 0) return l;
    }
    const l = try db.setting(arena, "clock_out_link") orelse return null;
    return if (l.len > 0) l else null;
}

/// Opens `url` in the default browser and waits for the opener to exit.
pub fn open(io: Io, url: []const u8) !void {
    const opener = if (builtin.os.tag == .macos) "open" else "xdg-open";
    var child = try std.process.spawn(io, .{
        .argv = &.{ opener, url },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.OpenFailed;
}

test "get - clock in falls back to the clock-out link" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var db: store.Store = try .open(testing.io, ":memory:");
    defer db.deinit();
    try testing.expectEqual(null, try get(&db, arena.allocator(), .in));
    try db.setSetting("clock_out_link", "https://clock.example/out", 0);
    try testing.expectEqualStrings("https://clock.example/out", (try get(&db, arena.allocator(), .in)).?);
    try db.setSetting("clock_in_link", "https://clock.example/in", 0);
    try testing.expectEqualStrings("https://clock.example/in", (try get(&db, arena.allocator(), .in)).?);
    try testing.expectEqualStrings("https://clock.example/out", (try get(&db, arena.allocator(), .out)).?);
}
