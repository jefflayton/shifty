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
        var result_buf: [256]u8 = undefined;
        const len = handler(params_slice, &result_buf);
        if (len > 0) {
            if (gResponse) |resp| {
                var ack_buf: [256]u8 = undefined;
                const ack = std.fmt.bufPrintZ(&ack_buf, "{s}_ack", .{action_slice}) catch return;
                result_buf[len] = 0;
                resp(ack.ptr, result_buf[0..len :0].ptr);
            }
        }
    }
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    menubar.runMenuBarApp(onMenuAction, &gResponse);
}
