const std = @import("std");
const mem = std.mem;

const menubar = @import("menubar");

fn onMenuAction(action: [*c]const u8) callconv(.c) void {
    const name = mem.span(action);
    if (mem.eql(u8, name, "quit")) {
        std.process.exit(0);
    } else if (std.mem.eql(u8, name, "open")) {
        // open your main window, do work, etc.
        std.debug.print("open!\n", .{});
    }
}

pub fn main() !void {
    menubar.runMenuBarApp(onMenuAction);
}
