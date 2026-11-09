//! `chat-completions`: the driver of any Chat Completions server, at the address its provider gives, reached with an
//! API key or none. It speaks Chat Completions as OpenAI's reference defines it, asked for its usage at the end of the
//! stream; it lists its models at the server's `/models`, and says its provider is connected where the server
//! answers. The servers of Ollama and LM Studio speak it the same way.
const std = @import("std");
const vocabulary = @import("vocabulary");
const Request = vocabulary.ResponsesRequest;
const ReasoningEffort = vocabulary.items.ReasoningEffort;
const seam = @import("../driver.zig");
const Call = seam.Call;
const Error = @import("../failure.zig").Error;
const Model = @import("../catalogue/model.zig").Model;
const ModelFacts = @import("../catalogue/facts.zig").ModelFacts;
const chat = @import("../wire/chat_completions.zig");
const messages = chat.messages;
const listings = @import("../wire/listings.zig");

pub const driver: seam.Driver = .{
    .id = "chat-completions",
    .name = "Chat Completions server",
    .text = chat.text(Settings, dialect(null, "/chat/completions")),
    .list = list,
    .status = status,
};

/// The request's settings as Chat Completions names them.
pub const Settings = struct {
    reasoning_effort: ?ReasoningEffort = null,
    max_tokens: ?u64 = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    top_k: ?f64 = null,
    frequency_penalty: ?f64 = null,
    presence_penalty: ?f64 = null,
    stop: ?vocabulary.TextOr([]const u8) = null,
    response_format: ?messages.ResponseFormat = null,
    verbosity: @FieldType(vocabulary.request.TextConfig, "verbosity") = null,
    tool_choice: ?messages.ToolChoice = null,
    parallel_tool_calls: ?bool = null,
    service_tier: ?vocabulary.request.ServiceTier = null,
    logprobs: ?bool = null,
    top_logprobs: ?u32 = null,
    stream_options: struct { include_usage: bool } = .{ .include_usage = true },
};

/// Chat Completions as a server that follows OpenAI's reference speaks it, at `base_url` unless its provider gives
/// another, its `/chat/completions` at `path` under it.
pub fn dialect(comptime base_url: ?[]const u8, comptime path: []const u8) chat.Dialect(Settings) {
    return .{
        .base_url = base_url,
        .path = path,
        .messages = .{ .image_detail = true, .file_addresses = false },
        .authorization = chat.serverAuthorization,
        .settings = settings,
        .details = chat.serverDetails,
        .stream_failure = chat.serverStreamFailure,
    };
}

/// The request's settings; `invalid_request` for a deeper reasoning, which Chat Completions has no field for.
fn settings(call: *Call, _: *const Model, request: *const Request, effort: ?ReasoningEffort) Error!Settings {
    if (request.reasoning) |reasoning| if (reasoning.mode == .pro) {
        return call.failWith(.invalid_request, "Chat Completions takes no deeper reasoning: reasoning.mode pro has no field there", .{});
    };
    return .{
        .reasoning_effort = effort,
        .max_tokens = request.max_output_tokens,
        .temperature = request.temperature,
        .top_p = request.top_p,
        .top_k = request.top_k,
        .frequency_penalty = request.frequency_penalty,
        .presence_penalty = request.presence_penalty,
        .stop = request.stop,
        .response_format = messages.responseFormat(request),
        .verbosity = if (request.text) |text| text.verbosity else null,
        .tool_choice = if (request.tool_choice) |choice| try messages.toolChoice(call.arena, choice) else null,
        .parallel_tool_calls = request.parallel_tool_calls,
        .service_tier = request.service_tier,
        .logprobs = if (request.top_logprobs != null) true else null,
        .top_logprobs = request.top_logprobs,
    };
}

/// Its listing of models, of which only the ids are read.
const Listing = struct { data: []const struct { id: []const u8 } };

/// The models the server lists: each a text model, by its id.
fn list(call: *Call) Error![]const ModelFacts {
    const listing = try listingOf(call) orelse return &.{};
    var listed: std.ArrayList(ModelFacts) = .empty;
    for (listing.data) |each| if (each.id.len > 0) try listed.append(call.arena, .{ .id = each.id, .octoii = .{ .kinds = &.{.text} } });
    return listed.items;
}

fn status(call: *Call) Error!seam.Status {
    const answered = try listingOf(call) != null;
    return listings.status(call, answered, try modelsUrl(call));
}

/// The server's listing, asked for with its key where the host keeps one.
fn listingOf(call: *Call) Error!?Listing {
    var headers: std.ArrayList(@import("foundation").http.Header) = .empty;
    if (try chat.serverAuthorization(call)) |authorization| try headers.append(call.arena, .{ .name = "authorization", .value = authorization });
    return listings.answer(Listing, call, .{ .url = try modelsUrl(call), .headers = headers.items });
}

fn modelsUrl(call: *Call) Error![]const u8 {
    const base = call.provider.settings.base_url orelse
        return call.failWith(.invalid_request, "A provider of a Chat Completions server names where the server is, its base_url", .{});
    return call.arena.print("{s}/models", .{base});
}
