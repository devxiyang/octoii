//! `zai` and `zai-coding-plan`: Z.ai's API, reached with an API key, and its GLM Coding Plan, the same API at its own
//! address with the plan's own key; both serve the catalogue's models through Z.ai's Chat Completions. Reasoning is
//! kept: `thinking` goes with `clear_thinking` false and each assistant message's reasoning is given back, as Z.ai asks
//! of agents; the effort goes as `reasoning_effort`, and `none` turns thinking off. It takes only the fields Z.ai
//! defines — structured output as `json_object` alone, one stop sequence, a temperature of at most 1 and `tool_choice`
//! `auto` alone — and its finish reasons and failures are its own.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vocabulary = @import("vocabulary");
const Request = vocabulary.ResponsesRequest;
const ReasoningEffort = vocabulary.items.ReasoningEffort;
const seam = @import("../driver.zig");
const Call = seam.Call;
const failure_ = @import("../failure.zig");
const Error = failure_.Error;
const Kind = failure_.Kind;
const Model = @import("../catalogue/model.zig").Model;
const chat = @import("../wire/chat_completions.zig");
const messages = chat.messages;
const http = @import("../wire/http.zig");

/// Where Z.ai's API is.
pub const base_url = "https://api.z.ai/api/paas/v4";

/// Where the GLM Coding Plan's API is.
pub const coding_plan_base_url = "https://api.z.ai/api/coding/paas/v4";

pub const driver: seam.Driver = .{ .id = "zai", .name = "Z.ai", .catalogue = "zai", .text = chat.text(Settings, dialect(base_url)) };

pub const coding_plan: seam.Driver = .{
    .id = "zai-coding-plan",
    .name = "Z.ai GLM Coding Plan",
    .catalogue = "zai-coding-plan",
    .text = chat.text(Settings, dialect(coding_plan_base_url)),
};

/// The highest temperature Z.ai takes.
const temperature_max = 1;

/// Chat Completions as Z.ai serves it at `address`, unless its provider gives another.
pub fn dialect(comptime address: []const u8) chat.Dialect(Settings) {
    return .{
        .base_url = address,
        .messages = .{ .image_detail = false, .file_addresses = true },
        .authorization = authorization,
        .settings = settings,
        .details = details,
        .endings = &.{
            .{ "model_context_window_exceeded", .{ .incomplete = .max_output_tokens } },
            .{ "sensitive", .{ .incomplete = .content_filter } },
            .{ "network_error", .{ .failed = .{ .kind = .server, .retryable = true } } },
        },
        .stream_failure = streamFailure,
    };
}

fn authorization(call: *Call) Error!?[]const u8 {
    return try std.fmt.allocPrint(call.arena, "Bearer {s}", .{try call.apiKey()});
}

/// The request's settings as Z.ai takes them.
pub const Settings = struct {
    thinking: ?struct { type: enum { enabled, disabled }, clear_thinking: bool = false } = null,
    reasoning_effort: ?ReasoningEffort = null,
    max_tokens: ?u64 = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    stop: ?[]const []const u8 = null,
    response_format: ?messages.ResponseFormat = null,
    tool_choice: ?messages.ToolChoice = null,
};

/// The request's settings, `thinking` for a model that reasons, or that does not say and is asked an effort;
/// `invalid_request` for one Z.ai does not take.
fn settings(call: *Call, model: *const Model, request: *const Request, effort: ?ReasoningEffort) Error!Settings {
    try checkFields(call, request);
    const reasons = model.reasons() orelse (effort != null);
    return .{
        .thinking = if (reasons) .{ .type = if (effort == .none) .disabled else .enabled } else null,
        .reasoning_effort = if (effort == .none) null else effort,
        .max_tokens = request.max_output_tokens,
        .temperature = request.temperature,
        .top_p = request.top_p,
        .stop = try stopSequences(call, request.stop),
        .response_format = messages.responseFormat(request),
        .tool_choice = if (request.tool_choice != null) .{ .mode = .auto } else null,
    };
}

/// Checks that `request` sets only what Z.ai takes, naming the first it does not.
fn checkFields(call: *Call, request: *const Request) Error!void {
    const verbosity = if (request.text) |text| text.verbosity != null else false;
    const undefined_fields = [_]struct { []const u8, bool }{
        .{ "top_k", request.top_k != null },
        .{ "frequency_penalty", request.frequency_penalty != null },
        .{ "presence_penalty", request.presence_penalty != null },
        .{ "top_logprobs", request.top_logprobs != null },
        .{ "text.verbosity", verbosity },
        .{ "parallel_tool_calls", request.parallel_tool_calls != null },
        .{ "service_tier", request.service_tier != null },
    };
    for (undefined_fields) |field| if (field[1]) return refuses(call, "{s}, which it does not define", .{field[0]});
    if (request.reasoning) |reasoning| if (reasoning.mode == .pro) return refuses(call, "reasoning.mode pro, which it does not define", .{});
    if (request.text) |text| if (text.format) |format| if (format == .json_schema) {
        return refuses(call, "a json_schema format: its structured output is json_object alone", .{});
    };
    if (request.tool_choice) |choice| if (choice != .mode or choice.mode != .auto) return refuses(call, "a tool_choice other than auto", .{});
    if (request.temperature) |temperature| if (temperature > temperature_max) {
        return refuses(call, "a temperature of {d}: it takes at most {d}", .{ temperature, temperature_max });
    };
}

/// The stop sequences as Z.ai takes them, a list of one.
fn stopSequences(call: *Call, stop: ?vocabulary.TextOr([]const u8)) Error!?[]const []const u8 {
    const given = stop orelse return null;
    const sequences = switch (given) {
        .text => |sequence| try call.arena.dupe([]const u8, &.{sequence}),
        .parts => |sequences| sequences,
    };
    if (sequences.len > 1) return refuses(call, "{d} stop sequences: it takes 1", .{sequences.len});
    return sequences;
}

fn refuses(call: *Call, comptime what: []const u8, arguments: anytype) Error {
    return call.failWith(.invalid_request, "Z.ai does not take " ++ what, arguments);
}

/// The failure kind of each of Z.ai's codes that says one.
const kinds_of_codes = std.StaticStringMap(Kind).initComptime(.{
    .{ "1261", .context_overflow },
    .{ "1000", .auth },
    .{ "1001", .auth },
    .{ "1003", .auth },
    .{ "1005", .auth },
    .{ "1220", .auth },
    .{ "1311", .auth },
    .{ "1315", .auth },
    .{ "1113", .quota },
    .{ "1308", .quota },
    .{ "1309", .quota },
    .{ "1310", .quota },
    .{ "1313", .quota },
    .{ "1314", .quota },
    .{ "1316", .quota },
    .{ "1317", .quota },
    .{ "1318", .quota },
    .{ "1319", .quota },
    .{ "1320", .quota },
    .{ "1321", .quota },
    .{ "1302", .rate_limit },
    .{ "1200", .server },
    .{ "1230", .server },
    .{ "1234", .server },
    .{ "1305", .server },
    .{ "1301", .content_filter },
    .{ "1210", .invalid_request },
    .{ "1211", .invalid_request },
    .{ "1212", .invalid_request },
    .{ "1213", .invalid_request },
    .{ "1214", .invalid_request },
    .{ "1215", .invalid_request },
    .{ "1221", .invalid_request },
    .{ "1222", .invalid_request },
});

/// Z.ai's error: its code, a number as text, its kind where the code says one, and its message.
const ZaiError = struct { kind: ?Kind = null, code: ?[]const u8 = null, message: ?[]const u8 = null };

fn zaiError(arena: Allocator, given: std.json.Value) Allocator.Error!?ZaiError {
    if (given != .object) return null;
    const code: ?[]const u8 = if (given.object.get("code")) |value| switch (value) {
        .string => |text| text,
        .integer => |number| try std.fmt.allocPrint(arena, "{d}", .{number}),
        .number_string => |text| text,
        else => null,
    } else null;
    const message = given.object.get("message");
    return .{
        .kind = if (code) |each| kinds_of_codes.get(each) else null,
        .code = code,
        .message = if (message) |text| (if (text == .string) text.string else null) else null,
    };
}

/// What Z.ai's body says of a refusal before the stream: its kind where its code says one, its message and code.
fn details(arena: Allocator, body: []const u8) ?http.Details {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    if (parsed != .object) return null;
    const raised = parsed.object.get("error") orelse return null;
    const said = (zaiError(arena, raised) catch return null) orelse return null;
    return .{ .kind = said.kind, .code = said.code, .message = said.message };
}

/// The failure an error in Z.ai's stream stands for: by its code, else `server`.
fn streamFailure(arena: Allocator, given: std.json.Value) Allocator.Error!chat.stream.StreamFailure {
    const said = try zaiError(arena, given) orelse ZaiError{};
    const kind = said.kind orelse .server;
    return .{
        .octoii = .{ .kind = kind, .retryable = failure_.retryableKind(kind) },
        .code = said.code orelse @tagName(kind),
        .message = said.message orelse "Z.ai's stream failed without saying why",
    };
}
