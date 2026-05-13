const std = @import("std");
const mem = std.mem;

const menubar = @import("menubar");

const router = @import("router.zig").router;

var gResponse: menubar.MenuActionResponse = null;

fn onMenuAction(action: [*c]const u8, params: [*c]const u8) callconv(.c) void {
    const action_slice = mem.span(action);
    const params_slice = mem.span(params);
    if (mem.eql(u8, action_slice, "quit")) {
        std.process.exit(0);
    } else if (mem.eql(u8, action_slice, "open")) {
        std.debug.print("open!\n", .{});
    } else {
        const handler = router.get(action_slice) orelse return;
        const result = handler(params_slice);
        if (result.len > 0) {
            if (gResponse) |resp| {
                var ack_buf: [256]u8 = undefined;
                var result_buf: [256]u8 = undefined;
                const ack = std.fmt.bufPrintZ(&ack_buf, "{s}_ack", .{action_slice}) catch return;
                const result_z = std.fmt.bufPrintZ(&result_buf, "{s}", .{result}) catch return;
                std.debug.print("{s}:{d}: ack={s} result={s}\n", .{ @src().file, @src().line, ack, result_z });
                resp(ack.ptr, result_z.ptr);
            }
        }
    }
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    menubar.runMenuBarApp(onMenuAction, &gResponse);
}
