//! The size of an image in pixels, read from the header of a PNG, JPEG, GIF or WebP file without decoding the image,
//! so that a request is checked against its model's input limits before it is sent.
const std = @import("std");

pub const Size = struct { width: u32, height: u32 };

/// The size of the image `bytes` hold; null for a file of another format or a header cut short.
pub fn of(bytes: []const u8) ?Size {
    return png(bytes) orelse gif(bytes) orelse webp(bytes) orelse jpeg(bytes);
}

fn png(bytes: []const u8) ?Size {
    if (!at(bytes, 0, "\x89PNG\r\n\x1a\n") or !at(bytes, 12, "IHDR")) return null;
    return sized(number(bytes, 16, 4, .big), number(bytes, 20, 4, .big));
}

fn gif(bytes: []const u8) ?Size {
    if (!at(bytes, 0, "GIF8")) return null;
    return sized(number(bytes, 6, 2, .little), number(bytes, 8, 2, .little));
}

/// A WebP's size, from its first chunk: a lossy, lossless or extended one.
fn webp(bytes: []const u8) ?Size {
    if (!at(bytes, 0, "RIFF") or !at(bytes, 8, "WEBP")) return null;
    const mask = (1 << 14) - 1;
    if (at(bytes, 12, "VP8 ")) {
        if (!at(bytes, 23, "\x9d\x01\x2a")) return null;
        const width = number(bytes, 26, 2, .little) orelse return null;
        const height = number(bytes, 28, 2, .little) orelse return null;
        return sized(width & mask, height & mask);
    }
    if (at(bytes, 12, "VP8L")) {
        if (bytes.len <= 20 or bytes[20] != 0x2f) return null;
        const size = number(bytes, 21, 4, .little) orelse return null;
        return sized((size & mask) + 1, ((size >> 14) & mask) + 1);
    }
    if (at(bytes, 12, "VP8X")) {
        const width = number(bytes, 24, 3, .little) orelse return null;
        const height = number(bytes, 27, 3, .little) orelse return null;
        return sized(width + 1, height + 1);
    }
    return null;
}

/// A JPEG's size, from its start-of-frame segment, found by walking its segments from the start of the image.
fn jpeg(bytes: []const u8) ?Size {
    if (!at(bytes, 0, "\xff\xd8")) return null;
    var place: usize = 2;
    while (place + 1 < bytes.len) {
        if (bytes[place] != 0xff) return null;
        const marker = bytes[place + 1];
        // A marker may be padded with more 0xFF bytes before it.
        if (marker == 0xff) {
            place += 1;
            continue;
        }
        if (marker >= 0xc0 and marker <= 0xcf and marker != 0xc4 and marker != 0xc8 and marker != 0xcc) {
            return sized(number(bytes, place + 7, 2, .big), number(bytes, place + 5, 2, .big));
        }
        // The restarts, the start and end of the image, and TEM stand alone, without a length.
        if ((marker >= 0xd0 and marker <= 0xd9) or marker == 0x01) {
            place += 2;
            continue;
        }
        const length = number(bytes, place + 2, 2, .big) orelse return null;
        place += 2 + length;
    }
    return null;
}

fn sized(width: ?u32, height: ?u32) ?Size {
    return .{ .width = width orelse return null, .height = height orelse return null };
}

fn at(bytes: []const u8, place: usize, expected: []const u8) bool {
    return bytes.len >= place + expected.len and std.mem.eql(u8, bytes[place..][0..expected.len], expected);
}

/// The unsigned number of `count` bytes from `place`, in `order`; null where they run past the end.
fn number(bytes: []const u8, place: usize, comptime count: usize, order: std.builtin.Endian) ?u32 {
    if (bytes.len < place + count) return null;
    var value: u32 = 0;
    for (0..count) |index| {
        const byte = bytes[if (order == .big) place + index else place + count - 1 - index];
        value = value * 256 + byte;
    }
    return value;
}

test "an image's size is read from its header" {
    const png_header = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x02\x80\x00\x00\x01\xe0";
    try std.testing.expectEqual(Size{ .width = 640, .height = 480 }, of(png_header).?);
    try std.testing.expectEqual(Size{ .width = 3, .height = 2 }, of("GIF89a\x03\x00\x02\x00").?);
    const jpeg_header = "\xff\xd8\xff\xe0\x00\x04ab\xff\xc0\x00\x11\x08\x00\x20\x00\x40";
    try std.testing.expectEqual(Size{ .width = 64, .height = 32 }, of(jpeg_header).?);
    try std.testing.expectEqual(null, of("%PDF-1.7"));
}
