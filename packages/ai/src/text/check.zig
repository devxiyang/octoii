//! A text request checked against its model before anything is sent: the parameters, features, files and hosted
//! tools the model takes, the names of the tools, a tool search that keeps a tool loaded, and a conversation whose
//! every call is answered. What the vocabulary leaves out has no field to be set. A check that fails leaves
//! `invalid_request` saying what and why, or `payload_too_large` past the model's input limits. No check counts
//! tokens: a request too long for its model's window is its provider's to refuse.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const Request = vocabulary.ResponsesRequest;
const Item = vocabulary.Item;
const Tool = vocabulary.Tool;
const Error = @import("../failure.zig").Error;
const Call = @import("../driver.zig").Call;
const model_ = @import("../catalogue/model.zig");
const Model = model_.Model;
const files = @import("files.zig");
const image_size = @import("image_size.zig");

/// The longest name a function may have, of letters, digits, `_` and `-`.
pub const function_name_max = 64;

/// A part of a text request that works only where its provider's protocol takes it; elsewhere the request fails.
pub const Part = enum {
    async_functions,
    custom_tools,
    namespaces,
    tool_search,
    image_output,
    truncation,
    routing,

    fn described(part: Part) []const u8 {
        return switch (part) {
            .async_functions => "async functions",
            .custom_tools => "custom tools",
            .namespaces => "namespaces of tools",
            .tool_search => "deferred tools and tool search",
            .image_output => "images in its output (modalities with image, or image_config)",
            .truncation => "truncation",
            .routing => "OpenRouter's routing (provider preferences, models and plugins)",
        };
    }
};

/// Checks `request` against `model`: each check in turn, the first that fails leaving its failure.
pub fn request(call: *Call, model: *const Model, given: *const Request) Error!void {
    const reference = try model.reference(call.arena);
    const list = inputItems(given);
    try parameters(call, model, reference, given, list);
    try features(call, model, reference, given, list);
    try reasoningBudget(call, model, reference, given);
    for (list, 0..) |item, index| for (inputContentOf(item)) |part| try file(call, model, reference, part, index);
    try toolNames(call, given, list);
    try hostedTools(call, model, reference, given, list);
    try toolSearch(call, given);
    try calls(call, given, list);
}

/// Checks that every part of `given` that works only at some providers is one of `parts`, those its protocol takes.
/// A protocol calls it before it sends anything.
pub fn parts(call: *Call, model: *const Model, given: *const Request, taken: []const Part) Error!void {
    const used = try partsUsed(call.arena, given);
    var missing: std.ArrayList([]const u8) = .empty;
    for (std.enums.values(Part)) |part| {
        if (used.contains(part) and std.mem.indexOfScalar(Part, taken, part) == null) try missing.append(call.arena, part.described());
    }
    if (missing.items.len == 0) return;
    return call.failWith(.invalid_request, "The model {s} cannot take {s}: its provider does not offer what the request asks for", .{
        try model.reference(call.arena), try std.mem.join(call.arena, ", ", missing.items),
    });
}

/// Checks a prepared request, its stored files read, against the model's input limits.
pub fn inputLimits(call: *Call, model: *const Model, given: *const Request) Error!void {
    if (model.octoii.input_limits == null) return;
    var images: std.ArrayList(?[]const u8) = .empty;
    for (inputItems(given)) |item| for (inputContentOf(item)) |part| {
        if (part == .input_image) try images.append(call.arena, files.inlineBase64(.{ .input_image = part.input_image }));
    };
    return withinInputLimits(call, model, given.*, images.items);
}

/// Checks a request of any kind, its stored files read, against the model's input limits: its size as JSON, which its
/// form on the wire follows closely; the count of `images`; and the bytes and the longest side of each image given
/// inline as base64, those at an address being null. `payload_too_large` for the first past them.
pub fn withinInputLimits(call: *Call, model: *const Model, asked: anytype, images: []const ?[]const u8) Error!void {
    const limits = model.octoii.input_limits orelse return;
    const reference = try model.reference(call.arena);
    if (limits.request_bytes) |most| {
        const bytes = (try foundation.json.encode(call.arena, asked)).len;
        if (bytes > most) return call.failWith(.payload_too_large, "The request takes {d} bytes, and the model {s} takes at most {d}", .{ bytes, reference, most });
    }
    if (limits.images) |most| if (images.len > most) {
        return call.failWith(.payload_too_large, "The request holds {d} images, and the model {s} takes at most {d}", .{ images.len, reference, most });
    };
    for (images) |given| if (given) |encoded| try image(call, limits, reference, encoded);
}

fn image(call: *Call, limits: model_.InputLimits, reference: []const u8, encoded: []const u8) Error!void {
    if (limits.image_bytes == null and limits.image_side_pixels == null) return;
    const decoder = std.base64.standard.Decoder;
    // Base64 that cannot be decoded holds no image ai can read; the provider judges what it is.
    const size = decoder.calcSizeForSlice(encoded) catch return;
    const bytes = try call.arena.alloc(u8, size);
    decoder.decode(bytes, encoded) catch return;
    if (limits.image_bytes) |most| if (bytes.len > most) {
        return call.failWith(.payload_too_large, "An image of the request takes {d} bytes, and the model {s} takes at most {d}", .{ bytes.len, reference, most });
    };
    const most = limits.image_side_pixels orelse return;
    const found = image_size.of(bytes) orelse return;
    const side = @max(found.width, found.height);
    if (side > most) {
        return call.failWith(.payload_too_large, "An image of the request is {d} pixels on its longest side, and the model {s} takes at most {d}", .{ side, reference, most });
    }
}

/// The items of a request, none where its input is text.
pub fn inputItems(given: *const Request) []const Item {
    const input = given.input orelse return &.{};
    return switch (input) {
        .text => &.{},
        .parts => |items| items,
    };
}

/// The input content an item holds: a user, developer or system message's, or a call's output.
pub fn inputContentOf(item: Item) []const vocabulary.InputContent {
    const given = switch (item) {
        .input_message => |message| message.content,
        .function_call_output => |output| output.output,
        .custom_tool_call_output => |output| output.output,
        else => return &.{},
    };
    return switch (given) {
        .text => &.{},
        .parts => |list| list,
    };
}

/// Checks that the model's `supported_parameters` list every parameter the request sets.
fn parameters(call: *Call, model: *const Model, reference: []const u8, given: *const Request, list: []const Item) Error!void {
    if (model.supported_parameters == null) return;
    var missing: std.ArrayList([]const u8) = .empty;
    const asked = [_]struct { field: []const u8, parameter: []const u8, set: bool }{
        .{ .field = "temperature", .parameter = "temperature", .set = given.temperature != null },
        .{ .field = "top_p", .parameter = "top_p", .set = given.top_p != null },
        .{ .field = "top_k", .parameter = "top_k", .set = given.top_k != null },
        .{ .field = "frequency_penalty", .parameter = "frequency_penalty", .set = given.frequency_penalty != null },
        .{ .field = "presence_penalty", .parameter = "presence_penalty", .set = given.presence_penalty != null },
        .{ .field = "stop", .parameter = "stop", .set = given.stop != null },
        .{ .field = "top_logprobs", .parameter = "top_logprobs", .set = given.top_logprobs != null },
        .{ .field = "max_output_tokens", .parameter = "max_tokens", .set = given.max_output_tokens != null },
        .{ .field = "tools", .parameter = "tools", .set = (if (given.tools) |tools| tools.len > 0 else false) or hasAddedTools(list) },
        // `auto` is what a model with tools does unasked, so no model need list it.
        .{ .field = "tool_choice", .parameter = "tool_choice", .set = given.tool_choice != null and !isAuto(given.tool_choice.?) },
        .{ .field = "parallel_tool_calls", .parameter = "parallel_tool_calls", .set = given.parallel_tool_calls != null },
        .{ .field = "text.format", .parameter = "structured_outputs", .set = formatIs(given, .json_schema) },
        .{ .field = "text.format", .parameter = "response_format", .set = formatIs(given, .json_object) },
        .{ .field = "text.verbosity", .parameter = "verbosity", .set = given.text != null and given.text.?.verbosity != null },
    };
    for (asked) |each| {
        if (!each.set or model.takes(each.parameter)) continue;
        try missing.append(call.arena, if (std.mem.eql(u8, each.field, each.parameter)) each.field else try call.arena.print("{s} (as {s})", .{ each.field, each.parameter }));
    }
    if (missing.items.len == 0) return;
    return call.failWith(.invalid_request, "The model {s} does not take {s}: its supported_parameters do not list what the request sets", .{ reference, try std.mem.join(call.arena, ", ", missing.items) });
}

fn hasAddedTools(list: []const Item) bool {
    for (list) |item| if (item == .additional_tools) return true;
    return false;
}

fn isAuto(choice: vocabulary.ToolChoice) bool {
    return choice == .mode and choice.mode == .auto;
}

fn formatIs(given: *const Request, kind: std.meta.Tag(vocabulary.request.TextFormat)) bool {
    const text = given.text orelse return false;
    const format = text.format orelse return false;
    return format == kind;
}

/// Checks that a budget of reasoning tokens goes only to a reasoning model that takes one.
fn reasoningBudget(call: *Call, model: *const Model, reference: []const u8, given: *const Request) Error!void {
    const reasoning = given.reasoning orelse return;
    if (reasoning.max_tokens == null or model.reasons() == false) return;
    const how = model.reasoning orelse return;
    if (how.supports_max_tokens == true) return;
    return call.failWith(.invalid_request, "The model {s} takes no budget of reasoning tokens: reasoning.max_tokens is for a model whose reasoning.supports_max_tokens is true, and an effort goes to the others", .{reference});
}

/// Checks the request against the model's `octoii.features`, each where it is given.
fn features(call: *Call, model: *const Model, reference: []const u8, given: *const Request, list: []const Item) Error!void {
    const has = model.octoii.features orelse return;
    if (given.tool_choice) |choice| if (has.tool_choices) |choices| {
        const kind: model_.ToolChoiceKind = switch (choice) {
            .mode => |mode| switch (mode) {
                .auto => .auto,
                .none => .none,
                .required => .required,
            },
            .function, .allowed_tools => .function,
        };
        if (std.mem.indexOfScalar(model_.ToolChoiceKind, choices, kind) == null) {
            return call.failWith(.invalid_request, "The model {s} does not take a tool_choice of {t}: its octoii.features.tool_choices list {s}", .{ reference, kind, try listedKinds(call.arena, choices) });
        }
    };
    if (given.service_tier) |tier| if (has.service_tiers) |tiers| {
        const named = @tagName(tier);
        const takes = for (tiers) |each| {
            if (std.mem.eql(u8, each, named)) break true;
        } else false;
        if (!takes) return call.failWith(.invalid_request, "The model {s} does not take the service_tier {s}: its octoii.features.service_tiers list {s}", .{ reference, named, if (tiers.len == 0) "none" else try std.mem.join(call.arena, ", ", tiers) });
    };
    const sampling = has.sampling orelse return;
    const reasoning = reasonsFor(model, given, list) orelse return;
    const fields = [_]struct { name: []const u8, set: bool, effect: ?model_.SamplingEffect }{
        .{ .name = "temperature", .set = given.temperature != null, .effect = sampling.temperature },
        .{ .name = "top_p", .set = given.top_p != null, .effect = sampling.top_p },
    };
    for (fields) |field| {
        const effect = field.effect orelse continue;
        if (!field.set or (if (reasoning) effect.reasoning else effect.plain) != false) continue;
        return call.failWith(.invalid_request, "The model {s} ignores {s} {s}: its octoii.features.sampling say it takes no effect then", .{ reference, field.name, if (reasoning) "while it reasons" else "while it does not reason" });
    }
}

fn listedKinds(arena: Allocator, kinds: []const model_.ToolChoiceKind) Allocator.Error![]const u8 {
    if (kinds.len == 0) return "none";
    var names: std.ArrayList([]const u8) = .empty;
    for (kinds) |kind| try names.append(arena, @tagName(kind));
    return std.mem.join(arena, ", ", names.items);
}

/// Whether `model` reasons for the request: never where it does not reason, always where it must, else by the effort
/// in effect at the request's end, `enabled: false` being `none`, else as the model does by default; null where
/// nothing says.
fn reasonsFor(model: *const Model, given: *const Request, list: []const Item) ?bool {
    if (model.reasons() == false) return false;
    if (model.reasoning) |how| if (how.mandatory) return true;
    const asked = given.reasoning;
    var effort: ?vocabulary.items.ReasoningEffort = if (asked) |config| (if (config.enabled == false) .none else config.effort) else null;
    for (list) |item| if (item == .configuration_update) {
        effort = item.configuration_update.reasoning.effort;
    };
    if (effort) |in_effect| return in_effect != .none;
    if (asked) |config| if (config.enabled == true or config.max_tokens != null) return true;
    const how = model.reasoning orelse return null;
    if (how.default_enabled) |enabled| return enabled;
    const by_default = how.default_effort orelse return null;
    return by_default != .none;
}

/// Checks that the model reads a file's modality, and the source, name and type of an image, a file or a video.
fn file(call: *Call, model: *const Model, reference: []const u8, part: vocabulary.InputContent, index: usize) Error!void {
    const modality: model_.InputModality = switch (part) {
        .input_text => return,
        .input_image => .image,
        .input_file => .file,
        .input_audio => .audio,
        .input_video => .video,
    };
    if (!model.reads(modality)) {
        return call.failWith(.invalid_request, "input[{d}] holds an {t}, and the model {s} does not read {t}: its architecture.input_modalities lack it", .{ index, part, reference, modality });
    }
    // Audio says its format, which the vocabulary holds to the formats it takes.
    const typed = files.TypedFile.of(part) orelse return;
    if (files.address(typed)) |at| if (!std.ascii.startsWithIgnoreCase(at, "https://")) {
        return call.failWith(.invalid_request, "input[{d}] holds an {s} at an address that is not https: ai sends only https addresses", .{ index, typed.kind() });
    };
    if (typed == .input_file) if (typed.input_file.octoii) |extension| if (extension.filename != null) {
        return call.failWith(.invalid_request, "The input_file at input[{d}] gives octoii.filename: an input_file names its file in its own filename", .{index});
    };
    const declares = if (typed.octoii()) |extension| extension.media_type != null else false;
    if (files.isInline(typed) or declares) {
        _ = try files.checkedType(call, typed, try call.arena.print("The {s} at input[{d}]", .{ typed.kind(), index }), null);
    }
}

/// A tool a request declares: one of its tools, or a function or custom tool within a namespace.
const Declared = union(enum) { tool: Tool, member: vocabulary.tools.NamespaceMember };

/// The tools of the request and those its items add or a search found, those within namespaces among them.
fn declaredTools(arena: Allocator, given: *const Request, list: []const Item) Allocator.Error![]const Declared {
    var declared: std.ArrayList(Declared) = .empty;
    var lists: std.ArrayList([]const Tool) = .empty;
    try lists.append(arena, given.tools orelse &.{});
    for (list) |item| switch (item) {
        .additional_tools => |added| try lists.append(arena, added.tools),
        .tool_search_output => |found| try lists.append(arena, found.tools),
        else => {},
    };
    for (lists.items) |tools| for (tools) |tool| {
        try declared.append(arena, .{ .tool = tool });
        if (tool == .namespace) for (tool.namespace.tools) |member| try declared.append(arena, .{ .member = member });
    };
    return declared.items;
}

/// The name of a function or custom tool, and whether it is `async`; null for another tool.
fn callable(declared: Declared) ?struct { name: []const u8, is_async: bool, deferred: bool } {
    return switch (declared) {
        .tool => |tool| switch (tool) {
            .function => |function| .{ .name = function.name, .is_async = function.async == true, .deferred = function.defer_loading == true },
            .custom => |custom| .{ .name = custom.name, .is_async = custom.async == true, .deferred = custom.defer_loading == true },
            else => null,
        },
        .member => |member| switch (member) {
            .function => |function| .{ .name = function.name, .is_async = function.async == true, .deferred = function.defer_loading == true },
            .custom => |custom| .{ .name = custom.name, .is_async = custom.async == true, .deferred = custom.defer_loading == true },
        },
    };
}

/// Checks that every function and custom tool has a name every provider takes.
fn toolNames(call: *Call, given: *const Request, list: []const Item) Error!void {
    for (try declaredTools(call.arena, given, list)) |declared| {
        const named = callable(declared) orelse continue;
        if (validName(named.name)) continue;
        const kind = switch (declared) {
            inline else => |tool| @tagName(tool),
        };
        return call.failWith(.invalid_request, "The {s} tool \"{s}\" has a name providers refuse: a name is at most {d} letters, digits, _ and -", .{ kind, named.name, function_name_max });
    }
}

fn validName(text: []const u8) bool {
    if (text.len == 0 or text.len > function_name_max) return false;
    for (text) |char| if (!std.ascii.isAlphanumeric(char) and char != '_' and char != '-') return false;
    return true;
}

/// Checks that the model's `octoii.hosted_tools`, where they are known, list the web search a request declares.
fn hostedTools(call: *Call, model: *const Model, reference: []const u8, given: *const Request, list: []const Item) Error!void {
    const searches = for (try declaredTools(call.arena, given, list)) |declared| {
        if (declared == .tool and (declared.tool == .web_search or declared.tool == .openrouter_web_search)) break true;
    } else false;
    if (!searches) return;
    const hosted = model.octoii.hosted_tools orelse return;
    for (hosted) |tool| if (tool == .web_search) return;
    return call.failWith(.invalid_request, "The model {s} does not search the web itself: its octoii.hosted_tools do not list web_search", .{reference});
}

/// Checks that a request declaring the tool search keeps a tool loaded, which the model sees before it searches.
fn toolSearch(call: *Call, given: *const Request) Error!void {
    const tools = given.tools orelse return;
    var searches = false;
    for (tools) |tool| switch (tool) {
        .tool_search => searches = true,
        .function => |function| if (function.defer_loading != true) return,
        .custom => |custom| if (custom.defer_loading != true) return,
        .namespace => |namespace| for (namespace.tools) |member| switch (member) {
            inline else => |each| if (each.defer_loading != true) return,
        },
        else => return,
    };
    if (searches) return call.failWith(.invalid_request, "The request declares the tool search and defers every tool: it keeps at least one tool that is not deferred", .{});
}

/// Checks that each function and custom tool call has exactly one output among the items after it, before the next
/// item the model writes, but an `async` function's; and that no developer or system message stands while a call
/// waits for its output.
fn calls(call: *Call, given: *const Request, list: []const Item) Error!void {
    var async_names: std.StringHashMapUnmanaged(void) = .empty;
    for (try declaredTools(call.arena, given, list)) |declared| if (declared == .tool) switch (declared.tool) {
        .function => |function| if (function.async == true) try async_names.put(call.arena, function.name, {}),
        .custom => |custom| if (custom.async == true) try async_names.put(call.arena, custom.name, {}),
        .namespace => |namespace| for (namespace.tools) |member| switch (member) {
            inline else => |each| if (each.async == true) try async_names.put(call.arena, try call.arena.print("{s}.{s}", .{ namespace.name, each.name }), {}),
        },
        else => {},
    };
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var answered: std.StringHashMapUnmanaged(void) = .empty;
    var waiting: std.StringArrayHashMapUnmanaged(usize) = .empty;
    var model_wrote_last = false;
    for (list, 0..) |item, index| {
        const model_wrote = writtenByModel(item);
        if (model_wrote and !model_wrote_last) try answeredBefore(call, &waiting, try call.arena.print("before the model writes again at input[{d}]", .{index}));
        if (item == .input_message and item.input_message.role != .user and waiting.count() > 0) {
            return call.failWith(.invalid_request, "The {t} message at input[{d}] stands between a function call and its output: an update stands after the outputs", .{ item.input_message.role, index });
        }
        switch (item) {
            inline .function_call, .custom_tool_call => |made| {
                if (seen.contains(made.call_id)) return call.failWith(.invalid_request, "The call at input[{d}] repeats the call_id {s} of an earlier call", .{ index, made.call_id });
                try seen.put(call.arena, made.call_id, {});
                const name = if (made.namespace) |namespace| try call.arena.print("{s}.{s}", .{ namespace, made.name }) else made.name;
                if (made.async != true and !async_names.contains(name)) try waiting.put(call.arena, made.call_id, index);
            },
            inline .function_call_output, .custom_tool_call_output => |output| {
                if (answered.contains(output.call_id)) return call.failWith(.invalid_request, "The output at input[{d}] answers the call {s} again: a call has exactly one output", .{ index, output.call_id });
                try answered.put(call.arena, output.call_id, {});
                _ = waiting.orderedRemove(output.call_id);
            },
            else => {},
        }
        model_wrote_last = model_wrote;
    }
    try answeredBefore(call, &waiting, "by the end of the input");
}

fn answeredBefore(call: *Call, waiting: *const std.StringArrayHashMapUnmanaged(usize), when: []const u8) Error!void {
    if (waiting.count() == 0) return;
    return call.failWith(.invalid_request, "The call {s} at input[{d}] has no output {s}: every call but an async function's is answered before the model writes again", .{ waiting.keys()[0], waiting.values()[0], when });
}

/// Whether the model, or its provider for it, wrote `item`.
fn writtenByModel(item: Item) bool {
    return switch (item) {
        .output_message, .function_call, .custom_tool_call, .reasoning, .web_search_call, .openrouter_web_search => true,
        .tool_search_call, .openrouter_tool_search, .compaction, .context_compaction, .armor_blocked => true,
        .tool_search_output => |output| output.execution == .server,
        .input_message, .function_call_output, .custom_tool_call_output, .additional_tools, .tool_removal, .configuration_update => false,
    };
}

/// The parts of a request that work only where a protocol takes them.
fn partsUsed(arena: Allocator, given: *const Request) Allocator.Error!std.EnumSet(Part) {
    var used: std.EnumSet(Part) = .empty;
    const list = inputItems(given);
    for (try declaredTools(arena, given, list)) |each| {
        if (callable(each)) |named| {
            if (named.is_async) used.insert(.async_functions);
            if (named.deferred) used.insert(.tool_search);
        }
        if (each == .tool) switch (each.tool) {
            .custom => used.insert(.custom_tools),
            .namespace => used.insert(.namespaces),
            .tool_search => used.insert(.tool_search),
            else => {},
        } else if (each.member == .custom) used.insert(.custom_tools);
    }
    // A call in the input may be of an async function too, where it says so itself.
    for (list) |item| switch (item) {
        inline .function_call, .custom_tool_call => |made| if (made.async == true) used.insert(.async_functions),
        else => {},
    };
    if (given.deferred_tools != null) used.insert(.tool_search);
    const images = if (given.modalities) |modalities| std.mem.indexOfScalar(@typeInfo(@TypeOf(modalities)).pointer.child, modalities, .image) != null else false;
    if (images or given.image_config != null) used.insert(.image_output);
    // `disabled` asks for what every provider does anyway: only `auto` asks a provider to truncate.
    if (given.truncation == .auto) used.insert(.truncation);
    if (usesRouting(given)) used.insert(.routing);
    return used;
}

/// Whether the request asks for OpenRouter's routing: its provider preferences but `options`, fallback models, or
/// plugins.
fn usesRouting(given: *const Request) bool {
    if (given.models) |models| if (models.len > 0) return true;
    if (given.plugins) |plugins| if (plugins.len > 0) return true;
    const preferences = given.provider orelse return false;
    const fields = @typeInfo(@TypeOf(preferences)).@"struct";
    inline for (fields.field_names) |name| {
        if (comptime !std.mem.eql(u8, name, "options")) if (@field(preferences, name) != null) return true;
    }
    return false;
}
