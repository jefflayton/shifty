const std = @import("std");
const core = @import("core");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

/// Main application state
const Model = struct {
    shift_length_label: vxfw.Text,
    shift_length: vxfw.TextField,
    hr_label: vxfw.Text,

    start_time_label: vxfw.Text,
    start_time: vxfw.TextField,
    calculate: vxfw.Button,
    focus: Field = .shift_length,

    const Field = enum { shift_length, start_time, calculate };

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
                } else if (key.matches('\t', .{}) or key.matches('n', .{ .ctrl = true })) {
                    return try self.focusNext(ctx);
                } else if (key.matches('\t', .{ .shift = true }) or key.matches('p', .{ .ctrl = true })) {
                    return try self.focusPrev(ctx);
                }
            },
            else => {},
        }
    }

    /// This function is called from the vxfw runtime. It will be called on a regular interval, and
    /// only when any event handler has marked the redraw flag in EventContext as true. By
    /// explicitly requiring setting the redraw flag, vxfw can prevent excessive redraws for events
    /// which don't change state (ie mouse motion, unhandled key events, etc)
    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const max_size = ctx.max.size();

        // shift_length
        const shift_length_label_box = box(self.shift_length_label.widget());
        const shift_length_sized: vxfw.SizedBox = .{
            .child = self.shift_length.widget(),
            .size = .{ .width = 8, .height = 1 },
        };
        const shift_length_border: vxfw.Border = .{
            .child = shift_length_sized.widget(),
            .style = self.borderStyle(.shift_length),
        };

        const shift_length_row_children = try ctx.arena.alloc(vxfw.FlexItem, 3);
        shift_length_row_children[0] = .{ .widget = shift_length_label_box.widget(), .flex = 0 };
        shift_length_row_children[1] = .{ .widget = shift_length_border.widget(), .flex = 0 };
        shift_length_row_children[2] = .{ .widget = self.hr_label.widget(), .flex = 0 };
        const shift_length_row: vxfw.FlexRow = .{ .children = shift_length_row_children };
        const shift_length_row_sized: vxfw.SizedBox = .{
            .child = shift_length_row.widget(),
            .size = .{ .width = 40, .height = 3 },
        };

        // start_time
        const start_time_label_box = box(self.start_time_label.widget());
        const start_time_sized: vxfw.SizedBox = .{
            .child = self.start_time.widget(),
            .size = .{ .width = 8, .height = 1 },
        };
        const start_time_border: vxfw.Border = .{
            .child = start_time_sized.widget(),
            .style = self.borderStyle(.start_time),
        };

        const start_time_row_children = try ctx.arena.alloc(vxfw.FlexItem, 2);
        start_time_row_children[0] = .{ .widget = start_time_label_box.widget(), .flex = 0 };
        start_time_row_children[1] = .{ .widget = start_time_border.widget(), .flex = 0 };
        const start_time_row: vxfw.FlexRow = .{ .children = start_time_row_children };
        const start_time_row_sized: vxfw.SizedBox = .{
            .child = start_time_row.widget(),
            .size = .{ .width = 40, .height = 3 },
        };

        // calculate
        const calculate_sized: vxfw.SizedBox = .{
            .child = self.calculate.widget(),
            .size = .{ .width = 9, .height = 1 },
        };
        const calculate_border: vxfw.Border = .{
            .child = calculate_sized.widget(),
            .style = self.borderStyle(.calculate),
        };

        const calculate_row_children = try ctx.arena.alloc(vxfw.FlexItem, 1);
        calculate_row_children[0] = .{ .widget = calculate_border.widget(), .flex = 0 };
        const calculate_row: vxfw.FlexRow = .{ .children = calculate_row_children };
        const calculate__row_sized: vxfw.SizedBox = .{
            .child = calculate_row.widget(),
            .size = .{ .width = 40, .height = 3 },
        };
        // Column
        const column_children = try ctx.arena.alloc(vxfw.FlexItem, 3);
        column_children[0] = .{ .widget = shift_length_row_sized.widget(), .flex = 0 };
        column_children[1] = .{ .widget = start_time_row_sized.widget(), .flex = 0 };
        column_children[2] = .{ .widget = calculate__row_sized.widget(), .flex = 0 };
        const column: vxfw.FlexColumn = .{ .children = column_children };

        const center: vxfw.Center = .{ .child = column.widget() };
        const center_subsurface: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try center.draw(ctx),
        };
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = center_subsurface;

        return .{
            .size = max_size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    fn calculateClockOut(_: ?*anyopaque, ctx: *vxfw.EventContext) anyerror!void {
        // const ptr = maybe_ptr orelse return;
        // const self: *Model = @ptrCast(@alignCast(ptr));
        // self.count +|= 1;
        return ctx.consumeAndRedraw();
    }

    fn borderStyle(self: *Model, field: Field) vaxis.Style {
        return if (self.focus == field)
            .{ .fg = .{ .index = 15 } }
        else
            .{};
    }

    fn box(w: vxfw.Widget) vxfw.SizedBox {
        return .{
            .child = w,
            .size = .{ .width = 11, .height = 3 },
        };
    }

    fn focusedWidget(self: *Model) vxfw.Widget {
        return switch (self.focus) {
            .shift_length => self.shift_length.widget(),
            .start_time => self.start_time.widget(),
            .calculate => self.calculate.widget(),
        };
    }

    fn focusNext(self: *Model, ctx: *vxfw.EventContext) !void {
        const n = @typeInfo(Field).@"enum".fields.len;
        self.focus = @enumFromInt((@intFromEnum(self.focus) + 1) % n);
        try ctx.requestFocus(self.focusedWidget());
    }

    fn focusPrev(self: *Model, ctx: *vxfw.EventContext) !void {
        const n = @typeInfo(Field).@"enum".fields.len;
        self.focus = @enumFromInt((@intFromEnum(self.focus) + n - 1) % n);
        try ctx.requestFocus(self.focusedWidget());
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    var buffer: [1024]u8 = undefined;
    var app: vxfw.App = try .init(io, alloc, init.environ_map, &buffer);
    defer app.deinit();

    const model = try alloc.create(Model);
    defer alloc.destroy(model);

    model.* = .{
        .shift_length_label = .{
            .text = "Shift Length",
            .text_align = .right,
        },
        .shift_length = .init(alloc),
        .hr_label = .{ .text = "hr" },
        .start_time_label = .{
            .text = "Clock In",
            .text_align = .right,
        },
        .start_time = .init(alloc),
        .calculate = .{
            .label = "Calculate",
            .onClick = Model.calculateClockOut,
            .userdata = model,
        },
    };
    defer {
        model.shift_length.deinit();
        model.start_time.deinit();
    }
    model.shift_length_label.style.bold = true;
    model.calculate.style.default = .{ .bg = .default };
    model.calculate.style.focus = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 5 } };

    try app.run(model.widget(), .{});
}
