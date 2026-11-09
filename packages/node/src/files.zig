//! The files a thread's messages give their model, and the pictures its calls show the person, as the node's HTTP
//! carries them, since a client's messages are JSON on its WebSocket: a file's bytes sent in a POST to `/files`, kept
//! by Siphon by their content — an image as a model is given one — and answered with the reference a message names it
//! by, and what an image became; and a kept file's bytes given back at `/files/<reference>`, as the person's own message
//! shows it — or, where the query asks with `width_max` and `height_max`, an image fitted to that box, its shape kept
//! and never enlarged, as a picture of it is drawn small — each kept by a browser for good, as what a reference names
//! never changes. Each is for a client whose session works on threads, or reads them; a page of another origin is
//! refused, as a browser lets any page send one.
const std = @import("std");
const Allocator = std.mem.Allocator;
const siphon_ = @import("siphon");
const Siphon = siphon_.Siphon;
const auth = @import("auth.zig");
const Request = @import("Request.zig");

/// Where files are sent, and given back from under.
pub const path = "/files";

/// Whether `target`'s path is the files' own.
pub fn isFiles(target: []const u8) bool {
    return std.mem.eql(u8, target, path) or std.mem.startsWith(u8, target, path ++ "/");
}

/// Answers `client`'s request for the files at `target`, its path: a file kept from a POST's body, or one given back by
/// a GET.
pub fn answer(siphon: *Siphon, client: auth.Client, arena: Allocator, request: *Request, target: []const u8) !void {
    if (!client.same_origin) return auth.answerJson(request, .forbidden, "{\"code\":\"origin\",\"message\":\"A page of another origin reaches no files here.\"}", null);
    const principal = client.principal orelse return unauthorized(request);
    if (std.mem.eql(u8, target, path)) {
        if (request.method() != .POST) return auth.answerJson(request, .method_not_allowed, "{\"code\":\"method\",\"message\":\"A file is sent with a POST.\"}", null);
        if (!principal.allows(.@"threads.operate")) return forbidden(request);
        return keep(siphon, arena, request);
    }
    if (request.method() != .GET) return auth.answerJson(request, .method_not_allowed, "{\"code\":\"method\",\"message\":\"A file is read with a GET.\"}", null);
    if (!principal.allows(.@"threads.read")) return forbidden(request);
    return give(siphon, arena, request, target[path.len + 1 ..]);
}

fn unauthorized(request: *Request) !void {
    return auth.answerJson(request, .unauthorized, "{\"code\":\"unauthenticated\",\"message\":\"No session of this node's is presented.\"}", null);
}

fn forbidden(request: *Request) !void {
    return auth.answerJson(request, .forbidden, "{\"code\":\"forbidden\",\"message\":\"The session does not let its client do that.\"}", null);
}

/// Keeps the request's body as a file — an image as a model is given one: answered with its reference, its size and, for
/// an image, what it became; refused past what a file may hold, and an image that does not decode or has more pixels
/// than are decoded.
fn keep(siphon: *Siphon, arena: Allocator, request: *Request) !void {
    const max = siphon_.threads.stored.bytes_max;
    var buffer: [16 << 10]u8 = undefined;
    const body = (try request.reader(&buffer)).allocRemaining(arena, .limited(max + 1)) catch |err| switch (err) {
        error.StreamTooLong => return auth.answerJson(request, .payload_too_large, try arena.print("{{\"code\":\"too-large\",\"message\":\"A file holds at most {d} bytes.\"}}", .{max}), null),
        else => return err,
    };
    if (body.len > max) return auth.answerJson(request, .payload_too_large, try arena.print("{{\"code\":\"too-large\",\"message\":\"A file holds at most {d} bytes.\"}}", .{max}), null);
    const kept = siphon.storeFile(arena, body) catch |err| switch (err) {
        error.Malformed => return auth.answerJson(request, .unprocessable_entity, "{\"code\":\"malformed\",\"message\":\"The image does not decode.\"}", null),
        error.TooLarge => return auth.answerJson(request, .payload_too_large, "{\"code\":\"too-large\",\"message\":\"The image has more pixels than are decoded.\"}", null),
        else => return err,
    };
    return auth.answerJson(request, .ok, try siphon_.foundation.json.encode(arena, kept), null);
}

/// Gives back the file `ref` names, its type as its first bytes tell it — or the picture of it the query asks for —
/// kept by the browser for good.
fn give(siphon: *Siphon, arena: Allocator, request: *Request, ref: []const u8) !void {
    const asked = boxOf(request.target()) catch return auth.answerJson(request, .bad_request, "{\"code\":\"box\",\"message\":\"A picture is asked for by width_max and height_max, both whole numbers.\"}", null);
    if (asked) |box| return givePicture(siphon, arena, request, ref, box);
    const bytes = siphon.storedFile(arena, ref) catch |err| switch (err) {
        error.NotFound, error.NotAReference => return notFound(request),
        else => return err,
    };
    return respondKept(request, bytes, mediaTypeOf(bytes));
}

/// Gives back the image `ref` names fitted to `box`; refused where the file kept is no image.
fn givePicture(siphon: *Siphon, arena: Allocator, request: *Request, ref: []const u8, box: siphon_.threads.stored.Box) !void {
    const picture = siphon.storedPicture(arena, ref, box) catch |err| switch (err) {
        error.NotFound, error.NotAReference => return notFound(request),
        error.NotAnImage => return auth.answerJson(request, .unsupported_media_type, "{\"code\":\"not-an-image\",\"message\":\"The file kept by that reference is no image to draw.\"}", null),
        else => return err,
    };
    return respondKept(request, picture.bytes, picture.media_type);
}

/// Answers with a kept file's bytes, or a picture of one, as what `media_type` names: kept by the browser for good,
/// as what a reference names never changes.
fn respondKept(request: *Request, bytes: []const u8, media_type: []const u8) !void {
    return request.respond(bytes, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = media_type },
        .{ .name = "cache-control", .value = "private, max-age=31536000, immutable" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    } });
}

fn notFound(request: *Request) !void {
    return auth.answerJson(request, .not_found, "{\"code\":\"not-found\",\"message\":\"No file is kept by that reference.\"}", null);
}

/// The box the query of `target` asks a picture to fit, by `width_max` and `height_max`, each a whole number; none where
/// it asks for neither; error.Malformed where it asks for one alone, or for one that is no number.
fn boxOf(target: []const u8) !?siphon_.threads.stored.Box {
    const query = target[(std.mem.indexOfScalar(u8, target, '?') orelse return null) + 1 ..];
    var width: ?u32 = null;
    var height: ?u32 = null;
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const name = pair[0..equals];
        const side: *?u32 = if (std.mem.eql(u8, name, "width_max")) &width else if (std.mem.eql(u8, name, "height_max")) &height else continue;
        side.* = std.fmt.parseInt(u32, pair[equals + 1 ..], 10) catch return error.Malformed;
    }
    if (width == null and height == null) return null;
    return .{ .width_max = width orelse return error.Malformed, .height_max = height orelse return error.Malformed };
}

/// What a file is, as its first bytes tell: an image or a PDF a message gives a model, else bytes alone.
fn mediaTypeOf(bytes: []const u8) []const u8 {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return "image/png";
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return "image/jpeg";
    if (std.mem.startsWith(u8, bytes, "GIF8")) return "image/gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    if (std.mem.startsWith(u8, bytes, "%PDF-")) return "application/pdf";
    return "application/octet-stream";
}

test "a file's type is what its first bytes tell, else bytes alone" {
    try std.testing.expectEqualStrings("image/png", mediaTypeOf("\x89PNG\r\n\x1a\n...."));
    try std.testing.expectEqualStrings("image/webp", mediaTypeOf("RIFF\x00\x00\x00\x00WEBPVP8 "));
    try std.testing.expectEqualStrings("application/pdf", mediaTypeOf("%PDF-1.7"));
    try std.testing.expectEqualStrings("application/octet-stream", mediaTypeOf("<script>"));
    try std.testing.expect(isFiles("/files/sha256:ab"));
    try std.testing.expect(!isFiles("/filesystem"));
}

test "a picture is asked for by both sides of its box, whole numbers, or not at all" {
    try std.testing.expectEqual(@as(?siphon_.threads.stored.Box, .{ .width_max = 768, .height_max = 256 }), try boxOf("/files/sha256:ab?width_max=768&height_max=256"));
    try std.testing.expectEqual(@as(?siphon_.threads.stored.Box, null), try boxOf("/files/sha256:ab"));
    try std.testing.expectEqual(@as(?siphon_.threads.stored.Box, null), try boxOf("/files/sha256:ab?v=new"));
    try std.testing.expectError(error.Malformed, boxOf("/files/sha256:ab?width_max=768"));
    try std.testing.expectError(error.Malformed, boxOf("/files/sha256:ab?width_max=768&height_max=tall"));
}
