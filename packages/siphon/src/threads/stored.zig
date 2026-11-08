//! The files a thread's conversation holds — an image pasted, a PDF attached, an image a call read — kept on the volume
//! by their content, as git keeps a blob: under `siphon.files/` by the SHA-256 of their bytes, written once and never
//! changed, the same bytes kept once however often they are given. A message names one by its reference, `sha256:` and
//! the hash, and its bytes are read as the message is sent to a model, so the log holds the reference alone. An image
//! is kept as a model is given one — fitted to what every provider's models read — as it comes into the conversation,
//! a person's sent to be kept or a call's read, so what the log names is what every model takes; and it is read too as
//! a picture fitted to a box, as a person's view draws one small.
const std = @import("std");
const Allocator = std.mem.Allocator;
const beak = @import("../beak.zig");
const image = @import("../image.zig");
const runtime_ = @import("../runtime.zig");
const Runtime = runtime_.Runtime;
const Changes = runtime_.Changes;

/// The directory the files are kept in.
const root = "siphon.files";

/// What a reference begins with, before the hash in lowercase hex.
const scheme = "sha256:";

/// The most bytes a file kept may hold.
pub const bytes_max = 32 << 20;

/// Keeps `bytes` as a file, from any task: its reference, the one it had where the same bytes were kept before;
/// error.TooLarge past `bytes_max`.
pub fn put(runtime: *Runtime, arena: Allocator, bytes: []const u8) ![]const u8 {
    if (bytes.len > bytes_max) return error.TooLarge;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const ref = try std.mem.concat(arena, u8, &.{ scheme, &std.fmt.bytesToHex(digest, .lower) });
    const path = try pathOf(arena, ref);
    if (try runtime.volume.stat(&arena, path) != null) return ref;
    var changes: Changes = .{ .arena = arena };
    try changes.mkdir(root);
    try changes.write(path, bytes);
    _ = try runtime.commit(&changes);
    return ref;
}

/// The bytes of the file `ref` names, from any task; error.NotFound where none is kept, error.NotAReference where `ref`
/// is none.
pub fn read(volume: beak.Volume, arena: Allocator, ref: []const u8) ![]const u8 {
    const path = try pathOf(arena, ref);
    if (try volume.stat(&arena, path) == null) return error.NotFound;
    return volume.readAll(&arena, path);
}

/// The box a picture is fitted to as a person's view draws an image small — a file kept, or one of a machine's as a
/// client reads it: the widest and the tallest it may be, in pixels.
pub const Box = struct { width_max: u32, height_max: u32 };

/// The sides a box may have, and the bytes a picture fitted to one may take.
const side_min = 16;
const side_max = 4096;
const picture_bytes_max = 1 << 20;

/// The image `ref` names fitted to `box`, as `pictureOf` fits one, from any task; error.NotAnImage where the file kept
/// is none, error.NotFound where none is kept, error.NotAReference where `ref` is none.
pub fn picture(volume: beak.Volume, arena: Allocator, ref: []const u8, box: Box) !image.Fitted {
    return pictureOf(arena, try read(volume, arena, ref), box);
}

/// The image `bytes` fitted to `box` as a person's view draws one small, its shape kept and never enlarged: each side
/// within 16 and 4096, the pixels of the box, a megabyte, in a format a browser draws; error.NotAnImage where they are
/// none.
pub fn pictureOf(arena: Allocator, bytes: []const u8, box: Box) image.Error!image.Fitted {
    const width = std.math.clamp(box.width_max, side_min, side_max);
    const height = std.math.clamp(box.height_max, side_min, side_max);
    return image.fitted(arena, bytes, .{ .width_max = width, .height_max = height, .pixels_max = @as(u64, width) * height, .bytes_max = picture_bytes_max });
}

/// The bounds an image is fitted to as a model is given it, its shape kept and never enlarged: some 1.15 million
/// pixels, its longest side 1568 at most, 3.75 MB at most, and a PNG or a JPEG — what every provider's models read
/// whole — an image in another format written again.
const model_bounds: image.Bounds = .{
    .width_max = 1568,
    .height_max = 1568,
    .pixels_max = 1_150_000,
    .bytes_max = 3_750_000,
    .formats = .initMany(&.{ .png, .jpeg }),
};

/// An image kept as a model is given one: its reference, and the image as it was fitted.
pub const KeptImage = struct { ref: []const u8, image: image.Fitted };

/// Keeps the image `bytes` as a model is given one, fitted to `model_bounds`, from any task — what it came as never
/// kept, as no model is given it; error.NotAnImage where they are none.
pub fn keepImage(runtime: *Runtime, arena: Allocator, bytes: []const u8) !KeptImage {
    const made = try image.fitted(arena, bytes, model_bounds);
    return .{ .ref = try put(runtime, arena, made.bytes), .image = made };
}

/// A file kept as a message gives it to a model: its reference, its size, and what it became where it is an image —
/// none for any other, which is kept as it came.
pub const Kept = struct { ref: []const u8, size: usize, media_type: ?[]const u8 };

/// Keeps `bytes`, which a person gives a message, as a model is given them, from any task: an image as `keepImage`
/// keeps one, and any other file as it is; error.TooLarge past `bytes_max`.
pub fn keep(runtime: *Runtime, arena: Allocator, bytes: []const u8) !Kept {
    if (bytes.len > bytes_max) return error.TooLarge;
    const kept = keepImage(runtime, arena, bytes) catch |err| switch (err) {
        error.NotAnImage => return .{ .ref = try put(runtime, arena, bytes), .size = bytes.len, .media_type = null },
        else => return err,
    };
    return .{ .ref = kept.ref, .size = kept.image.bytes.len, .media_type = kept.image.media_type };
}

/// Where the file `ref` names is kept; error.NotAReference where `ref` is not `sha256:` and 64 lowercase hex digits.
fn pathOf(arena: Allocator, ref: []const u8) ![]const u8 {
    return std.mem.concat(arena, u8, &.{ root, "/", try nameOf(ref) });
}

/// The name the file `ref` names is kept by in the files' directory: its hash; error.NotAReference where `ref` is not
/// `sha256:` and 64 lowercase hex digits.
fn nameOf(ref: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, ref, scheme)) return error.NotAReference;
    const hex = ref[scheme.len..];
    if (hex.len != 2 * std.crypto.hash.sha2.Sha256.digest_length) return error.NotAReference;
    for (hex) |char| if (!std.ascii.isDigit(char) and !(char >= 'a' and char <= 'f')) return error.NotAReference;
    return hex;
}

test "a file is kept once by its content, read back by its reference, and a reference of no file refused" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const runtime = try Runtime.open(std.testing.allocator, .{ .io = std.testing.io, .device = .memory }, .{});
    defer runtime.close();
    const ref = try put(runtime, arena, "\x89PNG\r\n\x1a\nbytes");
    try std.testing.expect(std.mem.startsWith(u8, ref, "sha256:"));
    try std.testing.expectEqualStrings(ref, try put(runtime, arena, "\x89PNG\r\n\x1a\nbytes"));
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\nbytes", try read(runtime.volume, arena, ref));
    try std.testing.expectError(error.NotAReference, read(runtime.volume, arena, "sha256:../thread.json"));
    try std.testing.expectError(error.NotFound, read(runtime.volume, arena, "sha256:0000000000000000000000000000000000000000000000000000000000000000"));
}
