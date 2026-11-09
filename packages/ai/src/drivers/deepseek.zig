//! `deepseek`: the Responses API as DeepSeek serves it, without state, reached with an API key. It ignores what it
//! does not take rather than refusing it, so whatever it would ignore fails before anything is sent, and what changes
//! nothing it answers is not sent. A request goes with its tool and effort changes folded and its developer messages
//! as system ones; its events come back as they are, but for its errors, classified, and its searches, counted.
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
const http = @import("../wire/http.zig");
const json = @import("../wire/json.zig");
const responses = @import("../wire/responses.zig");
const source = @import("../wire/source.zig");
const plainItems = @import("xai.zig").plainItems;
const effortOnly = @import("xai.zig").effortOnly;

/// Where DeepSeek's API is.
pub const base_url = "https://api.deepseek.com";

pub const driver: seam.Driver = .{ .id = "deepseek", .name = "DeepSeek", .catalogue = "deepseek", .text = text };

/// What DeepSeek takes of the fields some providers take: none of them.
const taken: responses.Taken = .{ .includes = &.{}, .service_tiers = &.{}, .web_search_domains = 0 };

/// The one custom tool DeepSeek takes, by name.
const apply_patch = "apply_patch";

const wire: responses.StreamWire = .{ .kind_of = kindOf, .response = withSearchesCounted };

fn kindOf(_: ?[]const u8, message: ?[]const u8) ?failure_.Kind {
    return if (responses.contextTooLong(message)) .context_overflow else null;
}

fn details(arena: Allocator, body: []const u8) ?http.Details {
    return responses.streamDetails(arena, body, wire);
}

/// Checks the request against what DeepSeek takes for `model`: a custom tool but `apply_patch`, an image but in a user
/// message or a function's output, and the fields it would ignore.
fn checkRequest(call: *seam.Call, model: *const Model, request: *const Request) Error!void {
    try check.parts(call, model, request, &.{.custom_tools});
    try responses.checkTaken(call, model, request, taken);
    const reference = try model.reference(call.arena);
    var tools: std.ArrayList(vocabulary.Tool) = .empty;
    try tools.appendSlice(call.arena, request.tools orelse &.{});
    for (check.inputItems(request)) |item| if (item == .additional_tools) try tools.appendSlice(call.arena, item.additional_tools.tools);
    for (tools.items) |tool| if (tool == .custom and !std.mem.eql(u8, tool.custom.name, apply_patch)) {
        return call.failWith(.invalid_request, "The model {s} takes a custom tool only as {s}, and the request declares {s}", .{ reference, apply_patch, tool.custom.name });
    };
    for (check.inputItems(request), 0..) |item, index| {
        if (item != .input_message or item.input_message.role == .user) continue;
        const parts = switch (item.input_message.content) {
            .text => continue,
            .parts => |parts| parts,
        };
        for (parts) |part| if (part == .input_image) {
            return call.failWith(.invalid_request, "The {t} message at input[{d}] holds an image: the model {s} reads images only from users and functions", .{ item.input_message.role, index, reference });
        };
    }
}

/// The request as it goes to DeepSeek for `model`: the model by its id, its tool and effort changes folded, its
/// developer messages as system ones, its tools as DeepSeek takes them, its provider options among its fields, and none
/// of what changes nothing DeepSeek answers.
pub fn wireRequest(arena: Allocator, model: *const Model, request: Request) Allocator.Error![]const u8 {
    var sent = try responses.withoutExplicitCaching(arena, try responses.foldEffortChanges(arena, try responses.foldToolChanges(arena, request)));
    const tools = sent.tools;
    const reasoning = sent.reasoning;
    inline for (.{ "tools", "reasoning", "metadata", "safety_identifier", "truncation", "prompt_cache_key", "session_id", "trace", "debug", "provider", "models", "plugins", "stop_server_tools_when", "max_tool_calls", "include", "service_tier", "modalities", "store" }) |field| @field(sent, field) = null;
    try plainItems(arena, &sent);
    for (@constCast(check.inputItems(&sent))) |*item| if (item.* == .input_message and item.input_message.role == .developer) {
        item.input_message.role = .system;
    };
    return foundation.json.encode(arena, foundation.json.merged(.{ sent, try json.ownOptions(arena, &request, "deepseek"), .{
        .model = model.id,
        .tools = if (tools) |given| try responses.plainTools(arena, given) else null,
        .reasoning = effortOnly(reasoning),
        .stream = true,
    } }));
}

fn text(call: *seam.Call, model: *const Model, request: *const Request) Error!seam.TextSource {
    try checkRequest(call, model, request);
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

fn translate(call: *seam.Call, data: []const u8, out: *std.ArrayList(vocabulary.ResponseStreamEvent)) Error!void {
    try out.append(call.arena, try responses.streamEvent(call, data, wire));
}

/// DeepSeek's response with its searches counted where it ran any, as it reports none: its web search calls that
/// searched.
fn withSearchesCounted(_: *seam.Call, response: vocabulary.Response, _: std.json.Value) Error!vocabulary.Response {
    var searches: u64 = 0;
    for (response.output) |item| if (item == .web_search_call) if (item.web_search_call.action) |action| {
        if (action == .search) searches += 1;
    };
    var usage = response.usage orelse return response;
    if (searches == 0) return response;
    var used = usage.server_tool_use_details orelse @TypeOf(usage.server_tool_use_details.?){};
    used.web_search_requests = searches;
    usage.server_tool_use_details = used;
    var made = response;
    made.usage = usage;
    return made;
}
