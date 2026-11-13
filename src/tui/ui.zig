//! Drawing helpers the TUI's screens share.

const std = @import("std");
const Allocator = std.mem.Allocator;

const core = @import("core");
const store = @import("store");
const report = store.report;
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

pub const bold: vaxis.Style = .{ .bold = true };
pub const dim: vaxis.Style = .{ .dim = true };
pub const green: vaxis.Style = .{ .fg = .{ .index = 2 } };
pub const yellow: vaxis.Style = .{ .fg = .{ .index = 3 } };
pub const red: vaxis.Style = .{ .fg = .{ .index = 1 } };
pub const cyan: vaxis.Style = .{ .fg = .{ .index = 6 } };

/// A project's own color, if it has one.
pub fn projectStyle(names: report.Names, project_id: ?core.Uuid, strong: bool) vaxis.Style {
    var style: vaxis.Style = .{ .bold = strong };
    const pid = project_id orelse {
        style.dim = true;
        return style;
    };
    const color = (names.project(pid) orelse return style).color orelse return style;
    if (color.len == 7 and color[0] == '#') {
        const rgb = std.fmt.parseInt(u24, color[1..], 16) catch return style;
        style.fg = .{ .rgb = .{ @truncate(rgb >> 16), @truncate(rgb >> 8), @truncate(rgb) } };
    }
    return style;
}

/// Time on organizations with no shift, by project, under its own heading:
/// it's never worked time. Nothing when there's none.
pub fn drawPersonal(p: *Painter, names: report.Names, t: report.Totals, a: Allocator) Allocator.Error!void {
    if (t.personal_by_project.len == 0) return;
    p.nl(1);
    p.put("Personal, not worked", .{ .bold = true });
    try p.right(try p.fmt("{f}", .{core.fmt.dur(t.personal)}), .{ .bold = true });
    p.nl(1);
    for (t.personal_by_project) |pt| {
        try p.print(.{}, "  {s: >7}  ", .{try p.fmt("{f}", .{core.fmt.dur(pt.secs)})});
        p.put(try names.label(a, pt.id, null), projectStyle(names, pt.id, false));
        if (names.organizationOf(pt.id)) |o| try p.print(dim, "  {s}", .{o.name});
        p.nl(1);
    }
}

/// Writes styled text into a surface line by line, clipped to a column of
/// `width` cells starting at `left`.
pub const Painter = struct {
    ctx: vxfw.DrawContext,
    surface: vxfw.Surface,
    left: u16,
    width: u16,
    height: u16,
    row: u16 = 1,
    col: u16 = 0,
    /// Draws everything reversed, for the selected line.
    highlight: bool = false,

    pub fn put(p: *Painter, str: []const u8, style: vaxis.Style) void {
        if (p.row >= p.height) return;
        var s = style;
        if (p.highlight) s.reverse = true;
        var it = p.ctx.graphemeIterator(str);
        while (it.next()) |g| {
            const bytes = g.bytes(str);
            const w: u16 = @intCast(p.ctx.stringWidth(bytes));
            if (p.col + w > p.width) return;
            p.surface.writeCell(p.left + p.col, p.row, .{ .char = .{ .grapheme = bytes, .width = @intCast(w) }, .style = s });
            p.col += w;
        }
    }

    pub fn fmt(p: *Painter, comptime f: []const u8, args: anytype) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(p.ctx.arena, f, args);
    }

    pub fn print(p: *Painter, style: vaxis.Style, comptime f: []const u8, args: anytype) Allocator.Error!void {
        p.put(try p.fmt(f, args), style);
    }

    /// Puts `str` flush right on the current row.
    pub fn right(p: *Painter, str: []const u8, style: vaxis.Style) Allocator.Error!void {
        const w: u16 = @intCast(p.ctx.stringWidth(str));
        p.pad(p.width -| w);
        p.put(str, style);
    }

    /// Moves to column `col`, filling the gap so a highlight runs through it.
    pub fn pad(p: *Painter, col: u16) void {
        while (p.col < col and p.col < p.width) p.put(" ", .{});
    }

    pub fn nl(p: *Painter, n: u16) void {
        if (p.highlight) p.pad(p.width);
        p.row +|= n;
        p.col = 0;
    }

    /// A one-row text field at column `col` of the current row.
    pub fn field(p: *Painter, w: vxfw.Widget, col: u16, width: u16) Allocator.Error!vxfw.SubSurface {
        const size: vxfw.Size = .{ .width = width, .height = 1 };
        return .{
            .origin = .{ .row = p.row, .col = p.left + col },
            .surface = try w.draw(p.ctx.withConstraints(size, .fromSize(size))),
        };
    }
};

/// A key and what it does, for a screen's key hints.
pub const Hint = struct { []const u8, []const u8 };

/// Rows `drawHints` needs for `hints` in `width` cells.
pub fn hintRows(ctx: vxfw.DrawContext, hints: []const Hint, width: u16) u16 {
    var rows: u16 = 1;
    var col: usize = 0;
    for (hints) |h| {
        const w = ctx.stringWidth(h[0]) + 1 + ctx.stringWidth(h[1]);
        if (col > 0 and col + 2 + w > width) {
            rows += 1;
            col = 0;
        }
        col += (if (col > 0) @as(usize, 2) else 0) + w;
    }
    return rows;
}

/// Key hints from the current row, wrapping onto the next rows: keys bold,
/// what they do dim.
pub fn drawHints(p: *Painter, hints: []const Hint) void {
    p.col = 0;
    for (hints) |h| {
        const w: u16 = @intCast(p.ctx.stringWidth(h[0]) + 1 + p.ctx.stringWidth(h[1]));
        if (p.col > 0 and p.col + 2 + w > p.width) p.nl(1) else if (p.col > 0) p.put("  ", .{});
        p.put(h[0], bold);
        p.put(" ", .{});
        p.put(h[1], dim);
    }
}

pub fn fieldText(a: Allocator, tf: *const vxfw.TextField) Allocator.Error![]const u8 {
    return std.mem.concat(a, u8, &.{ tf.buf.firstHalf(), tf.buf.secondHalf() });
}

/// Replaces a field's text.
pub fn setField(tf: *vxfw.TextField, text: []const u8) Allocator.Error!void {
    tf.clearAndFree();
    try tf.insertSliceAtCursor(text);
}

/// A choice in a project picker. `target` null is unassigned time.
pub const Option = struct {
    label: []const u8,
    target: ?store.Target,
    here: bool = false,
};

/// What a project picker offers, narrowed by `query`: the project linked to
/// where you are first, then every project and workspace, then unassigned.
pub fn options(a: Allocator, names: report.Names, here: ?store.Target, query: []const u8) Allocator.Error![]Option {
    var all: std.ArrayList(Option) = .empty;
    if (here) |t| try all.append(a, .{ .label = try names.label(a, t.project_id, t.workspace_id), .target = t, .here = true });
    for (names.projects) |p| {
        try all.append(a, .{ .label = p.name, .target = .{ .project_id = p.id } });
        for (names.workspaces) |w| if (w.project_id.eql(p.id)) {
            try all.append(a, .{ .label = try names.label(a, p.id, w.id), .target = .{ .project_id = p.id, .workspace_id = w.id } });
        };
    }
    try all.append(a, .{ .label = "(unassigned)", .target = null });

    if (query.len == 0) return all.items;
    var out: std.ArrayList(Option) = .empty;
    for (all.items) |o| if (std.ascii.indexOfIgnoreCase(o.label, query) != null) try out.append(a, o);
    return out.items;
}

/// Draws a picker's options from the current row down to `bottom`, keeping
/// `selected` in view.
pub fn drawOptions(p: *Painter, opts: []const Option, selected: usize, bottom: u16) void {
    if (opts.len == 0) {
        p.put("  No match", dim);
        return;
    }
    const sel = @min(selected, opts.len - 1);
    const room: usize = @max(1, bottom -| p.row -| 1);
    const first = if (sel >= room) sel - room + 1 else 0;
    for (opts[first..@min(opts.len, first + room)], first..) |o, i| {
        const on = i == sel;
        p.put(if (on) "  ▸ " else "    ", if (on) green else dim);
        p.put(o.label, if (on) bold else .{});
        if (o.here) p.put("  this repo", dim);
        p.nl(1);
    }
}

/// Moves a picker selection for ↑/↓ (and ctrl+p/ctrl+n, tab). Returns
/// whether the key was one of them.
pub fn movePick(key: vaxis.Key, selected: *usize) bool {
    if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true }) or key.matches('\t', .{ .shift = true })) {
        selected.* -|= 1;
        return true;
    }
    if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true }) or key.matches('\t', .{})) {
        selected.* += 1;
        return true;
    }
    return false;
}

const testing = std.testing;

test "projectStyle - uses the project's color" {
    const pid: core.Uuid = .v7At(1, @splat(0));
    const names: report.Names = .{
        .clients = &.{},
        .projects = &.{.{ .id = pid, .client_id = null, .name = "web", .color = "#ff8800" }},
        .workspaces = &.{},
    };
    try testing.expectEqual(vaxis.Color{ .rgb = .{ 0xff, 0x88, 0x00 } }, projectStyle(names, pid, false).fg);
    try testing.expect(projectStyle(names, null, false).dim);
}

test "options - here first, filtered" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pid: core.Uuid = .v7At(1, @splat(0));
    const names: report.Names = .{
        .clients = &.{},
        .projects = &.{.{ .id = pid, .client_id = null, .name = "web", .color = null }},
        .workspaces = &.{.{ .id = .v7At(2, @splat(0)), .project_id = pid, .name = "main" }},
    };
    const all = try options(arena.allocator(), names, .{ .project_id = pid }, "");
    try testing.expectEqual(4, all.len);
    try testing.expect(all[0].here);
    const some = try options(arena.allocator(), names, null, "MAIN");
    try testing.expectEqual(1, some.len);
    try testing.expectEqualStrings("web/main", some[0].label);
}
