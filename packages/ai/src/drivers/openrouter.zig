//! `openrouter`: OpenRouter's Responses API, which the vocabulary is, reached with an API key. A request goes as the
//! vocabulary makes it, its extensions off, automatic caching added, a tool removal folded, an effort changed where it
//! stands folded for a model that takes no such change, and ids made up for the items OpenRouter did not write; its events come back as they are, but for its errors, classified by its error types
//! and codes, and a context too long, which it answers as a response cut at its output limit.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const Event = vocabulary.ResponseStreamEvent;
const Item = vocabulary.Item;
const seam = @import("../driver.zig");
const failure_ = @import("../failure.zig");
const Error = failure_.Error;
const Kind = failure_.Kind;
const Model = @import("../catalogue/model.zig").Model;
const check = @import("../text/check.zig");
const http = @import("../wire/http.zig");
const json = @import("../wire/json.zig");
const responses = @import("../wire/responses.zig");
const source = @import("../wire/source.zig");

/// Where OpenRouter's API is.
pub const base_url = "https://openrouter.ai/api/v1";

pub const driver: seam.Driver = .{ .id = "openrouter", .name = "OpenRouter", .catalogue = "openrouter", .text = text, .image = @import("openrouter/images.zig").make, .speech = @import("openrouter/speech.zig").speak, .transcription = @import("openrouter/transcriptions.zig").transcribe, .video = @import("openrouter/videos.zig").calls, .decision = @import("openrouter/decisions.zig").decide };

/// The most characters of a routed provider's own words that a failure carries after OpenRouter's message.
const routed_words_max = 1000;

const error_types = std.StaticStringMap(Kind).initComptime(.{
    .{ "context_length_exceeded", .context_overflow }, .{ "max_tokens_exceeded", .invalid_request },
    .{ "token_limit_exceeded", .quota },               .{ "string_too_long", .payload_too_large },
    .{ "authentication", .auth },                      .{ "permission_denied", .forbidden },
    .{ "payment_required", .quota },                   .{ "rate_limit_exceeded", .rate_limit },
    .{ "provider_overloaded", .server },               .{ "provider_unavailable", .server },
    .{ "invalid_request", .invalid_request },          .{ "invalid_prompt", .invalid_request },
    .{ "not_found", .invalid_request },                .{ "precondition_failed", .invalid_request },
    .{ "payload_too_large", .payload_too_large },      .{ "unprocessable", .invalid_request },
    .{ "content_policy_violation", .content_filter },  .{ "refusal", .content_filter },
    .{ "invalid_image", .invalid_request },            .{ "image_too_large", .payload_too_large },
    .{ "image_too_small", .invalid_request },          .{ "unsupported_image_format", .invalid_request },
    .{ "image_not_found", .invalid_request },          .{ "image_download_failed", .invalid_request },
    .{ "server", .server },                            .{ "timeout", .server },
    .{ "unmapped", .server },
});
const codes = std.StaticStringMap(Kind).initComptime(.{
    .{ "invalid_prompt", .invalid_request },                .{ "invalid_image", .invalid_request },
    .{ "invalid_image_format", .invalid_request },          .{ "invalid_base64_image", .invalid_request },
    .{ "invalid_image_url", .invalid_request },             .{ "image_too_small", .invalid_request },
    .{ "image_parse_error", .invalid_request },             .{ "invalid_image_mode", .invalid_request },
    .{ "unsupported_image_media_type", .invalid_request },  .{ "empty_image_file", .invalid_request },
    .{ "failed_to_download_image", .invalid_request },      .{ "image_file_not_found", .invalid_request },
    .{ "data_residency_mismatch", .invalid_request },       .{ "image_too_large", .payload_too_large },
    .{ "image_file_too_large", .payload_too_large },        .{ "rate_limit_exceeded", .rate_limit },
    .{ "image_content_policy_violation", .content_filter }, .{ "bio_policy", .content_filter },
    .{ "cyber_policy", .content_filter },                   .{ "misalignment_policy_violation", .content_filter },
    .{ "permission_denied", .forbidden },                   .{ "invalid_api_key", .auth },
    .{ "server_error", .server },                           .{ "vector_store_timeout", .server },
});

/// An error's code as OpenRouter sends it: a Responses code, or an HTTP status.
pub const Code = union(enum) {
    name: []const u8,
    status: i64,

    const variants = foundation.json.Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// An error as OpenRouter sends it: its code, its message, and what it adds, kept whole.
pub const WireError = struct {
    code: ?Code = null,
    message: ?[]const u8 = null,
    metadata: ?Value = null,
};

/// What OpenRouter adds to an error that ai reads.
const Metadata = struct {
    /// OpenRouter's typed kind of error, where an API carries it inside the error.
    error_type: ?[]const u8 = null,
    /// The budget that was spent, for a request refused by a budget.
    limit_source: ?[]const u8 = null,
    /// The failure of the provider OpenRouter routed to, as that provider sent it.
    raw: ?[]const u8 = null,
    /// The name of the provider OpenRouter routed to.
    provider_name: ?[]const u8 = null,
};

fn metadataOf(arena: Allocator, wire: WireError) Metadata {
    const given = wire.metadata orelse return .{};
    return foundation.json.decodeValue(Metadata, arena, given) catch .{};
}

/// The request as it goes to OpenRouter for `model`: the vocabulary's, ids made up for the items it did not write,
/// a tool removal folded, an effort changed where it stands folded where the model's facts do not say it takes one —
/// OpenRouter refuses the change for a model that does not — no extensions, the model by its id, every parameter
/// required of the provider it routes to unless the request says otherwise, automatic caching unless it caches as it
/// says, as a stream.
pub fn wireRequest(arena: Allocator, model: *const Model, request: vocabulary.ResponsesRequest) Allocator.Error![]const u8 {
    var sent = try withItemIds(arena, request);
    if (responses.hasToolRemovals(&sent)) sent = try responses.foldToolChanges(arena, sent);
    const takes_effort_updates = if (model.octoii.features) |features| features.effort_updates == true else false;
    if (!takes_effort_updates) sent = try responses.foldEffortChanges(arena, sent);
    const items = check.inputItems(&sent);
    if (items.len > 0) {
        const plain = try arena.alloc(Item, items.len);
        for (items, plain) |item, *each| each.* = try responses.withoutExtensions(arena, item);
        sent.input = .{ .parts = plain };
    }
    const caching: ?vocabulary.request.CacheControl = if (request.cache_control == null and request.prompt_cache_options == null) .{} else null;
    return foundation.json.encode(arena, foundation.json.merged(.{ sent, .{
        .model = model.id,
        .provider = foundation.json.merged(.{ .{ .require_parameters = true }, sent.provider }),
        .cache_control = caching,
        .stream = true,
    } }));
}

/// The request with an id on each assistant message and function call that has none, made from its place in the
/// input or its `call_id`, and the status `completed` on one without a status: OpenRouter requires both of the items
/// it did not write.
fn withItemIds(arena: Allocator, request: vocabulary.ResponsesRequest) Allocator.Error!vocabulary.ResponsesRequest {
    const list = check.inputItems(&request);
    if (list.len == 0) return request;
    const items = try arena.dupe(Item, list);
    for (items, 0..) |*item, index| switch (item.*) {
        .function_call => |*call| {
            if (call.id == null) call.id = try arena.print("fc_{s}", .{call.call_id});
            if (call.status == null) call.status = .completed;
        },
        .output_message => |*message| {
            if (message.id == null) message.id = try arena.print("msg_{d}", .{index});
            if (message.status == null) message.status = .completed;
        },
        else => {},
    };
    var identified = request;
    identified.input = .{ .parts = items };
    return identified;
}

fn text(call: *seam.Call, model: *const Model, request: *const vocabulary.ResponsesRequest) Error!seam.TextSource {
    try check.parts(call, model, request, std.enums.values(check.Part));
    const key = try call.apiKey();
    const response = try http.send(call, .{
        .method = .POST,
        .url = try call.arena.print("{s}/responses", .{call.baseUrl(base_url)}),
        .headers = &.{
            .{ .name = "authorization", .value = try call.arena.print("Bearer {s}", .{key}) },
            .{ .name = "accept", .value = "text/event-stream" },
            .{ .name = "content-type", .value = "application/json" },
        },
        .body = try wireRequest(call.arena, model, request.*),
    });
    if (response.status < 200 or response.status >= 300) return call.fail(try http.failureOf(call, response, details));
    return source.of(vocabulary.ResponseStreamEvent, call, response, translate);
}

/// What OpenRouter's body says of a refusal before the stream: its kind where its type or budget says, its message
/// and code.
pub fn details(arena: Allocator, body: []const u8) ?http.Details {
    const given = foundation.json.decode(struct { @"error": WireError, error_type: ?[]const u8 = null }, arena, body) catch return null;
    const metadata = metadataOf(arena, given.@"error");
    const error_type = given.error_type orelse metadata.error_type;
    return .{
        .kind = if (metadata.limit_source != null) .quota else if (error_type) |named| error_types.get(named) else null,
        .message = wireErrorMessage(arena, given.@"error") catch null,
        .code = error_type orelse if (given.@"error".code) |code| (if (code == .name) code.name else null) else null,
    };
}

/// The message of OpenRouter's error: its own, followed by the words of the provider it routed to where it passes
/// that provider's failure on, named by the provider's name.
pub fn wireErrorMessage(arena: Allocator, wire: WireError) Allocator.Error!?[]const u8 {
    const metadata = metadataOf(arena, wire);
    const raw = std.mem.trim(u8, metadata.raw orelse return wire.message, " \t\r\n");
    if (raw.len == 0) return wire.message;
    const words = try routedWords(arena, raw);
    const routed = if (metadata.provider_name) |provider| try arena.print("{s}: {s}", .{ provider, words }) else words;
    const own = wire.message orelse return routed;
    return try arena.print("{s} ({s})", .{ own, routed });
}

/// The words of a routed provider's failure: the message of its error where it parses as one, else its text; at most
/// `routed_words_max` characters of them, as a provider may send a whole page.
fn routedWords(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    const Said = struct { @"error": ?struct { message: []const u8 } = null, message: ?[]const u8 = null };
    const said: Said = foundation.json.decode(Said, arena, raw) catch .{};
    const words = if (said.@"error") |inner| inner.message else said.message orelse raw;
    var count: usize = 0;
    var at: usize = 0;
    while (at < words.len) : (count += 1) {
        if (count == routed_words_max) return arena.print("{s}\u{2026}", .{words[0..at]});
        at += std.unicode.utf8ByteSequenceLength(words[at]) catch 1;
    }
    return words;
}

/// The failure an error in OpenRouter's stream or failed response stands for: by its error type where it gives one,
/// else by its code — a Responses code, or an HTTP status — else the provider's own, `server`.
pub fn classified(code: ?Code, error_type: ?[]const u8) vocabulary.extensions.FailureExtension {
    const by_type = if (error_type) |named| error_types.get(named) else null;
    const kind = by_type orelse if (code) |given| switch (given) {
        .name => |named| codes.get(named) orelse .server,
        .status => |status| if (status >= 100 and status <= 599) http.kindOfStatus(@intCast(status)) else .server,
    } else .server;
    return .{ .kind = kind, .retryable = failure_.retryableKind(kind) };
}

fn translate(call: *seam.Call, data: []const u8, out: *std.ArrayList(Event)) Error!void {
    const arena = call.arena;
    var value = try json.parseObject(call, data);
    responses.withoutNullLogprobs(&value);
    const kind = json.textOf(value, "type").?;
    if (std.mem.eql(u8, kind, "error") or std.mem.eql(u8, kind, "response.error")) {
        const given = try responses.decodeAs(struct { code: ?Code = null, message: ?[]const u8 = null, param: ?[]const u8 = null, @"error": ?WireError = null }, call, value, data);
        const code = if (given.@"error") |inner| inner.code else given.code;
        const extension = classified(code, if (given.@"error") |inner| metadataOf(arena, inner).error_type else null);
        const message = (if (given.@"error") |inner| try wireErrorMessage(arena, inner) else null) orelse given.message;
        return out.append(arena, .{ .@"error" = .{
            .code = if (code) |named| (if (named == .name) named.name else @tagName(extension.kind)) else @tagName(extension.kind),
            .message = message orelse "The provider's stream failed without saying why",
            .param = given.param,
            .octoii = extension,
            .sequence_number = 0,
        } });
    }
    const failed_error = if (std.mem.eql(u8, kind, "response.failed")) try responses.takeResponseError(WireError, call, &value, data) else null;
    var event = try responses.decodeAs(Event, call, value, data);
    switch (event) {
        .failed => |*failed| if (failed_error) |wire| {
            const extension = classified(wire.code, if (failed.response.error_type) |named| @tagName(named) else metadataOf(arena, wire).error_type);
            failed.response.@"error" = .{
                .code = if (wire.code) |code| (if (code == .name) code.name else @tagName(extension.kind)) else @tagName(extension.kind),
                .message = try wireErrorMessage(arena, wire) orelse "The response failed without saying why",
                .metadata = if (wire.metadata) |metadata| .{ .text = try foundation.json.encode(arena, metadata) } else null,
                .octoii = extension,
            };
        },
        inline .completed, .incomplete => |*ended| {
            if (contextTooLong(ended.response)) return endedTooLong(arena, ended.response, ended.sequence_number, out);
            ended.response = responses.withContextCounted(ended.response);
        },
        else => {},
    }
    try out.append(arena, event);
}

/// Whether a response stands for a context too long for the model: its error type says so, or it ended at its
/// output limit having written nothing.
fn contextTooLong(response: vocabulary.Response) bool {
    if (response.error_type == .context_length_exceeded) return true;
    if (response.status != .incomplete) return false;
    const reason = if (response.incomplete_details) |given| given.reason else null;
    if (reason != .max_output_tokens) return false;
    const usage = response.usage orelse return response.output.len == 0;
    return usage.output_tokens == 0;
}

/// A context too long, which OpenRouter answers as a response cut at its output limit: an `error` and the response
/// failed, as `context_overflow`.
fn endedTooLong(arena: Allocator, response: vocabulary.Response, sequence: u64, out: *std.ArrayList(Event)) Allocator.Error!void {
    const failed_error: vocabulary.response.ResponseError = .{
        .code = if (response.error_type) |named| @tagName(named) else "context_overflow",
        .message = "The context is too long for the model: the provider ended the response at its limit without writing",
        .octoii = .{ .kind = .context_overflow, .retryable = false },
    };
    try out.append(arena, .{ .@"error" = .{ .code = failed_error.code, .message = failed_error.message, .octoii = failed_error.octoii, .sequence_number = sequence } });
    var failed = response;
    failed.status = .failed;
    failed.incomplete_details = null;
    failed.@"error" = failed_error;
    try out.append(arena, .{ .failed = .{ .response = failed, .sequence_number = sequence + 1 } });
}

test "a provider's words go after OpenRouter's message, as their text where they are no JSON, cut at their limit" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const parse = struct {
        fn of(call_arena: Allocator, given: []const u8) !WireError {
            return foundation.json.decode(WireError, call_arena, given);
        }
    }.of;
    try std.testing.expectEqualStrings("Provider returned error (upstream timed out)", (try wireErrorMessage(arena, try parse(arena,
        \\{"message":"Provider returned error","metadata":{"raw":"  upstream timed out \n"}}
    ))).?);
    const page: [1050]u8 = @splat('x');
    const long = try arena.print("{{\"message\":\"Provider returned error\",\"metadata\":{{\"raw\":\"{s}\",\"provider_name\":\"Meta\"}}}}", .{&page});
    const cut = try arena.print("Provider returned error (Meta: {s}\u{2026})", .{page[0..1000]});
    try std.testing.expectEqualStrings(cut, (try wireErrorMessage(arena, try parse(arena, long))).?);
    try std.testing.expectEqualStrings("Provider returned error", (try wireErrorMessage(arena, try parse(arena,
        \\{"message":"Provider returned error","metadata":{"raw":null,"provider_name":"Meta"}}
    ))).?);
}
