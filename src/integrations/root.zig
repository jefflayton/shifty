//! Optional bridges to other tools. Each one maps a tool's own ids onto the
//! store's `links`; Shifty works without any of them.

test {
    _ = @import("situ.zig");
}

pub const situ = @import("situ.zig");
