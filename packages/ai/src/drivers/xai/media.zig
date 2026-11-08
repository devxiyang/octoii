//! What xAI's media APIs share: a request sent with the API key and its refusal classified as a text request's is, a
//! request's `provider` held to its own options, which join the body, a reference's type held to the images xAI
//! reads, and a cost in xAI's ticks.
const std = @import("std");
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const seam = @import("../../driver.zig");
const Call = seam.Call;
const Error = @import("../../failure.zig").Error;
const http = @import("../../wire/http.zig");
const json = @import("../../wire/json.zig");
const xai = @import("../xai.zig");

/// The images xAI's media APIs read.
const image_media_types = [_][]const u8{ "image/png", "image/jpeg", "image/webp" };

/// xAI's ticks in a US dollar, the unit of its costs.
const ticks_per_usd = 10_000_000_000;

/// A request to one of xAI's media APIs: where to under its address, what it accepts, and its body.
pub const Request = struct {
    method: std.http.Method = .POST,
    path: []const u8,
    accept: []const u8,
    body: ?[]const u8 = null,
    content_type: []const u8 = "application/json",
};

/// Sends `request` to xAI with the API key; its answer once it is ok, else its refusal, classified by its body and
/// status.
pub fn send(call: *Call, request: Request) Error!foundation.http.Response {
    const key = try call.apiKey();
    const response = try http.send(call, .{
        .method = request.method,
        .url = try std.fmt.allocPrint(call.arena, "{s}{s}", .{ call.baseUrl(xai.base_url), request.path }),
        .headers = &.{
            .{ .name = "authorization", .value = try std.fmt.allocPrint(call.arena, "Bearer {s}", .{key}) },
            .{ .name = "accept", .value = request.accept },
            .{ .name = "content-type", .value = request.content_type },
        },
        .body = request.body,
    });
    if (response.status < 200 or response.status >= 300) return call.fail(try http.failureOf(call, response, xai.details));
    return response;
}

/// xAI's own options of a request's `provider`, which join its body; `invalid_request` for any other field of it, as
/// xAI routes nowhere and keeps no data policy of OpenRouter's.
pub fn options(call: *Call, provider: anytype, comptime api: []const u8) Error!?std.json.ObjectMap {
    return json.ownOptionsAlone(call, provider, "xai", "xAI's " ++ api ++ " takes no provider {s}: its provider takes its options alone");
}

/// Checks that an image at `url` is of a type xAI reads, as far as its data URL or `octoii` say.
pub fn checkImageType(call: *Call, url: ?[]const u8, octoii: ?vocabulary.extensions.FileExtension, what: []const u8) Error!void {
    const given = url orelse "";
    const declared: ?[]const u8 = if (std.ascii.startsWithIgnoreCase(given, "data:"))
        given[5 .. std.mem.indexOfAny(u8, given, ";,") orelse given.len]
    else if (octoii) |extension| extension.media_type else null;
    const media_type = try std.ascii.allocLowerString(call.arena, declared orelse return);
    for (image_media_types) |each| if (std.mem.eql(u8, each, media_type)) return;
    return call.failWith(.invalid_request, "{s} is {s}, and xAI reads images of {s} alone", .{ what, media_type, try std.mem.join(call.arena, ", ", &image_media_types) });
}

/// A cost in xAI's ticks, ten billion to the dollar, in US dollars.
pub fn dollarsOfTicks(ticks: u64) f64 {
    return @as(f64, @floatFromInt(ticks)) / ticks_per_usd;
}

pub const jsonBody = @import("../openrouter/media.zig").jsonBody;
