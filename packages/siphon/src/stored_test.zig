//! The files kept by their content: a person's as a model is given them, an image fitted to what every model reads; and
//! as a person's view draws them, a kept image fitted to a box, its shape kept and never enlarged, a kept file that is
//! no image, or none kept, drawing nothing.
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = @import("testing.zig");

const wide_png = testing.pngOf(64, 32);

/// The reference the bytes `bytes` are kept by.
fn refOf(arena: Allocator, bytes: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.mem.concat(arena, u8, &.{ "sha256:", &std.fmt.bytesToHex(digest, .lower) });
}

test "a kept image is drawn fitted to a box, its shape kept and never enlarged; a kept file that is no image has none" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    const ref = (try siphon.storeFile(arena, &wide_png)).ref;
    const drawn = try siphon.storedPicture(arena, ref, .{ .width_max = 48, .height_max = 16 });
    try std.testing.expectEqual(@as(u32, 32), drawn.size.width);
    try std.testing.expectEqual(@as(u32, 16), drawn.size.height);
    const whole = try siphon.storedPicture(arena, ref, .{ .width_max = 768, .height_max = 256 });
    try std.testing.expectEqual(@as(u32, 64), whole.size.width);
    try std.testing.expectEqual(@as(u32, 32), whole.size.height);
    try std.testing.expectError(error.NotAnImage, siphon.storedPicture(arena, (try siphon.storeFile(arena, "plain words\n")).ref, .{ .width_max = 48, .height_max = 16 }));
    try std.testing.expectError(error.NotFound, siphon.storedPicture(arena, try refOf(arena, "never kept"), .{ .width_max = 48, .height_max = 16 }));
}

test "a file a person gives a message is kept as a model is given it: an image fitted to what every model reads, any other as it came" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try testing.open(&clock, .memory);
    defer siphon.close();
    // A PNG a model reads whole is kept as it came.
    const png = try siphon.storeFile(arena, &wide_png);
    try std.testing.expectEqualStrings("image/png", png.media_type.?);
    try std.testing.expectEqualSlices(u8, &wide_png, try siphon.storedFile(arena, png.ref));
    // A GIF of one transparent pixel is written again as a PNG, which every provider's models read.
    const gif = "GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff\x21\xf9\x04\x01\x00\x00\x00\x00\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x3b";
    const written = try siphon.storeFile(arena, gif);
    try std.testing.expectEqualStrings("image/png", written.media_type.?);
    try std.testing.expect(std.mem.startsWith(u8, try siphon.storedFile(arena, written.ref), "\x89PNG"));
    // Any other file is kept as it came, what it is the client's to say.
    const pdf = try siphon.storeFile(arena, "%PDF-1.7 a page");
    try std.testing.expect(pdf.media_type == null);
    try std.testing.expectEqualStrings("%PDF-1.7 a page", try siphon.storedFile(arena, pdf.ref));
}
