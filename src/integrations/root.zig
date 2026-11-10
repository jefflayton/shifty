//! Optional bridges to other tools. Each one maps a tool's own ids onto the
//! store's `links`; Shifty works without any of them.

test {
    _ = @import("situ.zig");
    _ = @import("git.zig");
    _ = @import("place.zig");
    _ = @import("here.zig");
    _ = @import("ffi.zig");
    _ = @import("clock_link.zig");
}

pub const clock_link = @import("clock_link.zig");

pub const situ = @import("situ.zig");
pub const git = @import("git.zig");
pub const place = @import("place.zig");
pub const here = @import("here.zig");
pub const ffi = @import("ffi.zig");
