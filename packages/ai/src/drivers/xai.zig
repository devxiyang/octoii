//! `xai`: OpenAI's Responses API as xAI serves it, reached with an API key. A request goes with nothing kept at xAI,
//! its encrypted reasoning asked for, its tool and effort changes folded, its text files as their text, and none of
//! what xAI does not take or would ignore: what it would ignore fails before anything is sent, and what changes nothing
//! it answers is not sent. Its events come back as they are, but for its errors, classified, and its usage, translated:
//! its cost from its ticks, its searches counted, its reasoning counted in the output and the context of its last
//! step as the response's.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const Request = vocabulary.ResponsesRequest;
const seam = @import("../driver.zig");
const failure_ = @import("../failure.zig");
const Error = failure_.Error;
const Model = @import("../catalogue/model.zig").Model;
const check = @import("../text/check.zig");
const files = @import("../text/files.zig");
const http = @import("../wire/http.zig");
const json = @import("../wire/json.zig");
const responses = @import("../wire/responses.zig");
const source = @import("../wire/source.zig");

/// Where xAI's API is.
pub const base_url = "https://api.x.ai/v1";

pub const driver: seam.Driver = .{ .id = "xai", .name = "xAI", .catalogue = "xai", .text = text, .image = @import("xai/images.zig").make, .speech = @import("xai/speech.zig").speak, .transcription = @import("xai/transcriptions.zig").transcribe, .video = @import("xai/videos.zig").calls, .realtime = @import("xai/realtime.zig").calls };

/// What xAI takes of the fields some providers take: its encrypted reasoning, three service tiers, and five domains a
/// search.
const taken: responses.Taken = .{ .includes = &.{.@"reasoning.encrypted_content"}, .service_tiers = &.{ .default, .fast, .priority }, .web_search_domains = 5 };

/// The highest `temperature` xAI samples at; one above it is sampled at it.
const temperature_max = 1;

/// The highest `top_p` xAI samples at, its models' default; one above it is sampled at it.
const top_p_max = 0.95;

/// xAI's ticks in a US dollar, the unit of its costs.
const ticks_per_usd = 10_000_000_000;

const wire: responses.StreamWire = .{ .kind_of = kindOf, .response = translated };

fn kindOf(_: ?[]const u8, message: ?[]const u8) ?failure_.Kind {
    return if (responses.contextTooLong(message)) .context_overflow else null;
}

/// What xAI's body says of a refusal, in every API it serves: its message and code, and a context too long.
pub fn details(arena: Allocator, body: []const u8) ?http.Details {
    return responses.streamDetails(arena, body, wire);
}

/// Checks the request against what xAI takes for `model`, before anything is sent: the fields it would ignore, a
/// `temperature` or `top_p` above what it samples at, an image it does not read, and a file but text, as it reads a
/// PDF only through a document search it runs.
fn checkRequest(call: *seam.Call, model: *const Model, request: *const Request) Error!void {
    try check.parts(call, model, request, &.{});
    try responses.checkTaken(call, model, request, taken);
    const reference = try model.reference(call.arena);
    if (request.temperature) |temperature| if (temperature > temperature_max) {
        return call.failWith(.invalid_request, "The model {s} samples a temperature above {d} at {d}: ask for at most that", .{ reference, temperature_max, temperature_max });
    };
    if (request.top_p) |top_p| if (top_p > top_p_max) {
        return call.failWith(.invalid_request, "The model {s} samples a top_p above {d} at {d}: ask for at most that", .{ reference, top_p_max, top_p_max });
    };
    for (check.inputItems(request)) |item| for (check.inputContentOf(item)) |part| {
        const file = files.TypedFile.of(part) orelse continue;
        if (file == .input_video) continue;
        const media_type = try files.mediaType(call.arena, file, null) orelse continue;
        if (file == .input_image and !std.mem.eql(u8, media_type, "image/png") and !std.mem.eql(u8, media_type, "image/jpeg")) {
            return call.failWith(.invalid_request, "The model {s} reads images of image/png and image/jpeg alone, and an input_image is {s}", .{ reference, media_type });
        }
        if (file == .input_file and !files.isText(media_type)) return pdfRefused(call, reference);
    };
}

fn pdfRefused(call: *seam.Call, reference: []const u8) Error {
    return call.failWith(.invalid_request, "The model {s} reads an input_file but text only through a document search its provider runs, which ai does not use", .{reference});
}

/// The request, its text files read as text, as it goes to xAI for `model`: the model by its id, its tool and effort
/// changes folded, nothing kept at xAI and the encrypted reasoning asked for unless the model does not reason, its
/// tools as xAI takes them, its provider options among its fields, and none of what changes nothing xAI answers.
pub fn wireRequest(arena: Allocator, model: *const Model, request: Request) Allocator.Error![]const u8 {
    var sent = try responses.withoutExplicitCaching(arena, try responses.foldEffortChanges(arena, try responses.foldToolChanges(arena, request)));
    const tools = sent.tools;
    const reasoning = sent.reasoning;
    var include: std.ArrayList(vocabulary.request.ResponseIncludable) = .empty;
    for (sent.include orelse &.{}) |value| if (std.mem.indexOfScalar(vocabulary.request.ResponseIncludable, include.items, value) == null) try include.append(arena, value);
    if (model.reasons() != false and std.mem.indexOfScalar(vocabulary.request.ResponseIncludable, include.items, .@"reasoning.encrypted_content") == null) try include.append(arena, .@"reasoning.encrypted_content");
    inline for (.{ "tools", "reasoning", "include", "metadata", "truncation", "session_id", "trace", "debug", "provider", "models", "plugins", "stop_server_tools_when", "max_tool_calls", "modalities", "store" }) |field| @field(sent, field) = null;
    try plainItems(arena, &sent);
    return foundation.json.encode(arena, foundation.json.merged(.{ sent, try json.ownOptions(arena, &request, "xai"), .{
        .model = model.id,
        .tools = if (tools) |given| try responses.plainTools(arena, given) else null,
        .reasoning = effortOnly(reasoning),
        .store = false,
        .include = if (include.items.len == 0) null else include.items,
        .stream = true,
    } }));
}

/// The request's items without Octoii's extensions.
pub fn plainItems(arena: Allocator, request: *Request) Allocator.Error!void {
    const items = check.inputItems(request);
    if (items.len == 0) return;
    const made = try arena.alloc(vocabulary.Item, items.len);
    for (items, made) |item, *each| each.* = try responses.withoutExtensions(arena, item);
    request.input = .{ .parts = made };
}

fn text(call: *seam.Call, model: *const Model, request: *const Request) Error!seam.TextSource {
    try checkRequest(call, model, request);
    const key = try call.apiKey();
    const with_texts = try responses.withTextFilesAsText(call, request.*);
    for (check.inputItems(&with_texts)) |item| for (check.inputContentOf(item)) |part| if (part == .input_file) return pdfRefused(call, try model.reference(call.arena));
    const response = try http.send(call, .{
        .method = .POST,
        .url = try call.arena.print("{s}/responses", .{call.baseUrl(base_url)}),
        .headers = &.{
            .{ .name = "authorization", .value = try call.arena.print("Bearer {s}", .{key}) },
            .{ .name = "accept", .value = "text/event-stream" },
            .{ .name = "content-type", .value = "application/json" },
        },
        .body = try wireRequest(call.arena, model, with_texts),
    });
    if (response.status < 200 or response.status >= 300) return call.fail(try http.failureOf(call, response, details));
    return source.of(vocabulary.ResponseStreamEvent, call, response, translate);
}

fn translate(call: *seam.Call, data: []const u8, out: *std.ArrayList(vocabulary.ResponseStreamEvent)) Error!void {
    try out.append(call.arena, try responses.streamEvent(call, data, wire));
}

/// The usage of a response as xAI reports it, of which ai reads these counts.
const XaiUsage = struct {
    input_tokens: u64,
    input_tokens_details: struct { cached_tokens: u64 },
    /// The visible output alone, without the reasoning.
    output_tokens: u64,
    output_tokens_details: struct { reasoning_tokens: u64 },
    total_tokens: u64,
    /// The cost in ticks, ten billion to the dollar.
    cost_in_usd_ticks: ?u64 = null,
    /// The tokens of the last step of a response whose searches took several.
    context_details: ?struct { input_tokens: u64 } = null,
    server_side_tool_usage_details: ?struct { web_search_calls: ?u64 = null } = null,
};

/// xAI's response as the vocabulary's: its usage with the reasoning counted in the output, its cost from its ticks
/// and its searches counted where it reports them, and the input of its last step as its `octoii.context_tokens`.
fn translated(call: *seam.Call, response: vocabulary.Response, raw: std.json.Value) Error!vocabulary.Response {
    if (raw != .object) return response;
    const given = raw.object.get("usage") orelse return response;
    const usage = foundation.json.decodeValue(XaiUsage, call.arena, given) catch return response;
    var made = response;
    const reasoning = usage.output_tokens_details.reasoning_tokens;
    made.usage = .{
        .input_tokens = usage.input_tokens,
        .input_tokens_details = .{ .cached_tokens = usage.input_tokens_details.cached_tokens },
        .output_tokens = usage.output_tokens + reasoning,
        .output_tokens_details = .{ .reasoning_tokens = reasoning },
        .total_tokens = usage.total_tokens,
        .cost = if (usage.cost_in_usd_ticks) |ticks| @as(f64, @floatFromInt(ticks)) / ticks_per_usd else null,
        .server_tool_use_details = if (usage.server_side_tool_usage_details) |used| (if (used.web_search_calls) |searches| .{ .web_search_requests = searches } else null) else null,
    };
    if (usage.context_details) |context| {
        var extension = made.octoii orelse vocabulary.extensions.ResponseExtension{};
        extension.context_tokens = context.input_tokens;
        made.octoii = extension;
    }
    return made;
}

/// The reasoning settings as a provider that takes the effort alone takes them.
pub fn effortOnly(reasoning: ?vocabulary.request.ReasoningConfig) ?Effort {
    const given = reasoning orelse return null;
    return .{ .effort = given.effort orelse return null };
}

pub const Effort = struct { effort: vocabulary.items.ReasoningEffort };
