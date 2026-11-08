//! A text request as Chat Completions takes it: the instructions and the updates before every other item as one
//! `system` message; each user turn as its `tool` messages, then a user message of the files its outputs held, its
//! user messages, and its updates inside `<system-update>` at the end of the last of them; and the items a model wrote
//! between two user turns as assistant messages of `reasoning_content`, text and `tool_calls`. Functions are its only
//! tools.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const content = vocabulary.content;
const Request = vocabulary.ResponsesRequest;
const Item = vocabulary.Item;
const InputContent = vocabulary.InputContent;
const Error = @import("../../failure.zig").Error;
const Call = @import("../../driver.zig").Call;
const files = @import("../../text/files.zig");
const tags = @import("../tags.zig");

/// How a provider's Chat Completions takes what a message holds.
pub const Options = struct {
    /// Whether an image's `detail` other than `auto` is sent, or the provider chooses it itself.
    image_detail: bool,
    /// Whether a file at an address goes as its `file_url`, or ai fetches it.
    file_addresses: bool,
};

/// What joins the texts Chat Completions takes as one.
const joiner = "\n\n";

/// A part of a user message.
pub const Part = union(enum) {
    text: struct { type: enum { text } = .text, text: []const u8 },
    image_url: struct { type: enum { image_url } = .image_url, image_url: struct { url: []const u8, detail: ?content.ImageDetail = null } },
    input_audio: struct { type: enum { input_audio } = .input_audio, input_audio: struct { data: []const u8, format: content.AudioFormat } },
    video_url: struct { type: enum { video_url } = .video_url, video_url: struct { url: []const u8 } },
    file: struct { type: enum { file } = .file, file: struct { file_data: ?[]const u8 = null, file_url: ?[]const u8 = null, filename: ?[]const u8 = null } },

    pub fn jsonStringify(part: Part, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (part) {
            inline else => |payload| try writer.write(payload),
        }
    }
};

/// A user message: its text, or its parts.
const User = struct { role: enum { user } = .user, content: vocabulary.TextOr(Part) };

/// A call of an assistant message.
pub const ToolCall = struct { id: []const u8, type: enum { function } = .function, function: struct { name: []const u8, arguments: []const u8 } };

pub const Message = union(enum) {
    system: struct { role: enum { system } = .system, content: []const u8 },
    user: User,
    tool: struct { role: enum { tool } = .tool, tool_call_id: []const u8, content: []const u8 },
    assistant: struct { role: enum { assistant } = .assistant, content: []const u8, reasoning_content: ?[]const u8 = null, tool_calls: ?[]const ToolCall = null },

    pub fn jsonStringify(message: Message, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (message) {
            inline else => |payload| try writer.write(payload),
        }
    }
};

/// The messages of `request`, whose changes are folded.
pub fn messages(call: *Call, request: *const Request, options: Options) Error![]const Message {
    const arena = call.arena;
    const items: []const Item = if (request.input) |input| switch (input) {
        .text => |text| try arena.dupe(Item, &.{.{ .input_message = .{ .role = .user, .content = .{ .text = text } } }}),
        .parts => |parts| parts,
    } else &.{};
    var leading: usize = 0;
    while (leading < items.len and isUpdate(items[leading])) leading += 1;
    var instructions: std.ArrayList([]const u8) = .empty;
    if (request.instructions) |given| try instructions.append(arena, given);
    for (items[0..leading]) |item| try instructions.append(arena, try instructionsText(call, item.input_message));
    var conversation: Conversation = .{ .call = call, .options = options };
    if (instructions.items.len > 0) try conversation.messages.append(arena, .{ .system = .{ .content = try std.mem.join(arena, joiner, instructions.items) } });
    for (items[leading..]) |item| try conversation.add(item);
    try conversation.flush();
    return conversation.messages.items;
}

/// Whether `item` is a developer or system message, which updates the instructions from where it stands.
fn isUpdate(item: Item) bool {
    return item == .input_message and item.input_message.role != .user;
}

/// The text of an update that joins the instructions, which take text alone.
fn instructionsText(call: *Call, message: vocabulary.items.InputMessage) Error![]const u8 {
    const parts = switch (message.content) {
        .text => |text| return text,
        .parts => |parts| parts,
    };
    var texts: std.ArrayList([]const u8) = .empty;
    for (parts) |part| {
        if (part != .input_text) return call.failWith(.invalid_request, "The instructions take text alone, and a {t} message that joins them holds an {t}", .{ message.role, part });
        try texts.append(call.arena, part.input_text.text);
    }
    return std.mem.join(call.arena, joiner, texts.items);
}

/// The fields of an assistant message, in the order they stand in it.
const Field = enum { reasoning_content, content, tool_calls };

/// An assistant message being gathered from the items a model wrote.
const Assistant = struct {
    reasoning: ?[]const u8 = null,
    text: ?[]const u8 = null,
    calls: std.ArrayList(ToolCall) = .empty,

    /// Whether an item for `field` begins another message: one for a field before a field it holds, or for the field
    /// it holds already but its calls.
    fn startsAnother(assistant: *const Assistant, field: Field) bool {
        const held = [_]struct { Field, bool }{ .{ .reasoning_content, assistant.reasoning != null }, .{ .content, assistant.text != null }, .{ .tool_calls, assistant.calls.items.len > 0 } };
        for (held) |each| {
            if (!each[1]) continue;
            if (@backingInt(each[0]) > @backingInt(field)) return true;
            if (each[0] == field and field != .tool_calls) return true;
        }
        return false;
    }
};

/// A user turn being gathered: its outputs, the files they held, its user messages and its updates.
const Turn = struct {
    tools: std.ArrayList(Message) = .empty,
    output_files: std.ArrayList(Part) = .empty,
    users: std.ArrayList(User) = .empty,
    updates: std.ArrayList(Part) = .empty,
};

/// Gathers the messages of a conversation one item at a time: each user turn and each run of the model's items.
const Conversation = struct {
    call: *Call,
    options: Options,
    messages: std.ArrayList(Message) = .empty,
    assistant: ?Assistant = null,
    turn: ?Turn = null,

    fn add(conversation: *Conversation, item: Item) Error!void {
        switch (item) {
            .input_message => |message| switch (message.role) {
                .user => try conversation.addUser(message.content),
                .developer, .system => try conversation.addUpdate(message.content),
            },
            .output_message => |message| try conversation.addAssistant(.content, try assistantText(conversation.call, message.content), null),
            .reasoning => |reasoning| try conversation.addAssistant(.reasoning_content, try reasoningText(conversation.call.arena, reasoning), null),
            .function_call => |given| try conversation.addAssistant(.tool_calls, "", .{ .id = given.call_id, .function = .{ .name = given.name, .arguments = given.arguments } }),
            .function_call_output => |output| try conversation.addOutput(output.call_id, output.output),
            else => return conversation.call.failWith(.invalid_request, "Chat Completions has no {t} item, and the request holds one", .{item}),
        }
    }

    /// Ends the conversation: the turn or the assistant message being gathered becomes its messages.
    fn flush(conversation: *Conversation) Error!void {
        try conversation.flushAssistant();
        try conversation.flushTurn();
    }

    /// Takes what the model wrote for `field` into the assistant message being gathered, or into a new one where it
    /// begins another.
    fn addAssistant(conversation: *Conversation, field: Field, text: []const u8, tool_call: ?ToolCall) Error!void {
        try conversation.flushTurn();
        if (conversation.assistant) |*open| if (open.startsAnother(field)) try conversation.flushAssistant();
        if (conversation.assistant == null) conversation.assistant = .{};
        const assistant = &conversation.assistant.?;
        switch (field) {
            .reasoning_content => assistant.reasoning = text,
            .content => assistant.text = text,
            .tool_calls => try assistant.calls.append(conversation.call.arena, tool_call.?),
        }
    }

    fn addUser(conversation: *Conversation, given: vocabulary.TextOr(InputContent)) Error!void {
        const turn = try conversation.openTurn();
        const made: vocabulary.TextOr(Part) = switch (given) {
            .text => |text| .{ .text = text },
            .parts => |parts| .{ .parts = try conversation.partsOf(parts) },
        };
        try turn.users.append(conversation.call.arena, .{ .content = made });
    }

    /// Takes an update: its text inside `<system-update>`, and any file it holds after it.
    fn addUpdate(conversation: *Conversation, given: vocabulary.TextOr(InputContent)) Error!void {
        const arena = conversation.call.arena;
        const turn = try conversation.openTurn();
        const parts: []const InputContent = switch (given) {
            .text => |text| try arena.dupe(InputContent, &.{.{ .input_text = .{ .text = text } }}),
            .parts => |parts| parts,
        };
        var texts: std.ArrayList([]const u8) = .empty;
        var others: std.ArrayList(InputContent) = .empty;
        for (parts) |part| switch (part) {
            .input_text => |text| try texts.append(arena, text.text),
            else => try others.append(arena, part),
        };
        try turn.updates.append(arena, .{ .text = .{ .text = try tags.systemUpdate(arena, try std.mem.join(arena, joiner, texts.items)) } });
        try turn.updates.appendSlice(arena, try conversation.partsOf(others.items));
    }

    /// Takes a function call's output: its text as a `tool` message, and its files for a user message after the
    /// outputs.
    fn addOutput(conversation: *Conversation, call_id: []const u8, output: vocabulary.TextOr(InputContent)) Error!void {
        const arena = conversation.call.arena;
        const turn = try conversation.openTurn();
        const parts = switch (output) {
            .text => |text| return turn.tools.append(arena, .{ .tool = .{ .tool_call_id = call_id, .content = text } }),
            .parts => |parts| try conversation.partsOf(parts),
        };
        var texts: std.ArrayList([]const u8) = .empty;
        for (parts) |part| switch (part) {
            .text => |text| try texts.append(arena, text.text),
            else => try turn.output_files.append(arena, part),
        };
        try turn.tools.append(arena, .{ .tool = .{ .tool_call_id = call_id, .content = try std.mem.join(arena, joiner, texts.items) } });
    }

    /// The user turn being gathered, begun where the model wrote last.
    fn openTurn(conversation: *Conversation) Error!*Turn {
        try conversation.flushAssistant();
        if (conversation.turn == null) conversation.turn = .{};
        return &conversation.turn.?;
    }

    fn flushAssistant(conversation: *Conversation) Allocator.Error!void {
        const assistant = conversation.assistant orelse return;
        conversation.assistant = null;
        try conversation.messages.append(conversation.call.arena, .{ .assistant = .{
            .content = assistant.text orelse "",
            .reasoning_content = assistant.reasoning,
            .tool_calls = if (assistant.calls.items.len == 0) null else assistant.calls.items,
        } });
    }

    /// The user turn gathered, as messages: its outputs as `tool` messages, which follow the calls they answer, then
    /// the files they held and its user messages, and its updates at the end of the last of them, so that an update
    /// stands past the user messages that follow it in the same turn.
    fn flushTurn(conversation: *Conversation) Allocator.Error!void {
        const turn = conversation.turn orelse return;
        conversation.turn = null;
        const arena = conversation.call.arena;
        var users: std.ArrayList(User) = .empty;
        if (turn.output_files.items.len > 0) try users.append(arena, .{ .content = .{ .parts = turn.output_files.items } });
        try users.appendSlice(arena, turn.users.items);
        if (turn.updates.items.len > 0) {
            var joined: std.ArrayList(Part) = .empty;
            if (users.pop()) |last| switch (last.content) {
                .text => |text| try joined.append(arena, .{ .text = .{ .text = text } }),
                .parts => |parts| try joined.appendSlice(arena, parts),
            };
            try joined.appendSlice(arena, turn.updates.items);
            try users.append(arena, .{ .content = .{ .parts = joined.items } });
        }
        try conversation.messages.appendSlice(arena, turn.tools.items);
        for (users.items) |user| try conversation.messages.append(arena, .{ .user = user });
    }

    fn partsOf(conversation: *Conversation, given: []const InputContent) Error![]const Part {
        const made = try conversation.call.arena.alloc(Part, given.len);
        for (given, made) |part, *each| each.* = try conversation.partOf(part);
        return made;
    }

    /// A part of input content as Chat Completions takes it; `Models` made each file inline a data URL of its type.
    fn partOf(conversation: *Conversation, part: InputContent) Error!Part {
        return switch (part) {
            .input_text => |text| .{ .text = .{ .text = text.text } },
            .input_image => |image| .{ .image_url = .{ .image_url = .{
                .url = image.image_url orelse "",
                .detail = if (conversation.options.image_detail and image.detail != .auto) image.detail else null,
            } } },
            .input_audio => |audio| .{ .input_audio = .{ .input_audio = .{ .data = audio.input_audio.data orelse "", .format = audio.input_audio.format } } },
            .input_video => |video| .{ .video_url = .{ .video_url = .{ .url = video.video_url orelse "" } } },
            .input_file => |file| conversation.filePart(file),
        };
    }

    /// A file as Chat Completions takes it: a text file's text inside `<file>`, another file as its data, or as its
    /// address where the provider fetches one. A file at an address is fetched where the provider takes no address, or
    /// where its type says it is text.
    fn filePart(conversation: *Conversation, given: content.InputFile) Error!Part {
        const call = conversation.call;
        const file: files.TypedFile = .{ .input_file = given };
        const name = files.name(file);
        if (if (given.file_data == null) given.file_url else null) |at| {
            const declared = try files.addressedType(call, file);
            const text = if (declared) |media_type| files.isText(media_type) else false;
            if (conversation.options.file_addresses and !text) return .{ .file = .{ .file = .{ .file_url = at, .filename = given.filename } } };
            const fetched = try files.fetchInput(call, file);
            if (files.isText(fetched.media_type)) return .{ .text = .{ .text = try tags.fileText(call.arena, fetched.data, name) } };
            const url = try std.fmt.allocPrint(call.arena, "data:{s};base64,{b64}", .{ fetched.media_type, fetched.data });
            return .{ .file = .{ .file = .{ .file_data = url, .filename = given.filename } } };
        }
        const media_type = try files.mediaType(call.arena, file, null);
        if (media_type != null and files.isText(media_type.?)) return .{ .text = .{ .text = try tags.fileText(call.arena, try inlineText(call.arena, file), name) } };
        return .{ .file = .{ .file = .{ .file_data = given.file_data orelse "", .filename = given.filename } } };
    }
};

/// A reasoning item's text, as its provider wrote it, else its summary's.
fn reasoningText(arena: Allocator, reasoning: vocabulary.items.ReasoningItem) Allocator.Error![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    if (reasoning.content) |parts| if (parts.len > 0) {
        for (parts) |part| try text.appendSlice(arena, part.text);
        return text.items;
    };
    for (reasoning.summary orelse &.{}) |part| try text.appendSlice(arena, part.text);
    return text.items;
}

/// An assistant message's text, which holds no image: Chat Completions takes none an assistant made.
fn assistantText(call: *Call, given: vocabulary.TextOr(vocabulary.OutputContent)) Error![]const u8 {
    const parts = switch (given) {
        .text => |text| return text,
        .parts => |parts| parts,
    };
    var text: std.ArrayList(u8) = .empty;
    for (parts) |part| switch (part) {
        .output_text => |written| try text.appendSlice(call.arena, written.text),
        .refusal => |refusal| try text.appendSlice(call.arena, refusal.refusal),
        .output_image => return call.failWith(.invalid_request, "Chat Completions takes no image an assistant made, and the request holds one", .{}),
    };
    return text.items;
}

/// The text a text file holds inline, from its data URL's base64 or its escaped data.
fn inlineText(arena: Allocator, file: files.TypedFile) Allocator.Error![]const u8 {
    if (files.inlineBase64(file)) |encoded| {
        const decoder = std.base64.standard.Decoder;
        const decoded = try arena.alloc(u8, decoder.calcSizeForSlice(encoded) catch return "");
        decoder.decode(decoded, encoded) catch return "";
        return decoded;
    }
    const data = file.input_file.file_data orelse "";
    const escaped = try arena.dupe(u8, data[(std.mem.indexOfScalar(u8, data, ',') orelse data.len -| 1) + 1 ..]);
    return std.Uri.percentDecodeInPlace(escaped);
}

/// A function as Chat Completions declares it.
pub const Function = struct {
    type: enum { function } = .function,
    function: struct { name: []const u8, description: ?[]const u8 = null, parameters: ?foundation.json.Raw = null, strict: ?bool = null },
};

/// The request's functions as Chat Completions' tools, which are functions alone; null for none.
pub fn tools(call: *Call, request: *const Request) Error!?[]const Function {
    const declared = request.tools orelse return null;
    if (declared.len == 0) return null;
    const made = try call.arena.alloc(Function, declared.len);
    for (declared, made) |tool, *each| {
        if (tool != .function) {
            const kind = switch (tool) {
                inline else => |given| @tagName(given.type),
            };
            return call.failWith(.invalid_request, "Chat Completions takes functions alone as tools, and the request declares a {s} tool", .{kind});
        }
        const function = tool.function;
        each.* = .{ .function = .{ .name = function.name, .description = function.description, .parameters = function.parameters, .strict = function.strict } };
    }
    return made;
}

/// A tool choice as Chat Completions names it.
pub const ToolChoice = union(enum) {
    mode: @FieldType(vocabulary.ToolChoice, "mode"),
    function: struct { type: enum { function } = .function, function: struct { name: []const u8 } },
    allowed_tools: struct { type: enum { allowed_tools } = .allowed_tools, allowed_tools: struct { mode: @FieldType(vocabulary.tools.AllowedToolsChoice, "mode"), tools: []const AllowedTool } },

    pub fn jsonStringify(choice: ToolChoice, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (choice) {
            inline else => |payload| try writer.write(payload),
        }
    }
};

/// A tool an `allowed_tools` choice names: a function by its name, or another as the request names it.
const AllowedTool = union(enum) {
    function: struct { type: enum { function } = .function, function: struct { name: []const u8 } },
    other: foundation.json.Raw,

    pub fn jsonStringify(tool: AllowedTool, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (tool) {
            inline else => |payload| try writer.write(payload),
        }
    }
};

pub fn toolChoice(arena: Allocator, choice: vocabulary.ToolChoice) Allocator.Error!ToolChoice {
    return switch (choice) {
        .mode => |mode| .{ .mode = mode },
        .function => |function| .{ .function = .{ .function = .{ .name = function.name } } },
        .allowed_tools => |allowed| {
            const made = try arena.alloc(AllowedTool, allowed.tools.len);
            for (allowed.tools, made) |tool, *each| {
                const named = foundation.json.decode(struct { type: enum { function }, name: []const u8 }, arena, tool.text) catch {
                    each.* = .{ .other = tool };
                    continue;
                };
                each.* = .{ .function = .{ .function = .{ .name = named.name } } };
            }
            return .{ .allowed_tools = .{ .allowed_tools = .{ .mode = allowed.mode, .tools = made } } };
        },
    };
}

/// A response format as Chat Completions names it.
pub const ResponseFormat = union(enum) {
    json_object: struct { type: enum { json_object } = .json_object },
    json_schema: struct {
        type: enum { json_schema } = .json_schema,
        json_schema: struct { name: []const u8, description: ?[]const u8 = null, schema: foundation.json.Raw, strict: ?bool = null },
    },

    pub fn jsonStringify(format: ResponseFormat, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (format) {
            inline else => |payload| try writer.write(payload),
        }
    }
};

/// The response format the request's text format asks for; null for free text.
pub fn responseFormat(request: *const Request) ?ResponseFormat {
    const text = request.text orelse return null;
    const format = text.format orelse return null;
    return switch (format) {
        .text => null,
        .json_object => .{ .json_object = .{} },
        .json_schema => |schema| .{ .json_schema = .{ .json_schema = .{ .name = schema.name, .description = schema.description, .schema = schema.schema, .strict = schema.strict } } },
    };
}
