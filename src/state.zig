var tz_buf: [64]u8 = undefined;
var tz_len: usize = 0;

pub fn setTimezone(tz: []const u8) void {
    const n = @min(tz.len, tz_buf.len);
    @memcpy(tz_buf[0..n], tz[0..n]);
    tz_len = n;
}

pub fn getTimezone() []const u8 {
    return tz_buf[0..tz_len];
}
