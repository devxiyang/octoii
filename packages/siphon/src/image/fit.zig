//! An image fitted within bounds: decoded by Wuffs — PNG, JPEG, GIF's first frame, WebP, BMP or QOI — memory-safely,
//! as an image may come from anywhere; kept as it is where it already fits and its format is one the bounds keep; else
//! resized in sRGB and written again by stb: as a PNG, losing nothing, where it fits and is translucent or no larger
//! than a JPEG of it — as a screenshot or a drawing is — else as a JPEG, as a photograph is, its quality lowered till it
//! fits.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// The formats an image is read from.
pub const Format = enum { png, jpeg, gif, webp, bmp, qoi };

/// A set of formats an image may stay in as it is.
pub const Formats = std.EnumSet(Format);

/// The formats models and browsers read, which a fitting keeps unless its bounds say fewer.
pub const read_everywhere: Formats = .initMany(&.{ .png, .jpeg, .gif, .webp });

/// The box an image is fitted to — the widest and the tallest it may be, its pixels and its bytes — and the formats it
/// may stay in as it is, of those models and browsers read.
pub const Bounds = struct { width_max: u32, height_max: u32, pixels_max: u64, bytes_max: usize, formats: Formats = read_everywhere };

pub const Size = struct { width: u32, height: u32 };

/// An image fitted: what it is, its bytes, its size, and the size it came at.
pub const Fitted = struct { media_type: []const u8, bytes: []const u8, size: Size, original: Size };

/// What a fitting may come to: bytes that are no image of a format read; an image of one that does not decode; one of
/// more pixels than are decoded, or that fits no bytes the bounds give; or memory not had.
pub const Error = error{ OutOfMemory, NotAnImage, Malformed, TooLarge };

/// The most pixels an image may have to be decoded at all: past it, its memory is never taken.
const decode_pixels_max: u64 = 64_000_000;

/// The qualities a JPEG is written at, the first where it fits the bounds' bytes.
const jpeg_qualities = [_]u8{ 85, 70, 55, 40, 25 };

extern fn siphon_image_decode(data: [*]const u8, len: usize, pixels_max: u64, width: *u32, height: *u32, format: *c_int, pixels: *?[*]u8) c_int;
extern fn siphon_image_resize(pixels: [*]const u8, width: u32, height: u32, into: [*]u8, to_width: u32, to_height: u32) c_int;
extern fn siphon_image_write_png(pixels: [*]const u8, width: u32, height: u32, bytes: *?[*]u8, len: *usize) c_int;
extern fn siphon_image_write_jpeg(pixels: [*]const u8, width: u32, height: u32, quality: c_int, bytes: *?[*]u8, len: *usize) c_int;
extern fn siphon_image_free(bytes: ?*anyopaque) void;

/// The error a call of the C beneath came to; none where it went well.
fn check(result: c_int) Error!void {
    return switch (result) {
        0 => {},
        1 => error.NotAnImage,
        2 => error.Malformed,
        3 => error.TooLarge,
        else => error.OutOfMemory,
    };
}

/// The image in `bytes` within `bounds`, as the file's comment says; its bytes `bytes` themselves where it is kept, else
/// in `arena`.
pub fn fitted(arena: Allocator, bytes: []const u8, bounds: Bounds) Error!Fitted {
    var width: u32 = 0;
    var height: u32 = 0;
    var format: c_int = 0;
    var decoded: ?[*]u8 = null;
    try check(siphon_image_decode(bytes.ptr, bytes.len, decode_pixels_max, &width, &height, &format, &decoded));
    defer siphon_image_free(decoded);
    const pixels = decoded.?[0 .. @as(usize, width) * height * 4];
    const from: Format = @fromBackingInt(@intCast(format));
    const original: Size = .{ .width = width, .height = height };
    const size = sizeWithin(width, height, bounds);
    const same = std.meta.eql(size, original);
    if (same and bounds.formats.contains(from) and read_everywhere.contains(from) and bytes.len <= bounds.bytes_max) {
        return .{ .media_type = mediaTypeOf(from), .bytes = bytes, .size = size, .original = original };
    }
    const sized = if (same) pixels else try resized(arena, pixels, original, size);
    const png: Fitted = .{ .media_type = "image/png", .bytes = try written(arena, sized, size, .png), .size = size, .original = original };
    if (png.bytes.len <= bounds.bytes_max) {
        if (translucent(sized)) return png;
        const jpeg = try written(arena, sized, size, .{ .jpeg = jpeg_qualities[0] });
        return if (png.bytes.len <= jpeg.len) png else .{ .media_type = "image/jpeg", .bytes = jpeg, .size = size, .original = original };
    }
    for (jpeg_qualities) |quality| {
        const jpeg = try written(arena, sized, size, .{ .jpeg = quality });
        if (jpeg.len <= bounds.bytes_max) return .{ .media_type = "image/jpeg", .bytes = jpeg, .size = size, .original = original };
    }
    return error.TooLarge;
}

/// `width` by `height` scaled down, its shape kept, to fit `bounds`' box and pixels; as it is where it fits; never a
/// side under one pixel. The side that bounds it most is met exactly, its scale a fraction; the pixels, bounding it more,
/// by the square root of theirs.
pub fn sizeWithin(width: u32, height: u32, bounds: Bounds) Size {
    var over: u64 = 1;
    var under: u64 = 1;
    if (@as(u64, bounds.width_max) * under < over * width) {
        over = bounds.width_max;
        under = width;
    }
    if (@as(u64, bounds.height_max) * under < over * height) {
        over = bounds.height_max;
        under = height;
    }
    var w: u64 = @max(1, width * over / under);
    var h: u64 = @max(1, height * over / under);
    if (w * h > bounds.pixels_max) {
        const scale = @sqrt(@as(f64, @floatFromInt(bounds.pixels_max)) / @as(f64, @floatFromInt(w * h)));
        w = @max(1, @as(u64, @intFromFloat(@as(f64, @floatFromInt(w)) * scale)));
        h = @max(1, @as(u64, @intFromFloat(@as(f64, @floatFromInt(h)) * scale)));
        // A scale rounded up past an exact side is taken back a pixel at a time, off the longer side.
        while (w * h > bounds.pixels_max and @max(w, h) > 1) {
            if (w > h) w -= 1 else h -= 1;
        }
    }
    return .{ .width = @intCast(w), .height = @intCast(h) };
}

/// The media type of an image in `format`.
fn mediaTypeOf(format: Format) []const u8 {
    return switch (format) {
        .png => "image/png",
        .jpeg => "image/jpeg",
        .gif => "image/gif",
        .webp => "image/webp",
        .bmp => "image/bmp",
        .qoi => "image/qoi",
    };
}

/// RGBA `pixels` of `from` resized to `to`, in `arena`.
fn resized(arena: Allocator, pixels: []const u8, from: Size, to: Size) Error![]const u8 {
    const into = try arena.alloc(u8, @as(usize, to.width) * to.height * 4);
    try check(siphon_image_resize(pixels.ptr, from.width, from.height, into.ptr, to.width, to.height));
    return into;
}

/// Whether any of RGBA `pixels` lets what is behind it through.
fn translucent(pixels: []const u8) bool {
    var at: usize = 3;
    while (at < pixels.len) : (at += 4) if (pixels[at] != 255) return true;
    return false;
}

/// RGBA `pixels` of `size` written as a PNG, or as a JPEG of a quality, in `arena`.
fn written(arena: Allocator, pixels: []const u8, size: Size, as: union(enum) { png, jpeg: u8 }) Error![]const u8 {
    var bytes: ?[*]u8 = null;
    var len: usize = 0;
    try check(switch (as) {
        .png => siphon_image_write_png(pixels.ptr, size.width, size.height, &bytes, &len),
        .jpeg => |quality| siphon_image_write_jpeg(pixels.ptr, size.width, size.height, quality, &bytes, &len),
    });
    defer siphon_image_free(bytes);
    return arena.dupe(u8, bytes.?[0..len]);
}

/// A width by height image of the pixels `paint` gives, written as a PNG, for the tests.
fn testPng(arena: Allocator, width: u32, height: u32, comptime paint: fn (x: u32, y: u32) [4]u8) ![]const u8 {
    const pixels = try arena.alloc(u8, @as(usize, width) * height * 4);
    for (0..height) |y| for (0..width) |x| {
        pixels[(y * width + x) * 4 ..][0..4].* = paint(@intCast(x), @intCast(y));
    };
    return written(arena, pixels, .{ .width = width, .height = height }, .png);
}

fn grey(_: u32, _: u32) [4]u8 {
    return .{ 128, 128, 128, 255 };
}

fn seeThrough(_: u32, _: u32) [4]u8 {
    return .{ 128, 128, 128, 100 };
}

/// Black and white by the pixel, as the finest drawing is: what a JPEG writes worst.
fn checkered(x: u32, y: u32) [4]u8 {
    const shade: u8 = if ((x + y) % 2 == 0) 0 else 255;
    return .{ shade, shade, shade, 255 };
}

/// Every pixel a colour of its own, as a photograph's grain is: what a PNG writes worst.
fn noise(x: u32, y: u32) [4]u8 {
    const hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&[2]u32{ x, y }));
    return .{ @truncate(hash), @truncate(hash >> 8), @truncate(hash >> 16), 255 };
}

test "an image is kept where it fits its bounds and its format is one they keep, else fitted and written again" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bounds: Bounds = .{ .width_max = 1568, .height_max = 1568, .pixels_max = 1_150_000, .bytes_max = 3_750_000 };
    try std.testing.expectEqual(Size{ .width = 1568, .height = 522 }, sizeWithin(3000, 1000, bounds));
    try std.testing.expectEqual(Size{ .width = 1072, .height = 1072 }, sizeWithin(2000, 2000, bounds));
    try std.testing.expectEqual(Size{ .width = 800, .height = 600 }, sizeWithin(800, 600, bounds));

    const small = try testPng(arena, 100, 50, grey);
    const kept = try fitted(arena, small, bounds);
    try std.testing.expectEqual(small.ptr, kept.bytes.ptr);
    try std.testing.expectEqualStrings("image/png", kept.media_type);

    // Past the box, an image is resized, its shape kept; written again as a PNG where it is translucent or no larger
    // than a JPEG of it, as a fine drawing is, else as a JPEG, as a photograph is.
    const wide = try fitted(arena, try testPng(arena, 3000, 1000, grey), bounds);
    try std.testing.expectEqual(Size{ .width = 1568, .height = 522 }, wide.size);
    try std.testing.expectEqual(Size{ .width = 3000, .height = 1000 }, wide.original);
    try std.testing.expectEqualStrings("image/jpeg", (try fitted(arena, try testPng(arena, 2000, 1000, noise), bounds)).media_type);
    try std.testing.expectEqualStrings("image/png", (try fitted(arena, try testPng(arena, 2000, 400, seeThrough), bounds)).media_type);
    var any_written = bounds;
    any_written.formats = .empty;
    try std.testing.expectEqualStrings("image/png", (try fitted(arena, try testPng(arena, 256, 256, checkered), any_written)).media_type);

    // A GIF of one transparent pixel fits, and stays a GIF but where the bounds keep PNG and JPEG alone.
    const gif = "GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff\x21\xf9\x04\x01\x00\x00\x00\x00\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x3b";
    try std.testing.expectEqualStrings("image/gif", (try fitted(arena, gif, bounds)).media_type);
    var two = bounds;
    two.formats = .initMany(&.{ .png, .jpeg });
    const written_again = try fitted(arena, gif, two);
    try std.testing.expectEqualStrings("image/png", written_again.media_type);
    try std.testing.expect(std.mem.startsWith(u8, written_again.bytes, "\x89PNG"));

    try std.testing.expectError(error.NotAnImage, fitted(arena, "plain words", bounds));
}
