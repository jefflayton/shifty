//! Everything the macOS app calls through shifty.h.

comptime {
    _ = @import("core").ffi;
    _ = @import("store").ffi;
}
