//! Ids: UUIDs of version 7, their time first, and the mint `Models` keeps where the host gives none — each id later
//! than the one before it, however the clock moves.
const std = @import("std");
const driver = @import("driver.zig");

pub const Uuid = [16]u8;

/// The id after `last` at `time_ms`: a new version 7, its other bits `random`, where the clock is past the last id's
/// time; else the last one higher, its random bits counting up into its time, so ids rise strictly. Past the year
/// 10889 there is no later id, and the last is given again.
pub fn next(last: ?Uuid, time_ms: i64, random: Uuid) Uuid {
    if (last) |given| if (time_ms <= timeOf(given)) return successor(given) orelse given;
    var out = random;
    const time: u48 = @intCast(std.math.clamp(time_ms, 0, std.math.maxInt(u48)));
    std.mem.writeInt(u48, out[0..6], time, .big);
    out[6] = 0x70 | (out[6] & 0x0f);
    out[8] = 0x80 | (out[8] & 0x3f);
    return out;
}

/// The time in a version 7 UUID: its first 48 bits.
pub fn timeOf(id: Uuid) i64 {
    return std.mem.readInt(u48, id[0..6], .big);
}

/// The bits of each byte that count: all but the version (the high half of byte 6) and the variant (the high two bits
/// of byte 8).
const counting_bits = [16]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x0f, 0xff, 0x3f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };

/// `id` one higher in its counting bits, or null where every one is set.
fn successor(id: Uuid) ?Uuid {
    var out = id;
    var index: usize = out.len;
    while (index > 0) {
        index -= 1;
        const mask = counting_bits[index];
        const value = out[index] & mask;
        if (value != mask) {
            out[index] = (out[index] & ~mask) | (value + 1);
            return out;
        }
        out[index] &= ~mask;
    }
    return null;
}

/// `id` as text: lowercase hex in the groups 8-4-4-4-12.
pub fn format(id: Uuid) [36]u8 {
    const hex = std.fmt.bytesToHex(id, .lower);
    var out: [36]u8 = undefined;
    @memcpy(out[0..8], hex[0..8]);
    out[8] = '-';
    @memcpy(out[9..13], hex[8..12]);
    out[13] = '-';
    @memcpy(out[14..18], hex[12..16]);
    out[18] = '-';
    @memcpy(out[19..23], hex[16..20]);
    out[23] = '-';
    @memcpy(out[24..36], hex[20..32]);
    return out;
}

/// The mint over the host's clock and randomness, one id at a time.
pub const Minter = struct {
    host: *const driver.Host,
    last: ?Uuid = null,
    lock: std.Io.Mutex = .init,

    pub fn mint(minter: *Minter) driver.Mint {
        return .{ .context = minter, .vtable = &.{ .mint = mintNext } };
    }

    fn mintNext(context: *anyopaque) [36]u8 {
        const minter: *Minter = @ptrCast(@alignCast(context));
        const io = minter.host.io;
        minter.lock.lockUncancelable(io);
        defer minter.lock.unlock(io);
        var random: Uuid = undefined;
        minter.host.randomBytes(&random);
        const id = next(minter.last, minter.host.nowMs(), random);
        minter.last = id;
        return format(id);
    }
};

test "minted ids rise strictly as text, through a clock that stands still or goes back" {
    var prng = std.Random.DefaultPrng.init(3);
    var last: ?Uuid = null;
    var last_text: [36]u8 = undefined;
    for ([_]i64{ 1_000, 1_000, 1_000, 999, 5_000, 4_000, 4_000, 6_000 }, 0..) |time, index| {
        var random: Uuid = undefined;
        prng.random().bytes(&random);
        const id = next(last, time, random);
        const text = format(id);
        try std.testing.expectEqual(@as(u8, '7'), text[14]);
        try std.testing.expect(std.mem.indexOfScalar(u8, "89ab", text[19]) != null);
        if (index > 0) try std.testing.expect(std.mem.order(u8, &last_text, &text) == .lt);
        last = id;
        last_text = text;
    }
    try std.testing.expectEqual(@as(i64, 6_000), timeOf(last.?));
}

test "an id counts up into its time where its random bits are full" {
    var id: Uuid = @splat(0xff);
    id[0] = 0;
    id[1] = 0;
    id[2] = 0;
    id[3] = 0;
    id[4] = 0;
    id[5] = 1;
    id[6] = 0x7f;
    id[8] = 0xbf;
    const later = next(id, 0, @splat(0));
    try std.testing.expectEqual(@as(i64, 2), timeOf(later));
    try std.testing.expectEqual(@as(u8, 0x70), later[6]);
    try std.testing.expectEqual(@as(u8, 0x80), later[8]);
    var last: Uuid = @splat(0xff);
    last[6] = 0x7f;
    last[8] = 0xbf;
    try std.testing.expectEqualSlices(u8, &last, &next(last, 0, @splat(0)));
}
