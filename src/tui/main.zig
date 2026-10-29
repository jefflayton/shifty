const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const time = core.time;
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const max_breaks = 8;
const label_width = 14;
const field_width = 10;
const row_width = 44;

const Break = struct {
    start: vxfw.TextField,
    end: vxfw.TextField,
};

/// Main application state
const Model = struct {
    shift_length: vxfw.TextField,
    start_time: vxfw.TextField,
    /// Every slot is always an initialized TextField pair; only the first
    /// `break_count` are shown. Slots are never freed while running because
    /// vxfw still delivers `focus_out` to the old widget after a focus change.
    breaks: [max_breaks]Break,
    break_count: usize = 0,
    /// Index into the tab order: shift length, clock in, then each break's
    /// start and end.
    focus: usize = 0,

    fn init(alloc: Allocator) Model {
        var self: Model = .{
            .shift_length = .init(alloc),
            .start_time = .init(alloc),
            .breaks = undefined,
        };
        for (&self.breaks) |*b| b.* = .{ .start = .init(alloc), .end = .init(alloc) };
        return self;
    }

    fn deinit(self: *Model) void {
        self.shift_length.deinit();
        self.start_time.deinit();
        for (&self.breaks) |*b| {
            b.start.deinit();
            b.end.deinit();
        }
    }

    pub fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Model.typeErasedEventHandler,
            .drawFn = Model.typeErasedDrawFn,
        };
    }

    /// This function will be called from the vxfw runtime.
    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => return ctx.requestFocus(self.focusedWidget()),
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    return;
                } else if (key.matches('\t', .{}) or
                    key.matches('n', .{ .ctrl = true }) or
                    key.matches(vaxis.Key.down, .{}) or
                    key.matches(vaxis.Key.enter, .{}))
                {
                    return self.moveFocus(ctx, 1);
                } else if (key.matches('\t', .{ .shift = true }) or
                    key.matches('p', .{ .ctrl = true }) or
                    key.matches(vaxis.Key.up, .{}))
                {
                    return self.moveFocus(ctx, -1);
                } else if (key.matches('t', .{ .ctrl = true })) {
                    return self.addBreak(ctx);
                } else if (key.matches('x', .{ .ctrl = true })) {
                    return self.removeFocusedBreak(ctx);
                }
            },
            else => {},
        }
    }

    /// This function is called from the vxfw runtime. It will be called on a regular interval, and
    /// only when any event handler has marked the redraw flag in EventContext as true. By
    /// explicitly requiring setting the redraw flag, vxfw can prevent excessive redraws for events
    /// which don't change state (ie mouse motion, unhandled key events, etc)
    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const arena = ctx.arena;
        const max_size = ctx.max.size();

        const eval = try self.evaluate(arena);

        var rows: std.ArrayList(vxfw.FlexItem) = .empty;

        // title
        try rows.append(arena, .{
            .widget = try text(arena, "Shifty", .{ .bold = true }, .center, row_width),
            .flex = 0,
        });

        // shift length
        try rows.append(arena, .{ .widget = try fieldRow(arena, "Shift Length", &.{
            try self.field(arena, eval, 0),
            try inlineText(arena, " hr", .{}),
        }), .flex = 0 });

        // clock in
        try rows.append(arena, .{ .widget = try fieldRow(arena, "Clock In", &.{
            try self.field(arena, eval, 1),
        }), .flex = 0 });

        // breaks
        for (0..self.break_count) |i| {
            const label = if (i == 0) "Breaks" else "";
            try rows.append(arena, .{ .widget = try fieldRow(arena, label, &.{
                try self.field(arena, eval, 2 + 2 * i),
                try inlineText(arena, " - ", .{}),
                try self.field(arena, eval, 3 + 2 * i),
            }), .flex = 0 });
        }
        if (self.break_count == 0) {
            try rows.append(arena, .{ .widget = try fieldRow(arena, "Breaks", &.{
                try inlineText(arena, "none (ctrl+t to add)", .{ .dim = true }),
            }), .flex = 0 });
        }

        // clock out
        const out_text = if (eval.out) |out|
            // calc always yields an in-range Time, which fits toStr's buffer
            try std.fmt.allocPrint(arena, "Clock Out: {s}", .{&(out.toStr() catch unreachable)})
        else
            "Clock Out: --:--";
        const out_padded = try make(arena, vxfw.Padding{
            .child = try text(arena, out_text, .{ .bold = eval.out != null, .dim = eval.out == null }, .center, row_width),
            .padding = .{ .top = 1, .bottom = 1 },
        });
        const out_sized = try make(arena, vxfw.SizedBox{
            .child = out_padded.widget(),
            .size = .{ .width = row_width, .height = 3 },
        });
        try rows.append(arena, .{ .widget = out_sized.widget(), .flex = 0 });

        // help
        try rows.append(arena, .{
            .widget = try text(arena,
                \\tab/enter next   shift+tab prev   ctrl+c quit
                \\ctrl+t add break   ctrl+x remove break
            , .{ .dim = true }, .center, row_width),
            .flex = 0,
        });

        const column: vxfw.FlexColumn = .{ .children = rows.items };

        const center: vxfw.Center = .{ .child = column.widget() };
        const center_subsurface: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try center.draw(ctx),
        };
        const children = try arena.alloc(vxfw.SubSurface, 1);
        children[0] = center_subsurface;

        return .{
            .size = max_size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }


    /// The bordered text field at tab index `idx`.
    fn field(self: *Model, arena: Allocator, eval: Evaluation, idx: usize) Allocator.Error!vxfw.Widget {
        const sized = try make(arena, vxfw.SizedBox{
            .child = self.textField(idx).widget(),
            .size = .{ .width = field_width, .height = 1 },
        });
        var style: vaxis.Style = .{};
        if (eval.invalid[idx]) style.fg = .{ .index = 1 };
        if (self.focus == idx) {
            if (!eval.invalid[idx]) style.fg = .{ .index = 15 };
            style.bold = true;
        }
        const border = try make(arena, vxfw.Border{ .child = sized.widget(), .style = style });
        return border.widget();
    }

    fn textField(self: *Model, idx: usize) *vxfw.TextField {
        return switch (idx) {
            0 => &self.shift_length,
            1 => &self.start_time,
            else => {
                const b = &self.breaks[(idx - 2) / 2];
                return if (idx % 2 == 0) &b.start else &b.end;
            },
        };
    }

    fn fieldCount(self: *const Model) usize {
        return 2 + 2 * self.break_count;
    }

    fn focusedWidget(self: *Model) vxfw.Widget {
        return self.textField(self.focus).widget();
    }

    fn moveFocus(self: *Model, ctx: *vxfw.EventContext, delta: isize) !void {
        const n: isize = @intCast(self.fieldCount());
        self.focus = @intCast(@mod(@as(isize, @intCast(self.focus)) + delta, n));
        try ctx.requestFocus(self.focusedWidget());
        ctx.consumeAndRedraw();
    }

    fn addBreak(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.break_count == max_breaks) return ctx.consumeEvent();
        self.break_count += 1;
        self.focus = self.fieldCount() - 2;
        try ctx.requestFocus(self.focusedWidget());
        ctx.consumeAndRedraw();
    }

    fn removeFocusedBreak(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.focus < 2) return ctx.consumeEvent();
        const i = (self.focus - 2) / 2;

        // Clear the removed slot and rotate it to the end, keeping every slot
        // a live TextField.
        self.breaks[i].start.clearAndFree();
        self.breaks[i].end.clearAndFree();
        std.mem.rotate(Break, self.breaks[i..self.break_count], 1);
        self.break_count -= 1;

        self.focus = @min(self.focus, self.fieldCount() - 1);
        try ctx.requestFocus(self.focusedWidget());
        ctx.consumeAndRedraw();
    }

    const Evaluation = struct {
        out: ?time.Time,
        /// Per tab index: the field has text that doesn't parse.
        invalid: []bool,
    };

    /// Parses every field and computes the clock-out time. Empty fields are
    /// not flagged, but an empty shift length or clock in yields no result,
    /// and a break with an empty side is left out.
    fn evaluate(self: *Model, arena: Allocator) Allocator.Error!Evaluation {
        const n = self.fieldCount();
        const invalid = try arena.alloc(bool, n);
        @memset(invalid, false);

        const length_str = try fieldText(arena, &self.shift_length);
        const shift_secs: ?i64 = time.parseDuration(length_str) catch blk: {
            invalid[0] = length_str.len > 0;
            break :blk null;
        };
        const start_str = try fieldText(arena, &self.start_time);
        const start: ?time.Time = time.Time.fromStr(start_str) catch blk: {
            invalid[1] = start_str.len > 0;
            break :blk null;
        };

        var breaks: std.ArrayList(time.TimeInterval) = .empty;
        for (self.breaks[0..self.break_count], 0..) |*b, i| {
            const s_str = try fieldText(arena, &b.start);
            const e_str = try fieldText(arena, &b.end);
            const s = time.Time.fromStr(s_str) catch null;
            const e = time.Time.fromStr(e_str) catch null;
            invalid[2 + 2 * i] = s == null and s_str.len > 0;
            invalid[3 + 2 * i] = e == null and e_str.len > 0;
            if (s != null and e != null) try breaks.append(arena, .{ .start = s.?, .end = e.? });
        }

        const any_invalid = std.mem.indexOfScalar(bool, invalid, true) != null;
        if (any_invalid or shift_secs == null or start == null) return .{ .out = null, .invalid = invalid };

        return .{
            .out = try time.calc(arena, shift_secs.?, start.?, breaks.items),
            .invalid = invalid,
        };
    }
};

/// A labeled row of `cells`, three lines tall to fit bordered fields.
fn fieldRow(arena: Allocator, label: []const u8, cells: []const vxfw.Widget) Allocator.Error!vxfw.Widget {
    const items = try arena.alloc(vxfw.FlexItem, cells.len + 1);
    const label_padded = try make(arena, vxfw.Padding{
        .child = try text(arena, label, .{ .bold = true }, .right, label_width - 1),
        .padding = .{ .top = 1, .right = 1 },
    });
    // FlexRow lays children out with unbounded width, which Padding rejects
    const label_sized = try make(arena, vxfw.SizedBox{
        .child = label_padded.widget(),
        .size = .{ .width = label_width, .height = 3 },
    });
    items[0] = .{ .widget = label_sized.widget(), .flex = 0 };
    for (cells, items[1..]) |cell, *item| item.* = .{ .widget = cell, .flex = 0 };
    const row = try make(arena, vxfw.FlexRow{ .children = items });
    const sized = try make(arena, vxfw.SizedBox{
        .child = row.widget(),
        .size = .{ .width = row_width, .height = 3 },
    });
    return sized.widget();
}

/// Text for a `fieldRow` cell, aligned with the middle line of bordered fields.
fn inlineText(arena: Allocator, str: []const u8, style: vaxis.Style) Allocator.Error!vxfw.Widget {
    const padded = try make(arena, vxfw.Padding{
        .child = try text(arena, str, style, .left, null),
        .padding = .{ .top = 1 },
    });
    const sized = try make(arena, vxfw.SizedBox{
        .child = padded.widget(),
        .size = .{ .width = @intCast(str.len), .height = 3 },
    });
    return sized.widget();
}

fn fieldText(arena: Allocator, tf: *const vxfw.TextField) Allocator.Error![]const u8 {
    return std.mem.concat(arena, u8, &.{ tf.buf.firstHalf(), tf.buf.secondHalf() });
}

fn make(arena: Allocator, value: anytype) Allocator.Error!*const @TypeOf(value) {
    const p = try arena.create(@TypeOf(value));
    p.* = value;
    return p;
}

fn text(
    arena: Allocator,
    str: []const u8,
    style: vaxis.Style,
    text_align: @FieldType(vxfw.Text, "text_align"),
    width: ?u16,
) Allocator.Error!vxfw.Widget {
    const t = try make(arena, vxfw.Text{ .text = str, .style = style, .text_align = text_align });
    const w = width orelse return t.widget();
    const sized = try make(arena, vxfw.SizedBox{
        .child = t.widget(),
        .size = .{ .width = w, .height = @intCast(std.mem.count(u8, str, "\n") + 1) },
    });
    return sized.widget();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    var buffer: [1024]u8 = undefined;
    var app: vxfw.App = try .init(io, alloc, init.environ_map, &buffer);
    defer app.deinit();

    const model = try alloc.create(Model);
    defer alloc.destroy(model);

    model.* = .init(alloc);
    defer model.deinit();

    try model.shift_length.insertSliceAtCursor("8");
    const now = try core.local.now(io).toStr();
    try model.start_time.insertSliceAtCursor(&now);

    try app.run(model.widget(), .{});
}

const testing = std.testing;

fn testModel(fields: []const []const u8) !*Model {
    const model = try testing.allocator.create(Model);
    model.* = .init(testing.allocator);
    model.break_count = (fields.len - 2) / 2;
    for (fields, 0..) |f, i| try model.textField(i).insertSliceAtCursor(f);
    return model;
}

fn freeModel(model: *Model) void {
    model.deinit();
    testing.allocator.destroy(model);
}

test "evaluate - clock out with breaks" {
    const model = try testModel(&.{ "8", "9:00 AM", "12pm", "1pm", "", "" });
    defer freeModel(model);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const eval = try model.evaluate(arena.allocator());
    try testing.expectEqual(time.Time{ .hour = 18, .min = 0 }, eval.out.?);
    try testing.expect(std.mem.indexOfScalar(bool, eval.invalid, true) == null);
}

test "evaluate - invalid field blocks result" {
    const model = try testModel(&.{ "8", "9:00 AM", "12pm", "nope" });
    defer freeModel(model);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const eval = try model.evaluate(arena.allocator());
    try testing.expectEqual(null, eval.out);
    try testing.expectEqualSlices(bool, &.{ false, false, false, true }, eval.invalid);
}

test "evaluate - empty clock in yields no result" {
    const model = try testModel(&.{ "8", "" });
    defer freeModel(model);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const eval = try model.evaluate(arena.allocator());
    try testing.expectEqual(null, eval.out);
    try testing.expectEqualSlices(bool, &.{ false, false }, eval.invalid);
}
