//! A request in Anthropic's form. The instructions and the updates before every other item make its system; the
//! user's items make user turns, call outputs first; what the model wrote makes assistant turns, its own blocks as they
//! came; an update waits for the end of the user's turn, then stands as a system message, or as a `<system-update>` in
//! the user's turn where the model takes no system message or the turn holds no item of the user's. The changes the
//! model does not take where they stand are folded into the request's own first. What Anthropic has no field for fails
//! before anything is sent.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const Raw = foundation.json.Raw;
const vocabulary = @import("vocabulary");
const Request = vocabulary.ResponsesRequest;
const Item = vocabulary.Item;
const Error = @import("../../failure.zig").Error;
const Call = @import("../../driver.zig").Call;
const Model = @import("../../catalogue/model.zig").Model;
const check = @import("../../text/check.zig");
const files = @import("../../text/files.zig");
const tags = @import("../../wire/tags.zig");
const responses = @import("../../wire/responses.zig");
const wire = @import("wire.zig");

/// A request on Anthropic's wire, and the betas it needs.
pub const Built = struct { request: wire.Request, betas: []const []const u8 };

/// The request as Anthropic takes it for `model`.
pub fn build(call: *Call, model: *const Model, given: Request) Error!Built {
    try check.parts(call, model, &given, &.{.tool_search});
    try checkFields(call, &given);
    const request = try planned(call.arena, model, try withTextFilesFetched(call, given));
    const reference = try model.reference(call.arena);
    if (forcesCall(request.tool_choice) and reasons(model, request.reasoning)) {
        return call.failWith(.invalid_request, "The model {s} reasons, and Anthropic refuses a request that forces a function while the model reasons", .{reference});
    }
    const max_tokens = request.max_output_tokens orelse model.max_completion_tokens orelse
        return call.failWith(.invalid_request, "The request gives no max_output_tokens, and the model {s} has no max_completion_tokens: Anthropic needs one", .{reference});
    const explicit = request.prompt_cache_options != null;
    var conversation: Conversation = try .init(call, model, &request, explicit);
    try conversation.build();
    const tools = try toolsOf(call, request.tools orelse &.{}, request.deferred_tools);
    var betas: std.ArrayList([]const u8) = .empty;
    const items = check.inputItems(&request);
    if (holds(items, .additional_tools) or holds(items, .tool_removal)) try betas.append(call.arena, wire.inline_tools_beta);
    if (holds(items, .configuration_update)) try betas.append(call.arena, wire.message_effort_beta);
    var built: wire.Request = .{
        .model = model.id,
        .max_tokens = max_tokens,
        .system = if (conversation.system.items.len == 0) null else conversation.system.items,
        .messages = try conversation.messages(),
        .tools = if (tools.len == 0) null else tools,
        .tool_choice = if (tools.len == 0) null else try toolChoice(call, &request),
        .thinking = thinkingOf(model, request.reasoning),
        .output_config = outputConfigOf(&request),
        .stop_sequences = if (request.stop) |stop| switch (stop) {
            .text => |one| try call.arena.dupe([]const u8, &.{one}),
            .parts => |many| many,
        } else null,
        .metadata = if (request.safety_identifier orelse request.user) |id| .{ .user_id = id } else null,
        .cache_control = if (explicit) null else request.cache_control orelse .{},
    };
    if (request.service_tier) |tier| switch (tier) {
        .auto => built.service_tier = .auto,
        .default => built.service_tier = .standard_only,
        .fast => {
            built.speed = .fast;
            try betas.append(call.arena, wire.fast_mode_beta);
        },
        else => return unsupported(call, "the service tier {t}", .{tier}),
    };
    return .{ .request = built, .betas = betas.items };
}

fn unsupported(call: *Call, comptime what: []const u8, arguments: anytype) Error {
    return call.failWith(.invalid_request, "Anthropic does not take " ++ what, arguments);
}

fn holds(items: []const Item, kind: std.meta.Tag(Item)) bool {
    for (items) |item| if (item == kind) return true;
    return false;
}

/// Checks the fields Anthropic has nothing for: sampling, verbosity, a JSON object format, OpenRouter's limits on
/// hosted tools and its reasoning modes, and custom tools' calls.
fn checkFields(call: *Call, request: *const Request) Error!void {
    const sampling = [_]struct { name: []const u8, set: bool }{
        .{ .name = "temperature", .set = request.temperature != null },
        .{ .name = "top_p", .set = request.top_p != null },
        .{ .name = "top_k", .set = request.top_k != null },
        .{ .name = "frequency_penalty", .set = request.frequency_penalty != null },
        .{ .name = "presence_penalty", .set = request.presence_penalty != null },
        .{ .name = "top_logprobs", .set = request.top_logprobs != null },
    };
    for (sampling) |field| if (field.set) return unsupported(call, "{s}: its API takes no sampling fields", .{field.name});
    if (request.text) |config| {
        if (config.verbosity != null) return unsupported(call, "text.verbosity", .{});
        if (config.format) |format| if (format == .json_object) return unsupported(call, "a json_object format: it answers in JSON of a schema", .{});
    }
    if (request.max_tool_calls != null) return unsupported(call, "max_tool_calls", .{});
    if (request.stop_server_tools_when != null) return unsupported(call, "stop_server_tools_when", .{});
    if (request.reasoning) |reasoning| {
        if (reasoning.mode) |mode| if (mode != .standard) return unsupported(call, "the reasoning mode {t}", .{mode});
        if (reasoning.context) |context| if (context != .auto) return unsupported(call, "the reasoning context {t}: its models read the reasoning they keep", .{context});
    }
    for (check.inputItems(request)) |item| if (item == .custom_tool_call or item == .custom_tool_call_output) return unsupported(call, "custom tools or their calls", .{});
}

/// The request with each text file at an address fetched into inline data, as Anthropic fetches PDFs alone.
fn withTextFilesFetched(call: *Call, request: Request) Error!Request {
    const items = check.inputItems(&request);
    if (items.len == 0) return request;
    const fetched = try call.arena.dupe(Item, items);
    for (fetched) |*item| switch (item.*) {
        .input_message => |*message| message.content = try textFilesFetched(call, message.content),
        .function_call_output => |*output| output.output = try textFilesFetched(call, output.output),
        else => {},
    };
    var made = request;
    made.input = .{ .parts = fetched };
    return made;
}

fn textFilesFetched(call: *Call, given: vocabulary.TextOr(vocabulary.InputContent)) Error!vocabulary.TextOr(vocabulary.InputContent) {
    const parts = switch (given) {
        .text => return given,
        .parts => |parts| try call.arena.dupe(vocabulary.InputContent, parts),
    };
    for (parts) |*part| {
        if (part.* != .input_file) continue;
        const file: files.TypedFile = .{ .input_file = part.input_file };
        if (files.address(file) == null) continue;
        const media_type = try files.addressedType(call, file) orelse continue;
        if (!files.isText(media_type)) continue;
        const got = try files.fetchInput(call, file);
        const encoder = std.base64.standard.Encoder;
        const data = try call.arena.alloc(u8, encoder.calcSize(got.data.len));
        part.* = .{ .input_file = .{
            .file_data = try call.arena.print("data:{s};base64,{s}", .{ got.media_type, encoder.encode(data, got.data) }),
            .filename = part.input_file.filename orelse files.name(file),
        } };
    }
    return .{ .parts = parts };
}

/// The request with what another provider's tool search wrote left out, and the changes the model does not take
/// where they stand folded: the effort in effect at the end as the request's, the tools in effect at the end as its
/// tools.
fn planned(arena: Allocator, model: *const Model, given: Request) Allocator.Error!Request {
    var request = try withoutForeignSearches(arena, given);
    const items = check.inputItems(&request);
    const features = model.octoii.features orelse @import("../../catalogue/model.zig").Features{};
    if (holds(items, .configuration_update)) {
        const stops = for (items) |item| {
            if (item == .configuration_update and item.configuration_update.reasoning.effort == .none) break true;
        } else false;
        if (features.effort_updates == false or !reasons(model, request.reasoning) or stops) request = try responses.foldEffortChanges(arena, request);
    }
    const changes = check.inputItems(&request);
    if (holds(changes, .additional_tools) or holds(changes, .tool_removal)) {
        if (features.tool_updates == false or !toolChangesPlaceable(changes)) request = try withToolsFolded(arena, request);
    }
    return request;
}

/// The request without the tool searches another provider ran, which Anthropic's models search again themselves.
fn withoutForeignSearches(arena: Allocator, request: Request) Allocator.Error!Request {
    const items = check.inputItems(&request);
    if (items.len == 0) return request;
    var kept: std.ArrayList(Item) = .empty;
    for (items) |item| switch (item) {
        inline .tool_search_call, .tool_search_output => |search| if (ownBlocks(arena, search.octoii) != null) try kept.append(arena, item),
        else => try kept.append(arena, item),
    };
    var made = request;
    made.input = .{ .parts = kept.items };
    return made;
}

/// The request with the tools in effect at its end as its tools, a tool added under an earlier one's name in its place.
fn withToolsFolded(arena: Allocator, request: Request) Allocator.Error!Request {
    var folded = try responses.foldToolChanges(arena, request);
    const tools = folded.tools orelse return folded;
    var named: std.StringArrayHashMapUnmanaged(vocabulary.Tool) = .empty;
    var unnamed: std.ArrayList(vocabulary.Tool) = .empty;
    for (tools) |tool| switch (tool) {
        inline .function, .custom, .namespace => |each| try named.put(arena, each.name, tool),
        else => try unnamed.append(arena, tool),
    };
    var merged: std.ArrayList(vocabulary.Tool) = .empty;
    try merged.appendSlice(arena, named.values());
    try merged.appendSlice(arena, unnamed.items);
    folded.tools = merged.items;
    return folded;
}

/// Whether every tool change stands in a turn that holds an item of the user's, after which a system message may stand.
fn toolChangesPlaceable(items: []const Item) bool {
    var user_in_turn = false;
    var change_waiting = false;
    for (items) |item| switch (item) {
        .output_message, .function_call, .reasoning, .web_search_call, .tool_search_call, .tool_search_output => {
            if (change_waiting and !user_in_turn) return false;
            user_in_turn = false;
            change_waiting = false;
        },
        .function_call_output => user_in_turn = true,
        .input_message => |message| if (message.role == .user) {
            user_in_turn = true;
        },
        .additional_tools, .tool_removal => change_waiting = true,
        else => {},
    };
    return !change_waiting or user_in_turn;
}

/// Whether the model reasons for a request with `reasoning`: never where it does not reason or the effort is `none`,
/// else where the request asks it to or the model reasons unasked.
fn reasons(model: *const Model, reasoning: ?vocabulary.request.ReasoningConfig) bool {
    if (model.reasons() == false) return false;
    if (reasoning) |asked| if (asked.effort == .none) return false;
    if (asksReasoning(reasoning)) return true;
    const how = model.reasoning orelse return false;
    return how.mandatory or how.default_enabled == true;
}

/// Whether `reasoning` asks the model to reason: an effort, a budget, a summary, or `enabled`.
fn asksReasoning(reasoning: ?vocabulary.request.ReasoningConfig) bool {
    const asked = reasoning orelse return false;
    return asked.effort != null or asked.max_tokens != null or asked.summary != null or asked.enabled == true;
}

/// Anthropic's thinking for `reasoning`: off for the effort `none`, a budget, or adaptive; none where the request asks
/// nothing or the model does not reason.
fn thinkingOf(model: *const Model, reasoning: ?vocabulary.request.ReasoningConfig) ?wire.Thinking {
    if (model.reasons() == false) return null;
    const asked = reasoning orelse return null;
    if (asked.effort == .none) return .{ .type = .disabled };
    const display: @FieldType(wire.Thinking, "display") = if (asked.summary != null) .summarized else null;
    if (asked.max_tokens) |budget| return .{ .type = .enabled, .budget_tokens = budget, .display = display };
    return if (asksReasoning(reasoning)) .{ .type = .adaptive, .display = display } else null;
}

/// Anthropic's `output_config`: the effort, unless it is `none`, and the schema of a structured answer.
fn outputConfigOf(request: *const Request) ?wire.OutputConfig {
    var config: wire.OutputConfig = .{};
    if (request.reasoning) |reasoning| if (reasoning.effort) |effort| if (effort != .none) {
        config.effort = effort;
    };
    if (request.text) |given| if (given.format) |format| if (format == .json_schema) {
        config.format = .{ .schema = format.json_schema.schema };
    };
    return if (config.effort == null and config.format == null) null else config;
}

fn forcesCall(choice: ?vocabulary.ToolChoice) bool {
    const given = choice orelse return false;
    return switch (given) {
        .mode => |mode| mode == .required,
        .function => true,
        .allowed_tools => false,
    };
}

/// The request's tool choice as Anthropic takes it, with parallel calls turned off where the request says.
fn toolChoice(call: *Call, request: *const Request) Error!?wire.ToolChoice {
    const parallel: ?bool = if (request.parallel_tool_calls == false) true else null;
    const choice = request.tool_choice orelse return if (parallel != null) .{ .type = .auto, .disable_parallel_tool_use = true } else null;
    var made: wire.ToolChoice = switch (choice) {
        .mode => |mode| switch (mode) {
            .auto => .{ .type = .auto },
            .none => .{ .type = .none },
            .required => .{ .type = .any },
        },
        .function => |function| .{ .type = .tool, .name = function.name },
        .allowed_tools => return unsupported(call, "a tool_choice of allowed_tools", .{}),
    };
    made.disable_parallel_tool_use = parallel;
    return made;
}

/// The tools as Anthropic takes them.
fn toolsOf(call: *Call, tools: []const vocabulary.Tool, deferred: ?vocabulary.request.DeferredTools) Error![]const wire.Tool {
    const made = try call.arena.alloc(wire.Tool, tools.len);
    for (tools, made) |tool, *each| each.* = try anthropicTool(call, tool, deferred);
    return made;
}

/// The input schema of a function that declares no parameters: an object of none.
const no_parameters: Raw = .{ .text = "{\"type\":\"object\",\"properties\":{}}" };

fn anthropicTool(call: *Call, tool: vocabulary.Tool, deferred: ?vocabulary.request.DeferredTools) Error!wire.Tool {
    switch (tool) {
        .function => |function| {
            if (function.output_schema != null) return unsupported(call, "the output_schema of the function {s}", .{function.name});
            if (function.allowed_callers) |callers| for (callers) |caller| if (caller == .programmatic) {
                return unsupported(call, "a programmatic caller of the function {s}", .{function.name});
            };
            return .{ .function = .{
                .name = function.name,
                .description = function.description,
                .input_schema = function.parameters orelse no_parameters,
                .strict = function.strict,
                .defer_loading = function.defer_loading,
            } };
        },
        .web_search => |search| {
            if (try othersSet(call, search.engine, .{ .max_results = search.max_results, .mode = search.mode, .search_context_size = search.search_context_size, .x_search = search.x_search })) |set| {
                return unsupported(call, "{s}", .{set});
            }
            var blocked: std.ArrayList([]const u8) = .empty;
            var allowed: ?[]const []const u8 = null;
            if (search.filters) |filters| {
                allowed = filters.allowed_domains;
                try blocked.appendSlice(call.arena, filters.blocked_domains orelse &.{});
                try blocked.appendSlice(call.arena, filters.excluded_domains orelse &.{});
            }
            return webSearch(allowed, blocked.items, search.max_uses, search.user_location);
        },
        .openrouter_web_search => |search| {
            const parameters = search.parameters orelse vocabulary.tools.OpenRouterWebSearchParameters{};
            if (try othersSet(call, parameters.engine, .{ .max_characters = parameters.max_characters, .max_results = parameters.max_results, .max_total_results = parameters.max_total_results, .mode = parameters.mode, .search_context_size = parameters.search_context_size, .x_search = parameters.x_search })) |set| {
                return unsupported(call, "{s}", .{set});
            }
            return webSearch(parameters.allowed_domains, parameters.excluded_domains orelse &.{}, parameters.max_uses, parameters.user_location);
        },
        .tool_search => |search| {
            if (search.parameters) |parameters| if (parameters.max_results != null) return unsupported(call, "a tool search's max_results: the model sets how many tools a search finds", .{});
            const ranking = if (deferred) |given| given.search else null;
            if (ranking) |how| switch (how) {
                .custom => return unsupported(call, "a custom tool search", .{}),
                inline else => |each| if (each.max_results != null) return unsupported(call, "a tool search's max_results: the model sets how many tools a search finds", .{}),
            };
            if (ranking != null and ranking.? == .regex) return .{ .tool_search = .{ .type = .tool_search_tool_regex_20251119, .name = "tool_search_tool_regex" } };
            return .{ .tool_search = .{ .type = .tool_search_tool_bm25_20251119, .name = "tool_search_tool_bm25" } };
        },
        .custom, .namespace => return unsupported(call, "a {t} tool", .{tool}),
    }
}

/// Why a web search cannot go to Anthropic: an engine other than the provider's own, or settings it has no field
/// for; null where it can.
fn othersSet(call: *Call, engine: ?vocabulary.tools.WebSearchEngine, others: anytype) Allocator.Error!?[]const u8 {
    if (engine) |given| if (given != .auto and given != .native) return try call.arena.print("a web search by the engine {t}: it searches with its own", .{given});
    var set: std.ArrayList([]const u8) = .empty;
    inline for (@typeInfo(@TypeOf(others)).@"struct".field_names) |name| if (@field(others, name) != null) try set.append(call.arena, name);
    if (set.items.len == 0) return null;
    return try call.arena.print("the web search settings {s}", .{try std.mem.join(call.arena, ", ", set.items)});
}

fn webSearch(allowed: ?[]const []const u8, blocked: []const []const u8, max_uses: ?u32, location: ?vocabulary.tools.WebSearchUserLocation) wire.Tool {
    var search: @FieldType(wire.Tool, "web_search") = .{ .max_uses = max_uses };
    if (allowed) |domains| if (domains.len > 0) {
        search.allowed_domains = domains;
    };
    if (blocked.len > 0) search.blocked_domains = blocked;
    if (location) |where| if (where.city != null or where.region != null or where.country != null or where.timezone != null) {
        search.user_location = .{ .city = where.city, .region = where.region, .country = where.country, .timezone = where.timezone };
    };
    return .{ .web_search = search };
}

/// The blocks an item came as, where Anthropic's provider metadata on it keeps them.
pub fn ownBlocks(arena: Allocator, extension: ?vocabulary.extensions.ItemExtension) ?[]const std.json.Value {
    const given = extension orelse return null;
    const metadata = given.provider_metadata orelse return null;
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, metadata.text, .{ .allocate = .alloc_always }) catch return null;
    if (value != .object) return null;
    const own = value.object.get("anthropic") orelse return null;
    if (own != .object) return null;
    const blocks = own.object.get("blocks") orelse return null;
    return if (blocks == .array) blocks.array.items else null;
}

/// `call_id` as Anthropic takes a call's id: each character it refuses replaced by `_`.
fn wireCallId(arena: Allocator, call_id: []const u8) Allocator.Error![]const u8 {
    const made = try arena.dupe(u8, call_id);
    for (made) |*char| if (!std.ascii.isAlphanumeric(char.*) and char.* != '_' and char.* != '-') {
        char.* = '_';
    };
    return made;
}

/// The conversation as it is built, item by item, the updates held until the user's turn ends.
const Conversation = struct {
    call: *Call,
    model: *const Model,
    request: *const Request,
    system: std.ArrayList(wire.Block) = .empty,
    built: std.ArrayList(Turn) = .empty,
    /// The updates waiting for the end of the user's turn: their texts, tool changes and effort.
    texts: std.ArrayList(wire.Block) = .empty,
    tools: std.ArrayList(wire.Block) = .empty,
    effort: ?vocabulary.items.ReasoningEffort = null,
    /// Whether the turn since the model last wrote holds an item of the user's.
    user_in_turn: bool = false,
    /// The breakpoints met so far, and the first that is marked: Anthropic takes only the latest few.
    breakpoints: usize = 0,
    first_marked: usize = 0,
    ttl: @FieldType(wire.CacheControl, "ttl"),

    const Turn = struct { role: @FieldType(wire.Message, "role"), content: std.ArrayList(wire.Block) = .empty, output_config: ?wire.OutputConfig = null };

    fn init(call: *Call, model: *const Model, request: *const Request, explicit: bool) Allocator.Error!Conversation {
        var count: usize = 0;
        for (check.inputItems(request)) |item| switch (item) {
            .input_message, .function_call_output => for (check.inputContentOf(item)) |part| {
                if (part == .input_text and part.input_text.prompt_cache_breakpoint != null) count += 1;
            },
            else => {},
        };
        const kept: usize = if (explicit) wire.cache_marks else wire.cache_marks - 1;
        return .{
            .call = call,
            .model = model,
            .request = request,
            .first_marked = count -| kept,
            .ttl = if (request.cache_control) |control| control.ttl else null,
        };
    }

    fn build(conversation: *Conversation) Error!void {
        const request = conversation.request;
        if (request.instructions) |instructions| if (instructions.len > 0) try conversation.system.append(conversation.call.arena, text(instructions, null));
        const input = request.input orelse return;
        const items = switch (input) {
            .text => |whole| return conversation.user(&.{text(whole, null)}),
            .parts => |items| items,
        };
        var leading = true;
        for (items) |item| {
            if (leading and isUpdate(item)) {
                try conversation.updateTexts(&conversation.system, item.input_message.content);
                continue;
            }
            leading = false;
            try conversation.add(item);
        }
    }

    fn isUpdate(item: Item) bool {
        return item == .input_message and item.input_message.role != .user;
    }

    fn add(conversation: *Conversation, item: Item) Error!void {
        const arena = conversation.call.arena;
        switch (item) {
            .input_message => |message| if (message.role == .user) {
                try conversation.user(try conversation.userBlocks(message.content));
            } else try conversation.updateTexts(&conversation.texts, message.content),
            .output_message => |message| try conversation.assistant(try conversation.assistantBlocks(message)),
            .function_call_output => |output| try conversation.user(&.{try conversation.toolResult(output)}),
            .additional_tools => |added| for (added.tools) |tool| try conversation.tools.append(arena, .{ .tool_addition = .{
                .tool = .{ .definition = try anthropicTool(conversation.call, tool, conversation.request.deferred_tools) },
            } }),
            .tool_removal => |removal| for (removal.names) |name| try conversation.tools.append(arena, .{ .tool_removal = .{ .tool = .{ .name = name } } }),
            .configuration_update => |update| conversation.effort = update.reasoning.effort,
            .custom_tool_call, .custom_tool_call_output => return unsupported(conversation.call, "custom tools or their calls", .{}),
            .function_call => |made| {
                const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, made.arguments, .{}) catch null;
                const input: Raw = if (parsed != null and parsed.? == .object) .{ .text = try foundation.json.encode(arena, parsed.?) } else .{ .text = "{}" };
                try conversation.assistant(&.{.{ .tool_use = .{ .id = try wireCallId(arena, made.call_id), .name = made.name, .input = input } }});
            },
            .reasoning => |reasoning| {
                if (reasoning.signature) |signature| if (signature.len > 0) {
                    var thought: std.ArrayList(u8) = .empty;
                    for (reasoning.summary orelse &.{}) |part| try thought.appendSlice(arena, part.text);
                    return conversation.assistant(&.{.{ .thinking = .{ .thinking = thought.items, .signature = signature } }});
                };
                if (reasoning.encrypted_content) |data| if (data.len > 0) return conversation.assistant(&.{.{ .redacted_thinking = .{ .data = data } }});
            },
            // Only Anthropic's own searches reach here, which go back as they came.
            inline .web_search_call, .tool_search_call, .tool_search_output => |search| try conversation.assistant(try rawBlocks(arena, ownBlocks(arena, search.octoii) orelse &.{})),
            // OpenRouter's own items, and compactions only another provider reads, mean nothing to Anthropic's models.
            else => {},
        }
    }

    /// The messages, the updates still waiting placed at the end, a user's tool results first.
    fn messages(conversation: *Conversation) Error![]const wire.Message {
        try conversation.flush();
        const arena = conversation.call.arena;
        const made = try arena.alloc(wire.Message, conversation.built.items.len);
        for (conversation.built.items, made) |turn, *message| {
            var content: std.ArrayList(wire.Block) = .empty;
            if (turn.role == .user) {
                for (turn.content.items) |block| if (block == .tool_result) try content.append(arena, block);
                for (turn.content.items) |block| if (block != .tool_result) try content.append(arena, block);
            } else try content.appendSlice(arena, turn.content.items);
            message.* = .{ .role = turn.role, .content = content.items, .output_config = turn.output_config };
        }
        return made;
    }

    fn user(conversation: *Conversation, blocks: []const wire.Block) Error!void {
        if (blocks.len == 0) return;
        conversation.user_in_turn = true;
        try conversation.into(.user, blocks);
    }

    fn assistant(conversation: *Conversation, blocks: []const wire.Block) Error!void {
        if (blocks.len == 0) return;
        try conversation.flush();
        conversation.user_in_turn = false;
        try conversation.into(.assistant, blocks);
    }

    fn into(conversation: *Conversation, role: @FieldType(wire.Message, "role"), blocks: []const wire.Block) Allocator.Error!void {
        const arena = conversation.call.arena;
        const turns = &conversation.built;
        if (turns.items.len == 0 or turns.items[turns.items.len - 1].role != role) try turns.append(arena, .{ .role = role });
        try turns.items[turns.items.len - 1].content.appendSlice(arena, blocks);
    }

    /// Places the updates waiting: after the user's turn, as a system message where the model takes one, else as
    /// `<system-update>` text in the user's turn; an effort alone may stand anywhere.
    fn flush(conversation: *Conversation) Error!void {
        const arena = conversation.call.arena;
        const takes = if (conversation.model.octoii.features) |features| features.instruction_updates != false else true;
        const as_system = takes and conversation.user_in_turn;
        if (!as_system) {
            const tagged = try arena.alloc(wire.Block, conversation.texts.items.len);
            for (conversation.texts.items, tagged) |block, *made| {
                made.* = block;
                made.text.text = try tags.systemUpdate(arena, block.text.text);
            }
            try conversation.user(tagged);
        }
        var content: std.ArrayList(wire.Block) = .empty;
        if (as_system) try content.appendSlice(arena, conversation.texts.items);
        try content.appendSlice(arena, conversation.tools.items);
        if (content.items.len > 0 or conversation.effort != null) {
            try conversation.built.append(arena, .{ .role = .system, .content = content, .output_config = if (conversation.effort) |effort| .{ .effort = effort } else null });
        }
        conversation.texts = .empty;
        conversation.tools = .empty;
        conversation.effort = null;
    }

    /// The texts of an update's content, onto `into`; a file fails, as Anthropic takes none in a system message.
    fn updateTexts(conversation: *Conversation, into_list: *std.ArrayList(wire.Block), content: vocabulary.TextOr(vocabulary.InputContent)) Error!void {
        const arena = conversation.call.arena;
        switch (content) {
            .text => |whole| if (whole.len > 0) try into_list.append(arena, text(whole, null)),
            .parts => |parts| for (parts) |part| {
                if (part != .input_text) return unsupported(conversation.call, "an {t} in a developer or system message", .{part});
                try into_list.append(arena, text(part.input_text.text, conversation.cacheMark(part.input_text)));
            },
        }
    }

    fn userBlocks(conversation: *Conversation, content: vocabulary.TextOr(vocabulary.InputContent)) Error![]const wire.Block {
        var blocks: std.ArrayList(wire.Block) = .empty;
        switch (content) {
            .text => |whole| if (whole.len > 0) try blocks.append(conversation.call.arena, text(whole, null)),
            .parts => |parts| for (parts) |part| try conversation.inputBlock(&blocks, part),
        }
        return blocks.items;
    }

    fn toolResult(conversation: *Conversation, output: vocabulary.items.FunctionCallOutput) Error!wire.Block {
        const content: vocabulary.TextOr(wire.Block) = switch (output.output) {
            .text => |whole| .{ .text = whole },
            .parts => |parts| blocks: {
                var blocks: std.ArrayList(wire.Block) = .empty;
                for (parts) |part| try conversation.inputBlock(&blocks, part);
                break :blocks .{ .parts = blocks.items };
            },
        };
        const failed = if (output.octoii) |extension| extension.is_error == true else false;
        return .{ .tool_result = .{ .tool_use_id = try wireCallId(conversation.call.arena, output.call_id), .content = content, .is_error = if (failed) true else null } };
    }

    /// The block of a piece of input content: text with its cache mark, an image, or a document.
    fn inputBlock(conversation: *Conversation, blocks: *std.ArrayList(wire.Block), part: vocabulary.InputContent) Error!void {
        const call = conversation.call;
        switch (part) {
            .input_text => |given| {
                const mark = conversation.cacheMark(given);
                if (given.text.len > 0) try blocks.append(call.arena, text(given.text, mark));
            },
            .input_image => |image| {
                const file: files.TypedFile = .{ .input_image = image };
                if (files.address(file)) |at| {
                    // Anthropic fetches the image itself; a name that says it is of a type an image is not fails first.
                    _ = try files.addressedType(call, file);
                    return blocks.append(call.arena, .{ .image = .{ .source = .{ .url = .{ .url = at } } } });
                }
                try blocks.append(call.arena, .{ .image = .{ .source = try base64Source(call, file) } });
            },
            .input_file => |given| try blocks.append(call.arena, try document(call, given)),
            .input_audio, .input_video => return unsupported(call, "an {t}", .{part}),
        }
    }

    /// The cache mark a kept breakpoint asks for, with the request's lifetime; none for text without one.
    fn cacheMark(conversation: *Conversation, part: vocabulary.content.InputText) ?wire.CacheControl {
        if (part.prompt_cache_breakpoint == null) return null;
        defer conversation.breakpoints += 1;
        return if (conversation.breakpoints >= conversation.first_marked) .{ .ttl = conversation.ttl } else null;
    }

    /// The blocks of an assistant message: those it came as where they still say its text, else its text and refusals.
    fn assistantBlocks(conversation: *Conversation, message: vocabulary.items.OutputMessage) Error![]const wire.Block {
        const arena = conversation.call.arena;
        var written: std.ArrayList(u8) = .empty;
        switch (message.content) {
            .text => |whole| try written.appendSlice(arena, whole),
            .parts => |parts| for (parts) |part| switch (part) {
                .output_text => |given| try written.appendSlice(arena, given.text),
                .refusal => |given| try written.appendSlice(arena, given.refusal),
                .output_image => {},
            },
        }
        if (ownBlocks(arena, message.octoii)) |own| {
            var said: std.ArrayList(u8) = .empty;
            for (own) |block| if (json_text(block)) |words| try said.appendSlice(arena, words);
            if (std.mem.eql(u8, said.items, written.items)) return rawBlocks(arena, own);
        }
        var blocks: std.ArrayList(wire.Block) = .empty;
        switch (message.content) {
            .text => |whole| if (whole.len > 0) try blocks.append(arena, text(whole, null)),
            .parts => |parts| for (parts) |part| switch (part) {
                .output_text => |given| if (given.text.len > 0) try blocks.append(arena, text(given.text, null)),
                .refusal => |given| if (given.refusal.len > 0) try blocks.append(arena, text(given.refusal, null)),
                .output_image => return unsupported(conversation.call, "an image in an assistant message", .{}),
            },
        }
        return blocks.items;
    }
};

fn json_text(block: std.json.Value) ?[]const u8 {
    if (block != .object) return null;
    const words = block.object.get("text") orelse return null;
    return if (words == .string) words.string else null;
}

fn rawBlocks(arena: Allocator, blocks: []const std.json.Value) Allocator.Error![]const wire.Block {
    const made = try arena.alloc(wire.Block, blocks.len);
    for (blocks, made) |block, *each| each.* = .{ .raw = .{ .text = try foundation.json.encode(arena, block) } };
    return made;
}

fn text(words: []const u8, mark: ?wire.CacheControl) wire.Block {
    return .{ .text = .{ .text = words, .cache_control = mark } };
}

/// A file as Anthropic's document: a PDF inline or at its address, or a text file as plain text.
fn document(call: *Call, given: vocabulary.content.InputFile) Error!wire.Block {
    const file: files.TypedFile = .{ .input_file = given };
    if (files.address(file)) |at| {
        _ = try files.addressedType(call, file);
        return .{ .document = .{ .source = .{ .url = .{ .url = at } }, .title = given.filename } };
    }
    const source = try base64Source(call, file);
    if (!files.isText(source.base64.media_type)) return .{ .document = .{ .source = source, .title = given.filename } };
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(source.base64.data) catch return call.failWith(.invalid_request, "An inline input_file is no base64 data URL of a type: Anthropic takes it as base64", .{});
    const bytes = try call.arena.alloc(u8, size);
    decoder.decode(bytes, source.base64.data) catch return call.failWith(.invalid_request, "An inline input_file is no base64 data URL of a type: Anthropic takes it as base64", .{});
    return .{ .document = .{ .source = .{ .text = .{ .data = bytes } }, .title = given.filename } };
}

/// A file inline as Anthropic's base64 source.
fn base64Source(call: *Call, file: files.TypedFile) Error!wire.Source {
    const media_type = try files.mediaType(call.arena, file, null);
    const data = files.inlineBase64(file);
    if (media_type == null or data == null) return call.failWith(.invalid_request, "An inline {s} is no base64 data URL of a type: Anthropic takes it as base64", .{file.kind()});
    return .{ .base64 = .{ .media_type = media_type.?, .data = data.? } };
}
