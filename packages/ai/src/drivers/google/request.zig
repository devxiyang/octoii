//! A text request as Google's Interactions API takes it: the instructions and the leading updates as its
//! `system_instruction`, the conversation as steps, later updates inside `<system-update>` at the end of the user's
//! turn, calls with Gemini's ids and their results naming them, thoughts and Google's searches as the model wrote
//! them, files inline or for Google to fetch, text files as their text, tools, and the settings in its
//! `generation_config` and `response_format`. What Google does not take fails before anything is sent; what changes
//! nothing it answers, such as the caching fields, is not sent.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const foundation = @import("foundation");
const Raw = foundation.json.Raw;
const vocabulary = @import("vocabulary");
const content = vocabulary.content;
const Request = vocabulary.ResponsesRequest;
const Item = vocabulary.Item;
const InputContent = vocabulary.InputContent;
const ReasoningEffort = vocabulary.items.ReasoningEffort;
const seam = @import("../../driver.zig");
const Call = seam.Call;
const Error = @import("../../failure.zig").Error;
const model_ = @import("../../catalogue/model.zig");
const Model = model_.Model;
const files = @import("../../text/files.zig");
const tags = @import("../../wire/tags.zig");
const responses = @import("../../wire/responses.zig");
const json = @import("../../wire/json.zig");

const joiner = "\n\n";

/// A block of a step's content.
pub const Block = union(enum) {
    text: struct { type: enum { text } = .text, text: []const u8 },
    image: struct { type: enum { image } = .image, data: ?[]const u8 = null, uri: ?[]const u8 = null, mime_type: ?[]const u8 = null, resolution: ?enum { low, high, ultra_high } = null },
    audio: struct { type: enum { audio } = .audio, data: []const u8, mime_type: []const u8 },
    video: Source(enum { video }),
    document: Source(enum { document }),

    pub fn jsonStringify(block: Block, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (block) {
            inline else => |payload| try writer.write(payload),
        }
    }
};

fn Source(comptime Type: type) type {
    return struct { type: Type = @fromBackingInt(@intCast(0)), data: ?[]const u8 = null, uri: ?[]const u8 = null, mime_type: ?[]const u8 = null };
}

/// What a search found that Google asks to be shown.
const Suggestions = struct { search_suggestions: []const u8 };

/// A step of the conversation.
pub const Step = union(enum) {
    user_input: struct { type: enum { user_input } = .user_input, content: *std.ArrayList(Block) },
    model_output: struct { type: enum { model_output } = .model_output, content: []const Block },
    function_call: struct { type: enum { function_call } = .function_call, id: []const u8, name: []const u8, arguments: Value },
    function_result: struct { type: enum { function_result } = .function_result, call_id: []const u8, name: []const u8, result: []const Block, is_error: ?bool = null },
    thought: struct { type: enum { thought } = .thought, signature: ?[]const u8 = null, summary: ?[]const Block = null },
    google_search_call: struct { type: enum { google_search_call } = .google_search_call, id: []const u8, arguments: struct { queries: []const []const u8 }, signature: ?[]const u8 = null },
    google_search_result: struct { type: enum { google_search_result } = .google_search_result, call_id: []const u8, result: []const Suggestions, signature: ?[]const u8 = null },

    pub fn jsonStringify(step: Step, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (step) {
            .user_input => |user| try writer.write(.{ .type = user.type, .content = user.content.items }),
            inline else => |payload| try writer.write(payload),
        }
    }

    /// Whether the step is on the user's side of the conversation, after which an update waits.
    fn userSide(step: Step) bool {
        return step == .user_input or step == .function_result;
    }
};

const Tool = union(enum) {
    function: struct { type: enum { function } = .function, name: []const u8, description: ?[]const u8 = null, parameters: ?Raw = null },
    google_search: struct { type: enum { google_search } = .google_search },

    pub fn jsonStringify(tool: Tool, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (tool) {
            inline else => |payload| try writer.write(payload),
        }
    }
};

const ChoiceMode = enum { auto, validated, none, any };

const ToolChoice = union(enum) {
    mode: ChoiceMode,
    allowed: struct { allowed_tools: struct { mode: ChoiceMode, tools: []const []const u8 } },

    pub fn jsonStringify(choice: ToolChoice, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (choice) {
            inline else => |payload| try writer.write(payload),
        }
    }
};

const GenerationConfig = struct {
    max_output_tokens: ?u64 = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    stop_sequences: ?[]const []const u8 = null,
    thinking_level: ?enum { minimal, low, medium, high } = null,
    thinking_summaries: ?enum { auto } = null,
    tool_choice: ?ToolChoice = null,

    fn empty(config: GenerationConfig) bool {
        inline for (comptime std.meta.fieldNames(GenerationConfig)) |name| if (@field(config, name) != null) return false;
        return true;
    }
};

const TextFormat = struct { type: enum { text } = .text, mime_type: ?[]const u8 = null, schema: ?Raw = null };

/// The fields of `image_config` Google's image format takes, by the same names.
const ImageConfig = struct { aspect_ratio: ?Value = null, image_size: ?Value = null };

const FormatPart = union(enum) {
    text: TextFormat,
    image: struct { type: enum { image } = .image, aspect_ratio: ?Value = null, image_size: ?Value = null },

    pub fn jsonStringify(part: FormatPart, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (part) {
            inline else => |payload| try writer.write(payload),
        }
    }
};

const ResponseFormat = union(enum) {
    text: TextFormat,
    parts: []const FormatPart,

    pub fn jsonStringify(format: ResponseFormat, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (format) {
            inline else => |payload| try writer.write(payload),
        }
    }
};

/// The interaction a text request asks for.
pub const Interaction = struct {
    model: []const u8,
    input: []const Step,
    system_instruction: ?[]const u8 = null,
    tools: ?[]const Tool = null,
    response_format: ?ResponseFormat = null,
    generation_config: ?GenerationConfig = null,
};

/// The interaction `request` asks Google for, prepared for `model`; `Failed` for what Google does not take.
pub fn interaction(call: *Call, model: *const Model, request: *const Request) Error!Interaction {
    try checkFields(call, model, request);
    const folded = try responses.foldEffortChanges(call.arena, try responses.foldToolChanges(call.arena, request.*));
    const items: []const Item = if (folded.input) |input| switch (input) {
        .text => |text| try call.arena.dupe(Item, &.{.{ .input_message = .{ .role = .user, .content = .{ .text = text } } }}),
        .parts => |parts| parts,
    } else &.{};
    var leading: usize = 0;
    while (leading < items.len and isUpdate(items[leading])) leading += 1;
    var builder: Builder = .{ .call = call, .targets = try callTargets(call.arena, items[leading..]) };
    const system = try builder.systemInstruction(folded.instructions, items[0..leading]);
    for (items[leading..]) |item| try builder.add(item);
    try builder.flush();
    const tools = try wireTools(call, folded.tools orelse &.{});
    const config = try generationConfig(call, &folded);
    return .{
        .model = model.id,
        .input = builder.steps.items,
        .system_instruction = if (system.len == 0) null else system,
        .tools = if (tools.len == 0) null else tools,
        .response_format = try responseFormat(call.arena, &folded),
        .generation_config = if (config.empty()) null else config,
    };
}

/// Checks that Google takes every setting of `request`, naming the first it does not.
fn checkFields(call: *Call, model: *const Model, request: *const Request) Error!void {
    const refuse: Refusal = .{ .call = call, .model = model };
    if (request.reasoning) |reasoning| {
        if (reasoning.context) |context| if (context != .auto) return refuse.of("reasoning.context {t}", .{context});
        if (reasoning.mode) |mode| if (mode != .standard) return refuse.of("reasoning.mode {t}", .{mode});
        if (reasoning.max_tokens != null) return refuse.of("reasoning.max_tokens: Google thinks at a level, which an effort gives", .{});
    }
    const unoffered = [_]struct { []const u8, bool }{
        .{ "top_k", request.top_k != null },
        .{ "frequency_penalty", request.frequency_penalty != null },
        .{ "presence_penalty", request.presence_penalty != null },
        .{ "top_logprobs", request.top_logprobs != null },
        .{ "max_tool_calls", request.max_tool_calls != null },
        .{ "parallel_tool_calls: false", request.parallel_tool_calls == false },
        .{ "stop_server_tools_when", request.stop_server_tools_when != null },
        .{ "text.verbosity", if (request.text) |text| text.verbosity != null else false },
    };
    for (unoffered) |field| if (field[1]) return refuse.of("{s}", .{field[0]});
    if (request.service_tier) |tier| if (tier != .auto and tier != .default) return refuse.of("service_tier {t}", .{tier});
    if (wantsImages(request) and std.mem.indexOfScalar(model_.OutputModality, model.architecture.output_modalities, .image) == null) {
        return refuse.of("images in its output", .{});
    }
    if (request.image_config) |config| {
        const value = std.json.parseFromSliceLeaky(Value, call.arena, config.text, .{}) catch Value{ .null = {} };
        if (value == .object) for (value.object.keys()) |key| {
            if (!std.mem.eql(u8, key, "aspect_ratio") and !std.mem.eql(u8, key, "image_size")) return refuse.of("image_config.{s}", .{key});
        };
    }
    for (request.tools orelse &.{}) |tool| if (tool == .function) {
        const function = tool.function;
        if (function.allowed_callers) |callers| for (callers) |caller| if (caller == .programmatic) return refuse.of("programmatic callers of {s}", .{function.name});
        if (function.output_schema != null) return refuse.of("an output_schema of {s}", .{function.name});
    };
}

const Refusal = struct {
    call: *Call,
    model: *const Model,

    fn of(refusal: Refusal, comptime what: []const u8, arguments: anytype) Error {
        const call = refusal.call;
        return call.failWith(.invalid_request, "The model {s} cannot take {s}: Google does not offer it", .{ try refusal.model.reference(call.arena), try call.arena.print(what, arguments) });
    }
};

fn wantsImages(request: *const Request) bool {
    const modalities = request.modalities orelse return false;
    for (modalities) |modality| if (modality == .image) return true;
    return false;
}

fn isUpdate(item: Item) bool {
    return item == .input_message and item.input_message.role != .user;
}

/// A call's function and Gemini's id of it, by which its result names it.
const Target = struct { name: []const u8, id: []const u8 };

/// The function and Gemini's id of each call of the conversation, by its `call_id`; a call Gemini gave no id goes by
/// its own.
fn callTargets(arena: Allocator, items: []const Item) Allocator.Error!std.StringHashMapUnmanaged(Target) {
    var targets: std.StringHashMapUnmanaged(Target) = .empty;
    for (items) |item| if (item == .function_call) {
        const call = item.function_call;
        const metadata = try googleMetadata(arena, call.octoii);
        try targets.put(arena, call.call_id, .{ .name = call.name, .id = json.textOf(metadata, "id") orelse call.call_id });
    };
    return targets;
}

/// What Google attached to an item, under its id; an empty object for nothing.
pub fn googleMetadata(arena: Allocator, extension: ?vocabulary.extensions.ItemExtension) Allocator.Error!Value {
    const empty: Value = .{ .object = .empty };
    const given = extension orelse return empty;
    const metadata = given.provider_metadata orelse return empty;
    const parsed = std.json.parseFromSliceLeaky(Value, arena, metadata.text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return empty,
    };
    if (parsed != .object) return empty;
    const own = parsed.object.get("google") orelse return empty;
    return if (own == .object) own else empty;
}

/// The steps of a conversation as they are added, with the updates that wait for the end of the user's turn.
const Builder = struct {
    call: *Call,
    targets: std.StringHashMapUnmanaged(Target),
    steps: std.ArrayList(Step) = .empty,
    /// The content of the last step, where it is the user's.
    user_content: ?*std.ArrayList(Block) = null,
    waiting: std.ArrayList(Block) = .empty,

    /// The system instruction: the instructions, then each leading update's text, apart; text alone.
    fn systemInstruction(builder: *Builder, instructions: ?[]const u8, updates: []const Item) Error![]const u8 {
        const arena = builder.call.arena;
        var texts: std.ArrayList([]const u8) = .empty;
        if (instructions) |given| if (given.len > 0) try texts.append(arena, given);
        for (updates) |update| for (try builder.blocksOf(update.input_message.content)) |block| {
            if (block != .text) return builder.call.failWith(.invalid_request, "Google's system instruction takes text alone, and a {t} message holds a file", .{update.input_message.role});
            try texts.append(arena, block.text.text);
        };
        return std.mem.join(arena, joiner, texts.items);
    }

    fn add(builder: *Builder, item: Item) Error!void {
        const call = builder.call;
        switch (item) {
            .input_message => |message| switch (message.role) {
                .user => try builder.push(.{ .user_input = .{ .content = try builder.listOf(try builder.blocksOf(message.content)) } }),
                .developer, .system => try builder.waiting.appendSlice(call.arena, try builder.updateBlocks(message.content)),
            },
            .output_message => |message| try builder.push(.{ .model_output = .{ .content = try builder.outputBlocks(message.content) } }),
            .function_call => |given| try builder.push(try builder.functionCall(given)),
            .function_call_output => |output| try builder.push(try builder.functionResult(output)),
            .reasoning => |reasoning| if (try thought(call.arena, reasoning)) |step| try builder.push(step),
            .web_search_call => |search| try builder.searchSteps(search),
            .custom_tool_call, .custom_tool_call_output, .tool_search_call, .tool_search_output, .openrouter_tool_search => {
                return call.failWith(.invalid_request, "The item of type {t} cannot go to Google: it takes no custom tools and no tool search", .{item});
            },
            // A search OpenRouter ran, a compaction or a call OpenRouter blocked is no part of what Gemini reads back.
            else => {},
        }
    }

    /// Adds `step`, after the updates waiting where it is the model's.
    fn push(builder: *Builder, step: Step) Allocator.Error!void {
        if (!step.userSide()) try builder.flush();
        try builder.steps.append(builder.call.arena, step);
        builder.user_content = if (step == .user_input) step.user_input.content else null;
    }

    /// Gives the updates waiting to the user's turn they stand in: at the end of its last message, else a step of
    /// their own.
    fn flush(builder: *Builder) Allocator.Error!void {
        if (builder.waiting.items.len == 0) return;
        const waiting = builder.waiting.items;
        builder.waiting = .empty;
        if (builder.user_content) |user| return user.appendSlice(builder.call.arena, waiting);
        try builder.push(.{ .user_input = .{ .content = try builder.listOf(waiting) } });
    }

    fn listOf(builder: *Builder, blocks: []const Block) Allocator.Error!*std.ArrayList(Block) {
        const list = try builder.call.arena.create(std.ArrayList(Block));
        list.* = .empty;
        try list.appendSlice(builder.call.arena, blocks);
        return list;
    }

    /// A function call as Gemini wrote it, by Gemini's id, else its own, its arguments an object.
    fn functionCall(builder: *Builder, given: vocabulary.items.FunctionCall) Error!Step {
        const call = builder.call;
        if (given.namespace != null) return call.failWith(.invalid_request, "The call {s} is of a namespace, which Google does not take", .{given.call_id});
        const parsed = std.json.parseFromSliceLeaky(Value, call.arena, given.arguments, .{ .allocate = .alloc_always }) catch Value{ .null = {} };
        const target = builder.targets.get(given.call_id);
        return .{ .function_call = .{ .id = if (target) |known| known.id else given.call_id, .name = given.name, .arguments = if (parsed == .object) parsed else .{ .object = .empty } } };
    }

    /// A call's output as the result naming its call and function: its text and images as blocks, and whether it
    /// failed; Google takes nothing else in a function's result.
    fn functionResult(builder: *Builder, output: vocabulary.items.FunctionCallOutput) Error!Step {
        const call = builder.call;
        const target = builder.targets.get(output.call_id) orelse
            return call.failWith(.invalid_request, "The output of {s} answers no function call of the conversation, so Google cannot name its function", .{output.call_id});
        const parts: []const InputContent = switch (output.output) {
            .text => |text| try call.arena.dupe(InputContent, &.{.{ .input_text = .{ .text = text } }}),
            .parts => |parts| parts,
        };
        var result: std.ArrayList(Block) = .empty;
        for (parts) |part| {
            if (part == .input_audio or part == .input_video) {
                return call.failWith(.invalid_request, "The output of {s} holds an {t}, and Google takes only text and images in a function's result", .{ output.call_id, part });
            }
            const block = try builder.blockOf(part);
            if (block != .text and block != .image) {
                return call.failWith(.invalid_request, "The output of {s} holds a {t}, and Google takes only text and images in a function's result", .{ output.call_id, block });
            }
            try result.append(call.arena, block);
        }
        return .{ .function_result = .{ .call_id = target.id, .name = target.name, .result = result.items, .is_error = if (output.octoii) |extension| extension.is_error else null } };
    }

    /// A search Google ran as the steps it was: its call with its queries and its result with its search suggestions,
    /// each with its signature; nothing for a search Google did not name.
    fn searchSteps(builder: *Builder, search: vocabulary.items.WebSearchCall) Error!void {
        const arena = builder.call.arena;
        const metadata = try googleMetadata(arena, search.octoii);
        const id = json.textOf(metadata, "id") orelse return;
        const queries: []const []const u8 = if (search.action) |action| switch (action) {
            .search => |searched| searched.queries orelse try arena.dupe([]const u8, &.{searched.query}),
            else => &.{},
        } else &.{};
        try builder.push(.{ .google_search_call = .{ .id = id, .arguments = .{ .queries = queries }, .signature = json.textOf(metadata, "signature") } });
        const suggestions = json.textOf(metadata, "search_suggestions");
        const result: []const Suggestions = if (suggestions) |given| try arena.dupe(Suggestions, &.{.{ .search_suggestions = given }}) else &.{};
        try builder.push(.{ .google_search_result = .{ .call_id = id, .result = result, .signature = json.textOf(metadata, "result_signature") } });
    }

    /// An update's blocks: its text inside `<system-update>`, then its files.
    fn updateBlocks(builder: *Builder, given: vocabulary.TextOr(InputContent)) Error![]const Block {
        const arena = builder.call.arena;
        var texts: std.ArrayList([]const u8) = .empty;
        var made: std.ArrayList(Block) = .empty;
        try made.append(arena, undefined);
        for (try builder.blocksOf(given)) |block| switch (block) {
            .text => |text| try texts.append(arena, text.text),
            else => try made.append(arena, block),
        };
        made.items[0] = .{ .text = .{ .text = try tags.systemUpdate(arena, try std.mem.join(arena, joiner, texts.items)) } };
        return made.items;
    }

    /// The blocks of a user, developer or system message's content.
    fn blocksOf(builder: *Builder, given: vocabulary.TextOr(InputContent)) Error![]const Block {
        const arena = builder.call.arena;
        const parts = switch (given) {
            .text => |text| return arena.dupe(Block, &.{.{ .text = .{ .text = text } }}),
            .parts => |parts| parts,
        };
        const made = try arena.alloc(Block, parts.len);
        for (parts, made) |part, *each| each.* = try builder.blockOf(part);
        return made;
    }

    /// What a model wrote: its text, its refusal as text, and the images it made.
    fn outputBlocks(builder: *Builder, given: vocabulary.TextOr(vocabulary.OutputContent)) Error![]const Block {
        const arena = builder.call.arena;
        const parts = switch (given) {
            .text => |text| return arena.dupe(Block, &.{.{ .text = .{ .text = text } }}),
            .parts => |parts| parts,
        };
        const made = try arena.alloc(Block, parts.len);
        for (parts, made) |part, *each| each.* = switch (part) {
            .output_text => |text| .{ .text = .{ .text = text.text } },
            .refusal => |refusal| .{ .text = .{ .text = refusal.refusal } },
            .output_image => |image| try builder.fileBlock(.{ .input_image = .{ .detail = .auto, .image_url = image.image_url } }),
        };
        return made;
    }

    fn blockOf(builder: *Builder, part: InputContent) Error!Block {
        return switch (part) {
            .input_text => |text| .{ .text = .{ .text = text.text } },
            .input_audio => |audio| .{ .audio = .{ .data = audio.input_audio.data orelse "", .mime_type = try builder.call.arena.print("audio/{t}", .{audio.input_audio.format}) } },
            .input_image => |image| builder.fileBlock(.{ .input_image = image }),
            .input_file => |file| builder.fileBlock(.{ .input_file = file }),
            .input_video => |video| builder.fileBlock(.{ .input_video = video }),
        };
    }

    /// A file as Google takes it: an image, a video, or a file named a PDF, at an address as its block's `uri` for
    /// Google to fetch, with its type where one is named; any other inline, fetched by ai where it is at an address.
    fn fileBlock(builder: *Builder, file: files.TypedFile) Error!Block {
        const call = builder.call;
        if (files.address(file)) |at| {
            const declared = try files.addressedType(call, file);
            const pdf = if (declared) |media_type| std.mem.eql(u8, media_type, "application/pdf") else false;
            if (file != .input_file or pdf) return typedBlock(file, declared, .{ .uri = at });
            const fetched = try files.fetchInput(call, file);
            if (files.isText(fetched.media_type)) return .{ .text = .{ .text = try tags.fileText(call.arena, fetched.data, files.name(file)) } };
            return typedBlock(file, fetched.media_type, .{ .data = try call.arena.print("{b64}", .{fetched.data}) });
        }
        const media_type = try files.mediaType(call.arena, file, null);
        const data = files.inlineBase64(file);
        if (media_type == null or data == null) return call.failWith(.invalid_request, "An {s} goes to Google as base64 of a named type", .{file.kind()});
        if (file == .input_file and files.isText(media_type.?)) {
            const decoder = std.base64.standard.Decoder;
            const decoded = try call.arena.alloc(u8, decoder.calcSizeForSlice(data.?) catch 0);
            decoder.decode(decoded, data.?) catch return call.failWith(.invalid_request, "An {s} goes to Google as base64 of a named type", .{file.kind()});
            return .{ .text = .{ .text = try tags.fileText(call.arena, decoded, files.name(file)) } };
        }
        return typedBlock(file, media_type, .{ .data = data.? });
    }
};

/// The block of a file of `media_type`, where one is named, at `source`: an image, with the resolution its `detail`
/// asks Google to read it at; a video; and a file as a document.
fn typedBlock(file: files.TypedFile, media_type: ?[]const u8, source: struct { data: ?[]const u8 = null, uri: ?[]const u8 = null }) Block {
    return switch (file) {
        .input_image => |image| .{ .image = .{ .data = source.data, .uri = source.uri, .mime_type = media_type, .resolution = switch (image.detail) {
            .auto => null,
            .low => .low,
            .high => .high,
            .original => .ultra_high,
        } } },
        .input_video => .{ .video = .{ .data = source.data, .uri = source.uri, .mime_type = media_type } },
        .input_file => .{ .document = .{ .data = source.data, .uri = source.uri, .mime_type = media_type } },
    };
}

/// A reasoning item as the thought it was, with its summary and signature; nothing where it holds neither.
fn thought(arena: Allocator, item: vocabulary.items.ReasoningItem) Allocator.Error!?Step {
    var texts: std.ArrayList([]const u8) = .empty;
    for (item.summary orelse &.{}) |part| try texts.append(arena, part.text);
    for (item.content orelse &.{}) |part| try texts.append(arena, part.text);
    const text = try std.mem.join(arena, joiner, texts.items);
    if (text.len == 0 and item.signature == null) return null;
    const summary: ?[]const Block = if (text.len == 0) null else try arena.dupe(Block, &.{.{ .text = .{ .text = text } }});
    return .{ .thought = .{ .signature = item.signature, .summary = summary } };
}

/// The request's tools as Google's: each function as a `function` tool, and web search as Google Search.
fn wireTools(call: *Call, tools: []const vocabulary.Tool) Error![]const Tool {
    const made = try call.arena.alloc(Tool, tools.len);
    for (tools, made) |tool, *each| each.* = switch (tool) {
        .function => |function| .{ .function = .{ .name = function.name, .description = function.description, .parameters = function.parameters } },
        .web_search => |search| search: {
            try checkSearch(call, search.engine, search, &.{ "type", "engine" });
            break :search .{ .google_search = .{} };
        },
        .openrouter_web_search => |search| search: {
            const parameters = search.parameters orelse vocabulary.tools.OpenRouterWebSearchParameters{};
            try checkSearch(call, parameters.engine, parameters, &.{"engine"});
            break :search .{ .google_search = .{} };
        },
        inline else => |given| return call.failWith(.invalid_request, "The tool of type {t} cannot go to Google: it takes functions and web search", .{given.type}),
    };
    return made;
}

/// Checks that a web search asks for Google's own search with no settings, as Google Search takes none.
fn checkSearch(call: *Call, engine: ?vocabulary.tools.WebSearchEngine, settings: anytype, comptime passed: []const []const u8) Error!void {
    var named: std.ArrayList([]const u8) = .empty;
    if (engine) |given| if (given != .auto and given != .native) try named.append(call.arena, try call.arena.print("engine {t}", .{given}));
    inline for (comptime std.meta.fieldNames(@TypeOf(settings))) |name| {
        const skipped = comptime for (passed) |each| {
            if (std.mem.eql(u8, each, name)) break true;
        } else false;
        if (comptime skipped) continue;
        if (@field(settings, name) != null) try named.append(call.arena, name);
    }
    if (named.items.len == 0) return;
    return call.failWith(.invalid_request, "Google's web search takes no settings, and the request sets {s}", .{try std.mem.join(call.arena, ", ", named.items)});
}

/// The `tool_choice` of a request: `auto` `auto`, or `validated` where a function is strict; `none` `none`;
/// `required` `any`; a function `allowed_tools` of the mode `any` naming it; allowed tools their mode and names. None
/// where the request chooses nothing and no function is strict.
fn toolChoice(call: *Call, given: ?vocabulary.ToolChoice, tools: []const vocabulary.Tool) Error!?ToolChoice {
    const strict = for (tools) |tool| {
        if (tool == .function and tool.function.strict == true) break true;
    } else false;
    const auto: ChoiceMode = if (strict) .validated else .auto;
    const choice = given orelse return if (strict) .{ .mode = .validated } else null;
    return switch (choice) {
        .mode => |mode| .{ .mode = switch (mode) {
            .auto => auto,
            .none => .none,
            .required => .any,
        } },
        .function => |function| .{ .allowed = .{ .allowed_tools = .{ .mode = .any, .tools = try call.arena.dupe([]const u8, &.{function.name}) } } },
        .allowed_tools => |allowed| allowed: {
            const names = try call.arena.alloc([]const u8, allowed.tools.len);
            for (allowed.tools, names) |tool, *name| {
                const named = foundation.json.decode(struct { type: enum { function }, name: []const u8 }, call.arena, tool.text) catch
                    return call.failWith(.invalid_request, "Google allows functions alone among allowed_tools", .{});
                name.* = named.name;
            }
            break :allowed .{ .allowed = .{ .allowed_tools = .{ .mode = if (allowed.mode == .required) .any else auto, .tools = names } } };
        },
    };
}

/// The formats the request asks Google for: JSON of its schema, or any JSON, as text; with images, the text and
/// images, of `image_config`'s aspect ratio and size. None where it asks for plain text alone.
fn responseFormat(arena: Allocator, request: *const Request) Allocator.Error!?ResponseFormat {
    const format = if (request.text) |text| text.format else null;
    const json_text = if (format) |given| given != .text else false;
    const text: TextFormat = .{
        .mime_type = if (json_text) "application/json" else null,
        .schema = if (format) |given| (if (given == .json_schema) given.json_schema.schema else null) else null,
    };
    if (!wantsImages(request)) return if (json_text) .{ .text = text } else null;
    const config: ImageConfig = if (request.image_config) |raw| foundation.json.decode(ImageConfig, arena, raw.text) catch .{} else .{};
    return .{ .parts = try arena.dupe(FormatPart, &.{ .{ .text = text }, .{ .image = .{ .aspect_ratio = config.aspect_ratio, .image_size = config.image_size } } }) };
}

/// The request's settings as Google's `generation_config`, each where it is set.
fn generationConfig(call: *Call, request: *const Request) Error!GenerationConfig {
    const reasoning = request.reasoning orelse vocabulary.request.ReasoningConfig{};
    return .{
        .max_output_tokens = request.max_output_tokens,
        .temperature = request.temperature,
        .top_p = request.top_p,
        .stop_sequences = if (request.stop) |stop| switch (stop) {
            .text => |sequence| try call.arena.dupe([]const u8, &.{sequence}),
            .parts => |sequences| sequences,
        } else null,
        .thinking_level = if (reasoning.effort) |effort| switch (effort) {
            .none, .minimal => .minimal,
            .low => .low,
            .medium => .medium,
            .high => .high,
            .xhigh, .max => return call.failWith(.invalid_request, "Google's thinking levels go up to high, and the request asks for {t}", .{effort}),
        } else null,
        .thinking_summaries = if (reasoning.summary != null) .auto else null,
        .tool_choice = try toolChoice(call, request.tool_choice, request.tools orelse &.{}),
    };
}
