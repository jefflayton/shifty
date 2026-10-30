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

/// An instant plus the zone it happened in, as recorded on shifts and
/// entries. The offset alone buckets days; `tz` covers DST and display.
pub const Stamp = struct {
    ts: i64,
    utc_offset_secs: i64,
    /// IANA name, e.g. `America/Chicago`; null if the system can't say.
    tz: ?[]const u8,

    /// The current instant in the local zone. `tz_env` is `$TZ`, if set;
    /// `tz` points into `buf`.
    pub fn now(io: Io, tz_env: ?[]const u8, buf: *TzBuf) Stamp {
        const ts = Io.Clock.real.now(io).toSeconds();
        return .{ .ts = ts, .utc_offset_secs = utcOffset(ts), .tz = tzName(io, tz_env, buf) };
    }
};

pub const TzBuf = [std.fs.max_path_bytes]u8;

/// The local IANA zone name: `$TZ` if it names one, else the target of the
/// `/etc/localtime` symlink (macOS and most Linux distros).
pub fn tzName(io: Io, tz_env: ?[]const u8, buf: *TzBuf) ?[]const u8 {
    if (tz_env) |env| {
        const tz = std.mem.trimStart(u8, env, ":");
        if (std.fs.path.isAbsolute(tz)) return tzFromPath(tz);
        return if (isZoneName(tz)) tz else null;
    }
    const len = Io.Dir.readLinkAbsolute(io, "/etc/localtime", buf) catch return null;
    return tzFromPath(buf[0..len]);
}

/// `/var/db/timezone/zoneinfo/America/Chicago` -> `America/Chicago`.
fn tzFromPath(path: []const u8) ?[]const u8 {
    const marker = "zoneinfo/";
    const i = std.mem.indexOf(u8, path, marker) orelse return null;
    const tz = path[i + marker.len ..];
    return if (isZoneName(tz)) tz else null;
}

/// Plausible IANA name: no POSIX rule strings (`CST6CDT` is a real zone, but
/// `<+03>-3` is not), no path tricks.
fn isZoneName(tz: []const u8) bool {
    if (tz.len == 0 or tz[0] == '/' or std.mem.indexOf(u8, tz, "..") != null) return false;
    for (tz) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '/', '_', '-', '+' => {},
        else => return false,
    };
    return true;
}

const testing = std.testing;

test "tzFromPath" {
    try testing.expectEqualStrings("America/Chicago", tzFromPath("/var/db/timezone/zoneinfo/America/Chicago").?);
    try testing.expectEqualStrings("Europe/London", tzFromPath("/usr/share/zoneinfo/Europe/London").?);
    try testing.expectEqualStrings("UTC", tzFromPath("/usr/share/zoneinfo/UTC").?);
    try testing.expectEqual(null, tzFromPath("/etc/localtime"));
    try testing.expectEqual(null, tzFromPath("/usr/share/zoneinfo/"));
}

test "tzName - TZ env wins" {
    var buf: TzBuf = undefined;
    const io = testing.io;
    try testing.expectEqualStrings("Asia/Tokyo", tzName(io, "Asia/Tokyo", &buf).?);
    try testing.expectEqualStrings("Asia/Tokyo", tzName(io, ":Asia/Tokyo", &buf).?);
    try testing.expectEqualStrings("Asia/Tokyo", tzName(io, "/usr/share/zoneinfo/Asia/Tokyo", &buf).?);
    try testing.expectEqual(null, tzName(io, "<+03>-3", &buf));
    try testing.expectEqual(null, tzName(io, "../etc/passwd", &buf));
}
