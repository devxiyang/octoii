//! `deepgram`: Deepgram's API, reached with an API key: the transcription kind through its speech-to-text API. Its
//! failures are classified by the `err_code` of its error, or the `category` of its other form, else by the HTTP
//! status.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const seam = @import("../driver.zig");
const failure_ = @import("../failure.zig");
const Kind = failure_.Kind;
const http = @import("../wire/http.zig");

/// Where Deepgram's API is.
pub const base_url = "https://api.deepgram.com/v1";

pub const driver: seam.Driver = .{ .id = "deepgram", .name = "Deepgram", .catalogue = "deepgram", .transcription = @import("deepgram/transcriptions.zig").transcribe, .realtime = @import("deepgram/realtime.zig").calls };

/// The failure kind of each of Deepgram's codes.
const kinds = std.StaticStringMap(Kind).initComptime(.{
    .{ "INVALID_AUTH", .auth },                       .{ "INSUFFICIENT_PERMISSIONS", .forbidden },
    .{ "ASR_PAYMENT_REQUIRED", .quota },              .{ "TOO_MANY_REQUESTS", .rate_limit },
    // The recording was cut off on its way, as when the connection closed before the whole of it came.
    .{ "ASR_UNPROCESSABLE_ENTITY", .transport },      .{ "Bad Request", .invalid_request },
    .{ "INVALID_QUERY_PARAMETER", .invalid_request }, .{ "INVALID_JSON", .invalid_request },
    .{ "PAYLOAD_ERROR", .invalid_request },           .{ "REMOTE_CONTENT_ERROR", .invalid_request },
});

/// What Deepgram's body says of a refusal: its kind where its code tells it, its message and its code.
pub fn details(arena: Allocator, body: []const u8) ?http.Details {
    const said = foundation.json.decode(struct { err_code: ?[]const u8 = null, err_msg: ?[]const u8 = null, category: ?[]const u8 = null, message: ?[]const u8 = null, details: ?[]const u8 = null }, arena, body) catch return null;
    const code = said.err_code orelse said.category;
    const words = said.err_msg orelse said.message;
    const message = if (words) |given| (if (said.details) |more| std.fmt.allocPrint(arena, "{s}: {s}", .{ given, more }) catch return null else given) else null;
    return .{ .kind = if (code) |given| kinds.get(given) else null, .message = message, .code = code };
}
