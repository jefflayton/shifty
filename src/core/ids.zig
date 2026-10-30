//! Row ids: UUIDv7, so ids sort by creation time and clients can mint them
//! offline without a server handing out integers.

const std = @import("std");
const Io = std.Io;

pub const Uuid = struct {
    bytes: [16]u8,

    /// A new UUIDv7 stamped with the current time.
    pub fn v7(io: Io) Uuid {
        const ms: u64 = @intCast(Io.Clock.real.now(io).toMilliseconds());
        var rand: [10]u8 = undefined;
        io.random(&rand);
        return .v7At(ms, rand);
    }

    /// RFC 9562 layout: 48-bit unix ms, version 7, 74 random bits, variant 10.
    pub fn v7At(ms: u64, rand: [10]u8) Uuid {
        var b: [16]u8 = undefined;
        std.mem.writeInt(u48, b[0..6], @truncate(ms), .big);
        @memcpy(b[6..], &rand);
        b[6] = 0x70 | (b[6] & 0x0f);
        b[8] = 0x80 | (b[8] & 0x3f);
        return .{ .bytes = b };
    }

    pub fn eql(a: Uuid, b: Uuid) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    /// Canonical lowercase form, e.g. `0190f5c4-929e-71ca-888c-d75111ac0f15`.
    pub fn toStr(u: Uuid) [36]u8 {
        const hex = "0123456789abcdef";
        var out: [36]u8 = undefined;
        var o: usize = 0;
        for (u.bytes, 0..) |byte, i| {
            if (i == 4 or i == 6 or i == 8 or i == 10) {
                out[o] = '-';
                o += 1;
            }
            out[o] = hex[byte >> 4];
            out[o + 1] = hex[byte & 0x0f];
            o += 2;
        }
        return out;
    }

    /// Accepts the canonical form or 32 bare hex digits, any case.
    pub fn parse(str: []const u8) error{InvalidUuid}!Uuid {
        var u: Uuid = .{ .bytes = undefined };
        var n: usize = 0;
        var i: usize = 0;
        while (i < str.len) {
            if (str[i] == '-' and str.len == 36) {
                i += 1;
                continue;
            }
            if (n == 16 or i + 1 >= str.len) return error.InvalidUuid;
            const hi = std.fmt.charToDigit(str[i], 16) catch return error.InvalidUuid;
            const lo = std.fmt.charToDigit(str[i + 1], 16) catch return error.InvalidUuid;
            u.bytes[n] = (hi << 4) | lo;
            n += 1;
            i += 2;
        }
        if (n != 16) return error.InvalidUuid;
        return u;
    }
};

const testing = std.testing;

test "v7At - layout" {
    const u: Uuid = .v7At(0x0190f5c4929e, @splat(0xff));
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x90, 0xf5, 0xc4, 0x92, 0x9e }, u.bytes[0..6]);
    try testing.expectEqual(0x7f, u.bytes[6]);
    try testing.expectEqual(0xbf, u.bytes[8]);
}

test "v7At - sorts by time" {
    const a: Uuid = .v7At(1000, @splat(0xff));
    const b: Uuid = .v7At(1001, @splat(0x00));
    try testing.expect(std.mem.order(u8, &a.bytes, &b.bytes) == .lt);
}

test "toStr / parse round trip" {
    const u: Uuid = .v7At(0x0190f5c4929e, .{ 0x01, 0xca, 0x88, 0x8c, 0xd7, 0x51, 0x11, 0xac, 0x0f, 0x15 });
    const s = u.toStr();
    try testing.expectEqualStrings("0190f5c4-929e-71ca-888c-d75111ac0f15", &s);
    try testing.expect(u.eql(try Uuid.parse(&s)));
    try testing.expect(u.eql(try Uuid.parse("0190F5C4929E71CA888CD75111AC0F15")));
}

test "parse - rejects bad input" {
    try testing.expectError(error.InvalidUuid, Uuid.parse(""));
    try testing.expectError(error.InvalidUuid, Uuid.parse("0190f5c4-929e-71ca-888c-d75111ac0f1"));
    try testing.expectError(error.InvalidUuid, Uuid.parse("0190f5c4-929e-71ca-888c-d75111ac0f1g"));
    try testing.expectError(error.InvalidUuid, Uuid.parse("0190f5c4929e71ca888cd75111ac0f15ab"));
}
