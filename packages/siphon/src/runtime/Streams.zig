//! What streams of each request while its task acts on it, kept in the order it was published, so one who follows its
//! topic later reads it from the start, each event by its offset, as a reader of a log reads on from an offset; let go
//! once the request's task ends, its answer then in its fiber's hands. A stream past its bound is kept no further, its
//! later events told as they come alone, so what is kept of it never skips one.
const Streams = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

/// How many bytes of one stream are kept at most.
pub const stream_bytes_max = 8 << 20;

allocator: Allocator,
/// The streams, by their request's key.
by_key: std.StringArrayHashMapUnmanaged(Stream) = .empty,

/// A stream: its topic; what was published of it and kept, in order, from offset 0; how many events were published,
/// kept or not; the bytes kept; and whether it passed its bound, keeping no more.
pub const Stream = struct {
    topic: []const u8,
    kept: std.ArrayList([]const u8) = .empty,
    count: u64 = 0,
    bytes: usize = 0,
    full: bool = false,
};

pub fn deinit(streams: *Streams) void {
    for (streams.by_key.keys(), streams.by_key.values()) |key, *stream| {
        streams.allocator.free(key);
        streams.free(stream);
    }
    streams.by_key.deinit(streams.allocator);
}

/// Adds `data`, published on `topic` for `key`, to its stream, kept where the stream is within its bound: its offset.
pub fn append(streams: *Streams, topic: []const u8, key: []const u8, data: []const u8) Allocator.Error!u64 {
    const allocator = streams.allocator;
    const slot = try streams.by_key.getOrPut(allocator, key);
    if (!slot.found_existing) {
        errdefer streams.by_key.swapRemoveAt(slot.index);
        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        slot.value_ptr.* = .{ .topic = try allocator.dupe(u8, topic) };
        slot.key_ptr.* = owned_key;
    }
    const stream = slot.value_ptr;
    const offset = stream.count;
    stream.count += 1;
    if (stream.full or stream.bytes + data.len > stream_bytes_max) {
        stream.full = true;
        return offset;
    }
    const copy = try allocator.dupe(u8, data);
    errdefer allocator.free(copy);
    try stream.kept.append(allocator, copy);
    stream.bytes += data.len;
    return offset;
}

/// Lets go of the stream of `key`, where there is one.
pub fn end(streams: *Streams, key: []const u8) void {
    const removed = streams.by_key.fetchSwapRemove(key) orelse return;
    streams.allocator.free(removed.key);
    var stream = removed.value;
    streams.free(&stream);
}

fn free(streams: *Streams, stream: *Stream) void {
    for (stream.kept.items) |data| streams.allocator.free(data);
    stream.kept.deinit(streams.allocator);
    streams.allocator.free(stream.topic);
}

test "a stream keeps what was published, by offset, to its bound and no further, till it ends" {
    var streams: Streams = .{ .allocator = std.testing.allocator };
    defer streams.deinit();
    try std.testing.expectEqual(@as(u64, 0), try streams.append("t", "k", "one"));
    try std.testing.expectEqual(@as(u64, 1), try streams.append("t", "k", "two"));
    try std.testing.expectEqual(@as(u64, 0), try streams.append("t", "other", "x"));
    const kept = streams.by_key.get("k").?;
    try std.testing.expectEqualStrings("t", kept.topic);
    try std.testing.expectEqual(@as(usize, 2), kept.kept.items.len);
    // Past its bound, a stream keeps no more, though a later event would fit: what it keeps never skips one.
    const big = try std.testing.allocator.alloc(u8, stream_bytes_max);
    defer std.testing.allocator.free(big);
    try std.testing.expectEqual(@as(u64, 2), try streams.append("t", "k", big));
    try std.testing.expectEqual(@as(u64, 3), try streams.append("t", "k", "small"));
    try std.testing.expectEqual(@as(usize, 2), streams.by_key.get("k").?.kept.items.len);
    streams.end("k");
    try std.testing.expect(streams.by_key.get("k") == null);
    streams.end("never");
}
