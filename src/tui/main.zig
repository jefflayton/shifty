const std = @import("std");
const Io = std.Io;

const core = @import("core");
const store = @import("store");
const situ = @import("integrations").situ;
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Calculator = @import("calc.zig").Calculator;
const Tracker = @import("tracker.zig").Tracker;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var stderr_buf: [256]u8 = undefined;
    var stderr_writer: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    // Open the store before taking over the terminal, so a failure prints
    // where it can be read.
    const path = store.defaultPath(arena, init.environ_map) catch |e| switch (e) {
        error.NoHome => {
            try stderr.writeAll("shifty-tui: $HOME isn't set; set $SHIFTY_DB to choose where the database goes\n");
            try stderr_writer.flush();
            std.process.exit(1);
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    var db = store.Store.open(io, path) catch |e| {
        switch (e) {
            error.SchemaTooNew => try stderr.print("shifty-tui: {s} was written by a newer Shifty; update this one\n", .{path}),
            else => try stderr.print("shifty-tui: can't open {s}: {t}\n", .{ path, e }),
        }
        try stderr_writer.flush();
        std.process.exit(1);
    };
    defer db.deinit();

    const cwd = std.process.currentPathAlloc(io, arena) catch null;
    const marker = if (cwd) |d| try situ.find(io, arena, d) else null;

    const calc = try gpa.create(Calculator);
    defer gpa.destroy(calc);
    calc.* = .init(gpa);
    defer calc.deinit();
    try prefillCalculator(io, calc, &db, arena);

    const tracker = try gpa.create(Tracker);
    defer gpa.destroy(tracker);
    tracker.* = .init(gpa, io, init.environ_map, &db, marker, calc);
    defer tracker.deinit();
    tracker.bind();

    var buffer: [1024]u8 = undefined;
    var app: vxfw.App = try .init(io, gpa, init.environ_map, &buffer);
    defer app.deinit();
    try app.run(tracker.widget(), .{});
}

/// Starts the calculator from the open shift, if any, else from now.
fn prefillCalculator(io: Io, calc: *Calculator, db: *store.Store, arena: std.mem.Allocator) !void {
    const shift = db.currentShift(arena) catch null;
    const secs = if (shift) |s| s.target_secs else 8 * std.time.s_per_hour;
    const mins: u64 = @intCast(@divFloor(secs, 60));
    const length = if (mins % 60 == 0)
        try std.fmt.allocPrint(arena, "{d}", .{mins / 60})
    else
        try std.fmt.allocPrint(arena, "{d}h{d}m", .{ mins / 60, mins % 60 });
    try calc.shift_length.insertSliceAtCursor(length);

    const start = if (shift) |s|
        core.time.Time.fromTs(s.in_ts + s.utc_offset_secs)
    else
        core.local.now(io);
    try calc.start_time.insertSliceAtCursor(&try start.toStr());
}

test {
    _ = @import("calc.zig");
    _ = @import("tracker.zig");
}
