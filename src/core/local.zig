//! Local wall-clock time. Zig's std has no timezone support, so this asks libc.

const std = @import("std");
const Io = std.Io;

const Time = @import("time.zig").Time;

/// Matches `struct tm` on Darwin, glibc, and musl.
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(timep: *const c_long, result: *Tm) ?*Tm;

/// Seconds east of UTC for the local timezone at unix timestamp `ts`.
pub fn utcOffset(ts: i64) i64 {
    var tm: Tm = undefined;
    const t: c_long = @intCast(ts);
    if (localtime_r(&t, &tm) == null) return 0;
    return tm.gmtoff;
}

/// The current local time of day.
pub fn now(io: Io) Time {
    const ts = Io.Clock.real.now(io).toSeconds();
    return Time.fromTs(ts + utcOffset(ts));
}
