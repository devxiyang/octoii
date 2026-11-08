//! What the providers that speak the Responses API share on the wire. A request is the vocabulary's with what a
//! provider does not take left out — Octoii's extensions always, explicit caching for a provider that caches by itself,
//! the changes a provider does not take where they stand folded — and OpenAI's form of it: its fields, its items as it
//! takes them, its tools under its names. Its stream comes back as the vocabulary's events, its errors classified by
//! each provider's table of codes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const foundation = @import("foundation");
const Raw = foundation.json.Raw;
const vocabulary = @import("vocabulary");
const Request = vocabulary.ResponsesRequest;
const Item = vocabulary.Item;
const Tool = vocabulary.Tool;
const Event = vocabulary.ResponseStreamEvent;
const failure_ = @import("../failure.zig");
const Error = failure_.Error;
const Kind = failure_.Kind;
const Call = @import("../driver.zig").Call;
const Model = @import("../catalogue/model.zig").Model;
const http = @import("http.zig");
const json = @import("json.zig");
const check = @import("../text/check.zig");

/// The failure kind of one of a provider's own codes or error types; null for one its table does not hold.
pub const KindOfCode = *const fn (code: []const u8) ?Kind;

// --- What every Responses provider is sent -----------------------------------------------------------------------

/// `item` without Octoii's extensions, on it or on its content: none of them reaches a provider.
pub fn withoutExtensions(arena: Allocator, item: Item) Allocator.Error!Item {
    var plain = item;
    switch (plain) {
        .input_message => |*message| message.content = try contentWithout(arena, message.content),
        inline .function_call_output, .custom_tool_call_output => |*output| output.output = try contentWithout(arena, output.output),
        else => {},
    }
    switch (plain) {
        inline else => |*payload| if (@hasField(@TypeOf(payload.*), "octoii")) {
            payload.octoii = null;
        },
    }
    return plain;
}

fn contentWithout(arena: Allocator, given: vocabulary.TextOr(vocabulary.InputContent)) Allocator.Error!vocabulary.TextOr(vocabulary.InputContent) {
    const parts = switch (given) {
        .text => return given,
        .parts => |parts| try arena.dupe(vocabulary.InputContent, parts),
    };
    for (parts) |*part| switch (part.*) {
        .input_text => {},
        inline else => |*file| file.octoii = null,
    };
    return .{ .parts = parts };
}

/// Whether the model of `reference` wrote what carries `extension`.
fn wroteIt(extension: ?vocabulary.extensions.ItemExtension, reference: []const u8) bool {
    const given = extension orelse return false;
    const model = given.model orelse return false;
    return std.mem.eql(u8, model, reference);
}

/// The items of a request, none where its input is text.
fn itemsOf(request: *const Request) []const Item {
    return check.inputItems(request);
}

/// Whether the request takes functions away from where an item stands.
pub fn hasToolRemovals(request: *const Request) bool {
    for (itemsOf(request)) |item| if (item == .tool_removal) return true;
    return false;
}

/// The request with the tools in effect at its end as its tools, its tool additions and removals replayed in order
/// and left out, for a provider that does not take the changes where they stand.
pub fn foldToolChanges(arena: Allocator, request: Request) Allocator.Error!Request {
    const list = itemsOf(&request);
    if (list.len == 0) return request;
    var in_effect: std.ArrayList(Tool) = .empty;
    try in_effect.appendSlice(arena, request.tools orelse &.{});
    var kept: std.ArrayList(Item) = .empty;
    for (list) |item| switch (item) {
        .additional_tools => |added| try in_effect.appendSlice(arena, added.tools),
        .tool_removal => |removal| {
            var index: usize = 0;
            while (index < in_effect.items.len) {
                if (removes(in_effect.items[index], removal.names)) _ = in_effect.orderedRemove(index) else index += 1;
            }
        },
        else => try kept.append(arena, item),
    };
    var folded = request;
    folded.tools = if (in_effect.items.len == 0) null else in_effect.items;
    folded.input = .{ .parts = kept.items };
    return folded;
}

/// Whether a removal of `names` takes `tool` away: a function or custom tool of one of the names.
fn removes(tool: Tool, names: []const []const u8) bool {
    const name = switch (tool) {
        .function => |function| function.name,
        .custom => |custom| custom.name,
        else => return false,
    };
    for (names) |each| if (std.mem.eql(u8, each, name)) return true;
    return false;
}

/// The request with the effort in effect at its end as its effort, its effort changes replayed and left out.
pub fn foldEffortChanges(arena: Allocator, request: Request) Allocator.Error!Request {
    const list = itemsOf(&request);
    var effort = if (request.reasoning) |reasoning| reasoning.effort else null;
    var kept: std.ArrayList(Item) = .empty;
    for (list) |item| switch (item) {
        .configuration_update => |update| effort = update.reasoning.effort,
        else => try kept.append(arena, item),
    };
    if (kept.items.len == list.len) return request;
    var folded = request;
    folded.input = .{ .parts = kept.items };
    if (effort) |in_effect| {
        var reasoning = request.reasoning orelse vocabulary.request.ReasoningConfig{};
        reasoning.effort = in_effect;
        folded.reasoning = reasoning;
    }
    return folded;
}

/// The request without explicit caching, for a provider or model that caches by itself: no `cache_control`, no
/// `prompt_cache_options`, and no breakpoint on any text, as caching never fails a request.
pub fn withoutExplicitCaching(arena: Allocator, request: Request) Allocator.Error!Request {
    var plain = request;
    plain.cache_control = null;
    plain.prompt_cache_options = null;
    const list = itemsOf(&request);
    if (list.len == 0) return plain;
    const items = try arena.dupe(Item, list);
    for (items) |*item| switch (item.*) {
        .input_message => |*message| message.content = try withoutBreakpoints(arena, message.content),
        inline .function_call_output, .custom_tool_call_output => |*output| output.output = try withoutBreakpoints(arena, output.output),
        else => {},
    };
    plain.input = .{ .parts = items };
    return plain;
}

fn withoutBreakpoints(arena: Allocator, given: vocabulary.TextOr(vocabulary.InputContent)) Allocator.Error!vocabulary.TextOr(vocabulary.InputContent) {
    const list = switch (given) {
        .text => return given,
        .parts => |list| list,
    };
    const parts = try arena.dupe(vocabulary.InputContent, list);
    for (parts) |*part| if (part.* == .input_text) {
        part.input_text.prompt_cache_breakpoint = null;
    };
    return .{ .parts = parts };
}

// --- OpenAI's Responses API --------------------------------------------------------------------------------------

/// A request as OpenAI's Responses API takes it: the vocabulary's fields it takes, its items and tools in its form,
/// kept nowhere, as a stream.
pub const OpenAiRequest = struct {
    model: []const u8,
    instructions: ?[]const u8 = null,
    input: ?vocabulary.TextOr(OpenAiItem) = null,
    tools: ?[]const OpenAiTool = null,
    tool_choice: ?vocabulary.ToolChoice = null,
    parallel_tool_calls: ?bool = null,
    max_tool_calls: ?u32 = null,
    reasoning: ?struct {
        effort: ?vocabulary.items.ReasoningEffort = null,
        summary: @FieldType(vocabulary.request.ReasoningConfig, "summary") = null,
        context: @FieldType(vocabulary.request.ReasoningConfig, "context") = null,
        mode: @FieldType(vocabulary.request.ReasoningConfig, "mode") = null,
    } = null,
    text: ?vocabulary.request.TextConfig = null,
    max_output_tokens: ?u64 = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    top_logprobs: ?u32 = null,
    truncation: @FieldType(Request, "truncation") = null,
    include: ?[]const vocabulary.request.ResponseIncludable = null,
    prompt_cache_key: ?[]const u8 = null,
    prompt_cache_options: ?vocabulary.request.PromptCacheOptions = null,
    service_tier: ?vocabulary.request.ServiceTier = null,
    metadata: ?Raw = null,
    safety_identifier: ?[]const u8 = null,
    stream: bool = true,
    store: bool = false,
};

/// An item as OpenAI takes it: the vocabulary's, or one whose tools go under OpenAI's names.
pub const OpenAiItem = union(enum) {
    item: Item,
    additional_tools: struct {
        type: enum { additional_tools } = .additional_tools,
        id: ?[]const u8 = null,
        role: @FieldType(vocabulary.items.AdditionalTools, "role"),
        tools: []const OpenAiTool,
    },
    tool_search_output: struct {
        type: enum { tool_search_output } = .tool_search_output,
        id: ?[]const u8 = null,
        call_id: []const u8,
        execution: vocabulary.items.ToolSearchExecution,
        tools: []const OpenAiTool,
        status: ?vocabulary.items.ItemStatus = null,
    },

    pub fn jsonStringify(item: OpenAiItem, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (item) {
            inline else => |payload| try writer.write(payload),
        }
    }
};

/// The parameters of a function that declares none, as OpenAI requires the field.
const NullParameters = struct { parameters: Value = .null };

/// A tool as OpenAI names it: the vocabulary's, a function whose parameters it requires, OpenRouter's web search as
/// its own, and the search for deferred tools as `tool_search`.
pub const OpenAiTool = union(enum) {
    tool: Tool,
    /// A function with no parameters, which OpenAI is sent as `null`.
    function: foundation.json.Merged(struct { vocabulary.tools.FunctionTool, NullParameters }),
    web_search: struct {
        type: enum { web_search } = .web_search,
        filters: ?struct { allowed_domains: []const []const u8 } = null,
        search_context_size: ?vocabulary.tools.SearchContextSize = null,
        user_location: ?vocabulary.tools.WebSearchUserLocation = null,
    },
    tool_search: struct { type: enum { tool_search } = .tool_search },

    pub fn jsonStringify(tool: OpenAiTool, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (tool) {
            inline else => |payload| try writer.write(payload),
        }
    }
};

/// Checks what OpenAI's Responses API refuses that no table of parts says: the fields it does not take, and a web
/// search or tool search set as it does not take them; `invalid_request` naming `provider`.
pub fn checkOpenAi(call: *Call, request: *const Request, provider: []const u8) Error!void {
    const lacking = [_]struct { field: []const u8, set: bool }{
        .{ .field = "top_k", .set = request.top_k != null },
        .{ .field = "frequency_penalty", .set = request.frequency_penalty != null },
        .{ .field = "presence_penalty", .set = request.presence_penalty != null },
        .{ .field = "stop", .set = request.stop != null },
        .{ .field = "deferred_tools", .set = request.deferred_tools != null },
        .{ .field = "stop_server_tools_when", .set = request.stop_server_tools_when != null },
    };
    for (lacking) |each| if (each.set) {
        return call.failWith(.invalid_request, "The provider {s} does not take {s}: OpenAI's Responses API has no such field", .{ provider, each.field });
    };
    for (request.tools orelse &.{}) |tool| try checkOpenAiTool(call, tool, provider);
    for (itemsOf(request)) |item| if (item == .additional_tools) for (item.additional_tools.tools) |tool| try checkOpenAiTool(call, tool, provider);
}

fn checkOpenAiTool(call: *Call, tool: Tool, provider: []const u8) Error!void {
    const setting: ?[]const u8 = switch (tool) {
        .web_search => |search| if (search.engine != null) "engine" else if (search.max_results != null) "max_results" else if (search.max_uses != null) "max_uses" else if (search.mode != null) "mode" else if (search.x_search != null) "x_search" else if (search.filters) |filters| (if (filters.blocked_domains != null) "filters.blocked_domains" else if (filters.excluded_domains != null) "filters.excluded_domains" else null) else null,
        .openrouter_web_search => |search| if (search.parameters) |parameters| (if (parameters.engine != null) "parameters.engine" else if (parameters.excluded_domains != null) "parameters.excluded_domains" else if (parameters.max_characters != null) "parameters.max_characters" else if (parameters.max_results != null) "parameters.max_results" else if (parameters.max_total_results != null) "parameters.max_total_results" else if (parameters.max_uses != null) "parameters.max_uses" else if (parameters.mode != null) "parameters.mode" else if (parameters.x_search != null) "parameters.x_search" else null) else null,
        .tool_search => |search| {
            if (search.parameters) |parameters| if (parameters.max_results != null) {
                return call.failWith(.invalid_request, "The provider {s} does not take the tool search's max_results: OpenAI's tool search has no such setting", .{provider});
            };
            return;
        },
        else => null,
    };
    const named = setting orelse return;
    const kind = if (tool == .web_search) @tagName(tool.web_search.type) else "openrouter:web_search";
    return call.failWith(.invalid_request, "The provider {s} does not take the {s} tool's {s}: OpenAI's web search takes its allowed domains, context size and location alone", .{ provider, kind, named });
}

/// The request as OpenAI's Responses API takes it for `model`: the model by its id, the effort changes folded, and
/// the tool changes too where a removal is among them; the fields it takes, the reasoning settings it knows, the
/// tools under its names, the items as `openAiItem` makes them, and the request's own settings of `provider` over it.
pub fn openAiRequest(arena: Allocator, model: *const Model, request: Request, provider: []const u8) Allocator.Error![]const u8 {
    var folded = try foldEffortChanges(arena, request);
    if (hasToolRemovals(&folded)) folded = try foldToolChanges(arena, folded);
    const reference = try model.reference(arena);
    var wire: OpenAiRequest = .{
        .model = model.id,
        .instructions = folded.instructions,
        .tools = if (folded.tools) |tools| try openAiTools(arena, tools) else null,
        .tool_choice = folded.tool_choice,
        .parallel_tool_calls = folded.parallel_tool_calls,
        .max_tool_calls = folded.max_tool_calls,
        .reasoning = if (folded.reasoning) |reasoning| .{ .effort = reasoning.effort, .summary = reasoning.summary, .context = reasoning.context, .mode = reasoning.mode } else null,
        .text = folded.text,
        .max_output_tokens = folded.max_output_tokens,
        .temperature = folded.temperature,
        .top_p = folded.top_p,
        .top_logprobs = folded.top_logprobs,
        .truncation = folded.truncation,
        .include = folded.include,
        .prompt_cache_key = folded.prompt_cache_key,
        .prompt_cache_options = folded.prompt_cache_options,
        .service_tier = folded.service_tier,
        .metadata = folded.metadata,
        .safety_identifier = folded.safety_identifier,
    };
    if (folded.input) |input| wire.input = switch (input) {
        .text => |whole| .{ .text = whole },
        .parts => |list| items: {
            var items: std.ArrayList(OpenAiItem) = .empty;
            for (list) |item| if (try openAiItem(arena, item, reference)) |made| try items.append(arena, made);
            break :items .{ .parts = items.items };
        },
    };
    return foundation.json.encode(arena, foundation.json.merged(.{ wire, try json.ownOptions(arena, &request, provider) }));
}

fn openAiTools(arena: Allocator, tools: []const Tool) Allocator.Error![]const OpenAiTool {
    const made = try arena.alloc(OpenAiTool, tools.len);
    for (tools, made) |tool, *each| each.* = openAiTool(tool);
    return made;
}

fn openAiTool(tool: Tool) OpenAiTool {
    return switch (tool) {
        .openrouter_web_search => |search| {
            const parameters = search.parameters orelse return .{ .web_search = .{} };
            return .{ .web_search = .{
                .filters = if (parameters.allowed_domains) |domains| .{ .allowed_domains = domains } else null,
                .search_context_size = parameters.search_context_size,
                .user_location = parameters.user_location,
            } };
        },
        .tool_search => .{ .tool_search = .{} },
        .function => |function| if (function.parameters == null) .{ .function = .{ .parts = .{ function, NullParameters{} } } } else .{ .tool = tool },
        else => .{ .tool = tool },
    };
}

/// `item` as OpenAI's Responses API takes it from a request, without Octoii's extensions, or null: reasoning without
/// its encrypted content left out, as OpenAI keeps nothing to look it up by; what OpenRouter wrote left out; the ids
/// of the items another model wrote left out, as OpenAI takes ids of its own alone; tools under OpenAI's names.
fn openAiItem(arena: Allocator, item: Item, reference: []const u8) Allocator.Error!?OpenAiItem {
    var made = try withoutExtensions(arena, item);
    switch (item) {
        .reasoning => |reasoning| {
            if (reasoning.encrypted_content == null) return null;
            made.reasoning.signature = null;
            made.reasoning.format = null;
            // Another model's reasoning was left out as the request was prepared: this one is the model's own.
            if (made.reasoning.summary == null) made.reasoning.summary = &.{};
        },
        inline .function_call, .custom_tool_call => |call, tag| {
            @field(made, @tagName(tag)).async = null;
            if (!wroteIt(call.octoii, reference)) @field(made, @tagName(tag)).id = null;
        },
        .additional_tools => |added| return .{ .additional_tools = .{ .id = added.id, .role = added.role, .tools = try openAiTools(arena, added.tools) } },
        .tool_search_output => |found| return .{ .tool_search_output = .{
            .id = if (wroteIt(found.octoii, reference)) found.id else null,
            .call_id = found.call_id,
            .execution = found.execution,
            .tools = try openAiTools(arena, found.tools),
            .status = found.status,
        } },
        .openrouter_web_search, .openrouter_tool_search, .armor_blocked, .context_compaction => return null,
        .output_message => |message| if (!wroteIt(message.octoii, reference)) {
            made.output_message.id = null;
        },
        .tool_search_call => |search| if (!wroteIt(search.octoii, reference)) {
            made.tool_search_call.id = null;
        },
        .compaction => |compaction| if (!wroteIt(compaction.octoii, reference)) {
            made.compaction.id = null;
        },
        else => {},
    }
    return .{ .item = made };
}

// --- The stream --------------------------------------------------------------------------------------------------

/// An error as a Responses provider sends it, in an `error` event, a failed response, or a refusal's body.
pub const WireError = struct {
    code: ?[]const u8 = null,
    type: ?[]const u8 = null,
    message: ?[]const u8 = null,
    param: ?[]const u8 = null,
};

/// The `logprobs` some providers send as `null` for none taken off, as the vocabulary leaves them out.
pub fn withoutNullLogprobs(value: *Value) void {
    switch (value.*) {
        .array => |list| for (list.items) |*entry| withoutNullLogprobs(entry),
        .object => |*members| {
            if (members.get("logprobs")) |logprobs| if (logprobs == .null) {
                _ = members.orderedRemove("logprobs");
            };
            var it = members.iterator();
            while (it.next()) |entry| withoutNullLogprobs(entry.value_ptr);
        },
        else => {},
    }
}

/// `value` read as a `T`; `invalid_response` where it is none.
pub fn decodeAs(comptime T: type, call: *Call, value: Value, data: []const u8) Error!T {
    return foundation.json.decodeValue(T, call.arena, value) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => {
            // The event itself is what tells why, and too long for the message a person reads.
            std.log.scoped(.ai).warn("an event outside the vocabulary, {t}: {s}", .{ err, data });
            var failure = try failure_.Failure.format(call.arena, .invalid_response, "The provider sent an event outside the vocabulary: {t}", .{err});
            failure.body = data;
            return call.fail(failure);
        },
    };
}

/// A failed response's error, as the provider sent it, taken off the event so that the rest reads as the
/// vocabulary's; null where it carries none.
pub fn takeResponseError(comptime E: type, call: *Call, value: *Value, data: []const u8) Error!?E {
    const response = value.object.getPtr("response") orelse return null;
    if (response.* != .object) return null;
    const given = response.object.get("error") orelse return null;
    _ = response.object.orderedRemove("error");
    if (given == .null) return null;
    return try decodeAs(E, call, given, data);
}

/// The event of the vocabulary one event of OpenAI's stream stands for: an `error` and a failed response with their
/// failures classified by `kind_of`, a code it does not know being `server`; an ended response's usage with the
/// searches its web search calls ran and the cache writes kept 12 hours, and the tokens its context took; every other
/// event as it is; null for a type the vocabulary does not have, as a provider adds its own beside the answer.
pub fn openAiEvent(call: *Call, data: []const u8, kind_of: KindOfCode) Error!?Event {
    var value = try json.parseObject(call, data);
    withoutNullLogprobs(&value);
    const kind = json.textOf(value, "type").?;
    if (!Event.names(kind)) return null;
    if (std.mem.eql(u8, kind, "error")) {
        const given = try decodeAs(struct { code: ?[]const u8 = null, type: ?[]const u8 = null, message: ?[]const u8 = null, param: ?[]const u8 = null, @"error": ?WireError = null }, call, value, data);
        const wire = given.@"error" orelse WireError{ .code = given.code, .message = given.message, .param = given.param };
        const extension = classified(wire, kind_of);
        return .{ .@"error" = .{
            .code = wire.code orelse @tagName(extension.kind),
            .message = try errorMessage(call.arena, wire) orelse "The provider's stream failed without saying why",
            .param = wire.param,
            .octoii = extension,
            .sequence_number = 0,
        } };
    }
    const failed_error = if (std.mem.eql(u8, kind, "response.failed")) try takeResponseError(WireError, call, &value, data) else null;
    var event = try decodeAs(Event, call, value, data);
    switch (event) {
        .failed => |*failed| if (failed_error) |wire| {
            const extension = classified(wire, kind_of);
            failed.response.@"error" = .{
                .code = wire.code orelse wire.type orelse @tagName(extension.kind),
                .message = try errorMessage(call.arena, wire) orelse "The response failed without saying why",
                .octoii = extension,
            };
        },
        inline .completed, .incomplete => |*ended| ended.response = withContextCounted(withUsageCounted(ended.response, try longCacheWrites(call, value, data))),
        else => {},
    }
    return event;
}

/// The failure an error in OpenAI's stream stands for: by its code or type, else the provider's own, `server`.
fn classified(wire: WireError, kind_of: KindOfCode) vocabulary.extensions.FailureExtension {
    const kind = kindOfError(wire, kind_of) orelse .server;
    return .{ .kind = kind, .retryable = failure_.retryableKind(kind) };
}

/// The kind of an error by its code, else by its type, as `kind_of` says.
fn kindOfError(wire: WireError, kind_of: KindOfCode) ?Kind {
    if (wire.code) |code| if (kind_of(code)) |kind| return kind;
    if (wire.type) |kind| return kind_of(kind);
    return null;
}

/// An error's message, naming the field it concerns where it names one.
fn errorMessage(arena: Allocator, wire: WireError) Allocator.Error!?[]const u8 {
    const message = wire.message orelse return null;
    const param = wire.param orelse return message;
    return try std.fmt.allocPrint(arena, "{s} ({s})", .{ message, param });
}

/// What a body of OpenAI's says of a refusal before the stream: its kind by its code or type, its message naming the
/// field it concerns, and its code; an admission error's `detail` as its message.
pub fn openAiDetails(arena: Allocator, body: []const u8, kind_of: KindOfCode) ?http.Details {
    const given = foundation.json.decode(struct { @"error": ?WireError = null, detail: ?[]const u8 = null }, arena, body) catch return null;
    if (given.detail) |detail| return .{ .message = detail };
    const wire = given.@"error" orelse return null;
    return .{ .kind = kindOfError(wire, kind_of), .message = errorMessage(arena, wire) catch null, .code = wire.code orelse wire.type };
}

/// `response`'s usage with what OpenAI counts apart or not at all: the searches of its web search calls, which it
/// bills and does not count, and the tokens written into the prompt cache for 12 hours.
fn withUsageCounted(response: vocabulary.Response, long_writes: ?u64) vocabulary.Response {
    var counted = response;
    var usage = response.usage orelse return response;
    var searches: u64 = 0;
    for (response.output) |item| if (item == .web_search_call) if (item.web_search_call.action) |action| {
        if (action == .search) searches += 1;
    };
    if (searches > 0) {
        var details = usage.server_tool_use_details orelse @TypeOf(usage.server_tool_use_details.?){};
        details.web_search_requests = searches;
        usage.server_tool_use_details = details;
    }
    if (long_writes) |writes| {
        var extension = usage.octoii orelse vocabulary.extensions.UsageExtension{};
        extension.cache_write_long_tokens = writes;
        usage.octoii = extension;
    }
    counted.usage = usage;
    return counted;
}

/// `response` with the tokens its context took, where its provider gave none apart: the input its usage counts, as a
/// response of the Responses API is one request.
pub fn withContextCounted(response: vocabulary.Response) vocabulary.Response {
    const usage = response.usage orelse return response;
    var counted = response;
    var extension = response.octoii orelse vocabulary.extensions.ResponseExtension{};
    if (extension.context_tokens == null) extension.context_tokens = usage.input_tokens;
    counted.octoii = extension;
    return counted;
}

/// The tokens an ended response wrote into the prompt cache for 12 hours, as OpenAI counts them apart.
fn longCacheWrites(call: *Call, value: Value, data: []const u8) Error!?u64 {
    const given = try decodeAs(struct { response: struct { usage: ?struct { input_tokens_details: struct { cache_write_tokens_details: ?struct { ttl_12h_tokens: u64 = 0 } = null } } = null } }, call, value, data);
    const usage = given.response.usage orelse return null;
    const details = usage.input_tokens_details.cache_write_tokens_details orelse return null;
    return if (details.ttl_12h_tokens > 0) details.ttl_12h_tokens else null;
}

// --- Other Responses providers -----------------------------------------------------------------------------------

/// What of the fields some providers take a provider takes.
pub const Taken = struct {
    /// The `include` values it takes.
    includes: []const vocabulary.request.ResponseIncludable,
    /// The service tiers it takes.
    service_tiers: []const vocabulary.request.ServiceTier,
    /// The most domains its web search's filters may allow or exclude, and never both; 0 where it takes no filters.
    web_search_domains: usize,
};

/// Checks that the request sets none of the fields some providers take that the model's provider does not, as `taken`
/// says; what it would ignore fails before anything is sent rather than going to be ignored.
pub fn checkTaken(call: *Call, model: *const Model, request: *const Request, taken: Taken) Error!void {
    const reference = try model.reference(call.arena);
    if (request.max_tool_calls != null) return refuse(call, reference, "max_tool_calls", .{});
    if (request.stop_server_tools_when) |conditions| if (conditions.len > 0) return refuse(call, reference, "stop_server_tools_when", .{});
    for (request.include orelse &.{}) |value| if (std.mem.indexOfScalar(vocabulary.request.ResponseIncludable, taken.includes, value) == null) {
        return refuse(call, reference, "the include {t}", .{value});
    };
    if (request.reasoning) |reasoning| {
        if (reasoning.context) |context| if (context != .auto) return refuse(call, reference, "the reasoning context {t}", .{context});
        if (reasoning.mode) |mode| if (mode != .standard) return refuse(call, reference, "the reasoning mode {t}", .{mode});
    }
    if (request.service_tier) |tier| if (std.mem.indexOfScalar(vocabulary.request.ServiceTier, taken.service_tiers, tier) == null) {
        return refuse(call, reference, "the service tier {t}", .{tier});
    };
    if (request.tool_choice) |choice| if (choice == .allowed_tools) return refuse(call, reference, "a tool_choice of allowed_tools", .{});
    var tools: std.ArrayList(Tool) = .empty;
    try tools.appendSlice(call.arena, request.tools orelse &.{});
    for (check.inputItems(request)) |item| if (item == .additional_tools) try tools.appendSlice(call.arena, item.additional_tools.tools);
    for (tools.items) |tool| switch (tool) {
        .function => |function| try checkTakenFunction(call, reference, function),
        .namespace => |namespace| for (namespace.tools) |member| if (member == .function) try checkTakenFunction(call, reference, member.function),
        .openrouter_web_search => return call.failWith(.invalid_request, "OpenRouter's web search runs only at OpenRouter: declare web_search for a model that searches itself", .{}),
        .web_search => |search| try checkTakenSearch(call, reference, search, taken),
        else => {},
    };
}

fn refuse(call: *Call, reference: []const u8, comptime what: []const u8, arguments: anytype) Error {
    return call.fail(try failure_.Failure.format(call.arena, .invalid_request, "The model {s} does not take " ++ what ++ ": its provider would ignore it", .{reference} ++ arguments));
}

fn checkTakenFunction(call: *Call, reference: []const u8, function: vocabulary.tools.FunctionTool) Error!void {
    if (function.output_schema != null) return refuse(call, reference, "the output_schema of the function {s}", .{function.name});
    if (function.allowed_callers) |callers| for (callers) |caller| if (caller == .programmatic) {
        return refuse(call, reference, "programmatic callers of the function {s}", .{function.name});
    };
}

fn checkTakenSearch(call: *Call, reference: []const u8, search: vocabulary.tools.WebSearchTool, taken: Taken) Error!void {
    const settings = .{ .engine = search.engine, .max_results = search.max_results, .max_uses = search.max_uses, .mode = search.mode, .search_context_size = search.search_context_size, .user_location = search.user_location, .x_search = search.x_search };
    inline for (@typeInfo(@TypeOf(settings)).@"struct".field_names) |name| {
        if (@field(settings, name) != null) return refuse(call, reference, "the web search's " ++ name, .{});
    }
    const filters = search.filters orelse return;
    const allowed = lengthOf(filters.allowed_domains);
    const excluded = lengthOf(filters.excluded_domains) + lengthOf(filters.blocked_domains);
    if (allowed + excluded == 0) return;
    if (taken.web_search_domains == 0) return refuse(call, reference, "the web search's filters", .{});
    if (allowed > 0 and excluded > 0) return refuse(call, reference, "a web search that both allows and excludes domains", .{});
    if (@max(allowed, excluded) > taken.web_search_domains) return refuse(call, reference, "a web search's filters of more than {d} domains", .{taken.web_search_domains});
}

fn lengthOf(list: ?[]const []const u8) usize {
    return if (list) |given| given.len else 0;
}

/// A tool as a provider without OpenRouter's additions takes it: a function with only the fields it reads, a web
/// search by its name with the domains its filters allow or exclude.
pub const PlainTool = union(enum) {
    tool: Tool,
    function: foundation.json.Merged(struct { struct {
        type: enum { function } = .function,
        name: []const u8,
        description: ?[]const u8 = null,
        strict: ?bool = null,
    }, struct { parameters: ?Raw } }),
    web_search: struct {
        type: enum { web_search } = .web_search,
        filters: ?struct { allowed_domains: ?[]const []const u8 = null, excluded_domains: ?[]const []const u8 = null } = null,
    },

    pub fn jsonStringify(tool: PlainTool, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (tool) {
            .function => |function| {
                // The parameters go as given, `null` among them.
                try writer.beginObject();
                try writer.objectField("type");
                try writer.write("function");
                try writer.objectField("name");
                try writer.write(function.parts[0].name);
                if (function.parts[0].description) |description| {
                    try writer.objectField("description");
                    try writer.write(description);
                }
                try writer.objectField("parameters");
                if (function.parts[1].parameters) |parameters| try writer.write(parameters) else try writer.write(null);
                if (function.parts[0].strict) |strict| {
                    try writer.objectField("strict");
                    try writer.write(strict);
                }
                try writer.endObject();
            },
            inline else => |payload| try writer.write(payload),
        }
    }
};

pub fn plainTools(arena: Allocator, tools: []const Tool) Allocator.Error![]const PlainTool {
    const made = try arena.alloc(PlainTool, tools.len);
    for (tools, made) |tool, *each| each.* = switch (tool) {
        .function => |function| .{ .function = .{ .parts = .{ .{ .name = function.name, .description = function.description, .strict = function.strict }, .{ .parameters = function.parameters } } } },
        .web_search => |search| web: {
            const filters = search.filters orelse break :web .{ .web_search = .{} };
            const allowed = filters.allowed_domains orelse &.{};
            if (allowed.len > 0) break :web .{ .web_search = .{ .filters = .{ .allowed_domains = allowed } } };
            var excluded: std.ArrayList([]const u8) = .empty;
            try excluded.appendSlice(arena, filters.excluded_domains orelse &.{});
            try excluded.appendSlice(arena, filters.blocked_domains orelse &.{});
            break :web .{ .web_search = .{ .filters = if (excluded.items.len > 0) .{ .excluded_domains = excluded.items } else null } };
        },
        else => .{ .tool = tool },
    };
    return made;
}

/// The request with each text file of its input content as its text in an `input_text`, inside `<file>` with its name
/// where it has one, for a provider that takes no text files; one at an address is fetched first where nothing names
/// it as another type. A file of another type stays as it is, for the protocol to send or refuse.
pub fn withTextFilesAsText(call: *Call, request: Request) Error!Request {
    const items = check.inputItems(&request);
    if (items.len == 0) return request;
    const made = try call.arena.dupe(Item, items);
    for (made) |*item| switch (item.*) {
        .input_message => |*message| message.content = try textsOf(call, message.content),
        inline .function_call_output, .custom_tool_call_output => |*output| output.output = try textsOf(call, output.output),
        else => {},
    };
    var texts = request;
    texts.input = .{ .parts = made };
    return texts;
}

fn textsOf(call: *Call, given: vocabulary.TextOr(vocabulary.InputContent)) Error!vocabulary.TextOr(vocabulary.InputContent) {
    const files = @import("../text/files.zig");
    const parts = switch (given) {
        .text => return given,
        .parts => |parts| try call.arena.dupe(vocabulary.InputContent, parts),
    };
    for (parts) |*part| {
        if (part.* != .input_file) continue;
        const file: files.TypedFile = .{ .input_file = part.input_file };
        const bytes: []const u8 = if (files.address(file) == null) inline_text: {
            const media_type = try files.mediaType(call.arena, file, null) orelse continue;
            if (!files.isText(media_type)) continue;
            const encoded = files.inlineBase64(file) orelse continue;
            const decoder = std.base64.standard.Decoder;
            const decoded = try call.arena.alloc(u8, decoder.calcSizeForSlice(encoded) catch continue);
            decoder.decode(decoded, encoded) catch continue;
            break :inline_text decoded;
        } else fetched: {
            if (try files.addressedType(call, file)) |named| if (!files.isText(named)) continue;
            const got = try files.fetchInput(call, file);
            if (!files.isText(got.media_type)) continue;
            break :fetched got.data;
        };
        part.* = .{ .input_text = .{ .text = try @import("tags.zig").fileText(call.arena, bytes, files.name(file)) } };
    }
    return .{ .parts = parts };
}

/// Whether a message says the context is too long for the model, in the words providers put it.
pub fn contextTooLong(message: ?[]const u8) bool {
    const given = message orelse return false;
    var lowered: [1024]u8 = undefined;
    const text = std.ascii.lowerString(&lowered, given[0..@min(given.len, lowered.len)]);
    const said = [_][]const u8{ "maximum context length", "maximum prompt length", "context length", "context window", "too many tokens", "too many input tokens", "prompt is too long" };
    for (said) |words| if (std.mem.indexOf(u8, text, words) != null) return true;
    return false;
}

/// What a provider's protocol says of its stream: how its failures are classified and its responses translated.
pub const StreamWire = struct {
    /// The kind of failure a refusal or an error in the stream stands for, by its code and message.
    kind_of: *const fn (code: ?[]const u8, message: ?[]const u8) ?Kind,
    /// The provider's response as the vocabulary's, given the response as it came.
    response: ?*const fn (call: *Call, response: vocabulary.Response, raw: Value) Error!vocabulary.Response = null,
};

/// An error's code as such a provider sends it: text, or a number.
const AnyCode = union(enum) {
    name: []const u8,
    number: i64,

    const variants = foundation.json.Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;

    fn text(code: ?AnyCode, arena: Allocator) Allocator.Error!?[]const u8 {
        const given = code orelse return null;
        return switch (given) {
            .name => |name| name,
            .number => |number| try std.fmt.allocPrint(arena, "{d}", .{number}),
        };
    }
};

const AnyError = struct { code: ?AnyCode = null, message: ?[]const u8 = null, type: ?[]const u8 = null, param: ?[]const u8 = null };

/// The vocabulary's event one event of such a provider's stands for, its errors classified and its responses
/// translated as `wire` says.
pub fn streamEvent(call: *Call, data: []const u8, wire: StreamWire) Error!Event {
    var value = try json.parseObject(call, data);
    withoutNullLogprobs(&value);
    const kind = json.textOf(value, "type").?;
    if (std.mem.eql(u8, kind, "error")) {
        const given = try decodeAs(struct { code: ?AnyCode = null, message: ?[]const u8 = null, param: ?[]const u8 = null, @"error": ?AnyError = null }, call, value, data);
        const inner = given.@"error" orelse AnyError{};
        const code = try AnyCode.text(inner.code, call.arena) orelse try AnyCode.text(given.code, call.arena) orelse inner.type;
        const message = inner.message orelse given.message orelse "The provider's stream failed without saying why";
        const extension = streamFailure(wire, code, message);
        return .{ .@"error" = .{ .code = code orelse @tagName(extension.kind), .message = message, .param = given.param orelse inner.param, .octoii = extension, .sequence_number = 0 } };
    }
    const carries = for ([_][]const u8{ "response.created", "response.in_progress", "response.completed", "response.incomplete", "response.failed" }) |each| {
        if (std.mem.eql(u8, each, kind)) break true;
    } else false;
    const given_error = if (carries) try takeResponseError(AnyError, call, &value, data) else null;
    var event = try decodeAs(Event, call, value, data);
    switch (event) {
        inline .created, .in_progress, .completed, .incomplete, .failed => |*carrier| {
            if (given_error) |wire_error| {
                const code = try AnyCode.text(wire_error.code, call.arena) orelse wire_error.type;
                const message = wire_error.message orelse "The response failed without saying why";
                const extension = streamFailure(wire, code, message);
                carrier.response.@"error" = .{ .code = code orelse @tagName(extension.kind), .message = message, .octoii = extension };
            }
            if (wire.response) |translate| carrier.response = try translate(call, carrier.response, value.object.get("response") orelse .null);
        },
        else => {},
    }
    return event;
}

/// The failure an error in the stream stands for: as its code or message says, else the provider's own, `server`.
fn streamFailure(wire: StreamWire, code: ?[]const u8, message: ?[]const u8) vocabulary.extensions.FailureExtension {
    const kind = wire.kind_of(code, message) orelse .server;
    return .{ .kind = kind, .retryable = failure_.retryableKind(kind) };
}

/// What such a provider's refusal says, in either form — its error as OpenAI's, or its code beside its message — its
/// kind as `wire` classifies it.
pub fn streamDetails(arena: Allocator, body: []const u8, wire: StreamWire) ?http.Details {
    const value = std.json.parseFromSliceLeaky(Value, arena, body, .{ .allocate = .alloc_always }) catch return null;
    if (value != .object) return null;
    const given = value.object.get("error") orelse return null;
    const wire_error: AnyError = switch (given) {
        .string => |message| .{ .code = if (json.textOf(value, "code")) |code| .{ .name = code } else null, .message = message },
        .object => foundation.json.decodeValue(AnyError, arena, given) catch return null,
        else => return null,
    };
    const code = (AnyCode.text(wire_error.code, arena) catch null) orelse wire_error.type;
    return .{ .kind = wire.kind_of(code, wire_error.message), .message = wire_error.message, .code = code };
}
