//! Chat Completions' stream as the vocabulary's events. Its chunks' deltas become output items as they come:
//! reasoning, read from `reasoning_content` or `reasoning`; a message of text and refusal; and a function call for
//! each tool call, whose `call_id` is `call_` and a new UUID, as servers give the calls of every response the same
//! ids. Its finish reason ends the response with the usage of its last chunks; a stream that ends without one is no
//! whole response, for the text stream to fail.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const Event = vocabulary.ResponseStreamEvent;
const OutputItem = vocabulary.OutputItem;
const content = vocabulary.content;
const failure_ = @import("../../failure.zig");
const Error = failure_.Error;
const Call = @import("../../driver.zig").Call;

/// A tool call's fragment in a chunk's delta.
const ToolCallDelta = struct {
    index: ?u32 = null,
    function: ?struct {
        name: ?[]const u8 = null,
        /// Text, or an object where a server writes the arguments whole.
        arguments: ?std.json.Value = null,
    } = null,
};

const TopLogprob = struct { token: []const u8, logprob: f64, bytes: ?[]const u16 = null };

const ChatLogprob = struct { token: []const u8, logprob: f64, bytes: ?[]const u16 = null, top_logprobs: ?[]const TopLogprob = null };

/// One choice of a chunk: its delta and, at its end, why it finished.
const Choice = struct {
    index: ?u32 = null,
    delta: ?struct {
        content: ?[]const u8 = null,
        reasoning_content: ?[]const u8 = null,
        reasoning: ?[]const u8 = null,
        refusal: ?[]const u8 = null,
        tool_calls: ?[]const ToolCallDelta = null,
    } = null,
    logprobs: ?struct { content: ?[]const ChatLogprob = null } = null,
    finish_reason: ?[]const u8 = null,
};

/// What a request used, as Chat Completions counts it.
const ChatUsage = struct {
    prompt_tokens: u64,
    completion_tokens: u64,
    total_tokens: ?u64 = null,
    prompt_tokens_details: ?struct { cached_tokens: ?u64 = null } = null,
    completion_tokens_details: ?struct { reasoning_tokens: ?u64 = null } = null,

    fn usage(given: ChatUsage) vocabulary.response.ResponseUsage {
        const cached = if (given.prompt_tokens_details) |details| details.cached_tokens else null;
        const reasoning = if (given.completion_tokens_details) |details| details.reasoning_tokens else null;
        return .{
            .input_tokens = given.prompt_tokens,
            .input_tokens_details = .{ .cached_tokens = cached orelse 0 },
            .output_tokens = given.completion_tokens,
            .output_tokens_details = .{ .reasoning_tokens = reasoning orelse 0 },
            .total_tokens = given.total_tokens orelse given.prompt_tokens + given.completion_tokens,
        };
    }
};

/// A chunk of the stream: its choices' deltas, its usage, or an error.
const Chunk = struct {
    id: ?[]const u8 = null,
    choices: ?[]const Choice = null,
    usage: ?ChatUsage = null,
    @"error": ?std.json.Value = null,
};

/// How a finish reason ends a response.
pub const Ending = union(enum) {
    completed,
    incomplete: @FieldType(vocabulary.response.IncompleteDetails, "reason"),
    failed: vocabulary.extensions.FailureExtension,
};

/// A finish reason and how it ends a response.
pub const NamedEnding = struct { []const u8, Ending };

/// What Chat Completions' own finish reasons mean.
const chat_endings = [_]NamedEnding{
    .{ "stop", .completed },
    .{ "tool_calls", .completed },
    .{ "function_call", .completed },
    .{ "length", .{ .incomplete = .max_output_tokens } },
    .{ "content_filter", .{ .incomplete = .content_filter } },
};

/// The failure an error a provider's stream carried stands for: its kind, its code and its message.
pub const StreamFailure = struct { octoii: vocabulary.extensions.FailureExtension, code: []const u8, message: []const u8 };

/// Reads the failure an error in the stream stands for, in `arena`.
pub const StreamFailureOf = *const fn (arena: Allocator, given: std.json.Value) Allocator.Error!StreamFailure;

const PartKind = enum { output_text, refusal, reasoning_text };

/// A part of a text item, its text growing.
const TextPart = struct {
    kind: PartKind,
    text: std.ArrayList(u8) = .empty,
    logprobs: std.ArrayList(content.Logprob) = .empty,
};

/// A text item being streamed: reasoning, or a message of text and refusal parts.
const TextItem = struct {
    kind: enum { reasoning, message },
    id: []const u8,
    output_index: u32,
    parts: std.ArrayList(TextPart) = .empty,
};

/// A function call being streamed; added once it has a name.
const CallItem = struct {
    id: []const u8,
    call_id: []const u8,
    output_index: ?u32 = null,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
};

pub const Translator = struct {
    call: *Call,
    /// The provider's own finish reasons, looked up before Chat Completions' own.
    endings: []const NamedEnding,
    stream_failure: StreamFailureOf,
    output: std.ArrayList(OutputItem) = .empty,
    text: ?*TextItem = null,
    calls: std.AutoArrayHashMapUnmanaged(u32, *CallItem) = .empty,
    id: ?[]const u8 = null,
    usage: ?vocabulary.response.ResponseUsage = null,
    finish_reason: ?[]const u8 = null,

    /// The events one chunk's data stands for, onto `out`.
    pub fn chunk(translator: *Translator, data: []const u8, out: *std.ArrayList(Event)) Error!void {
        const call = translator.call;
        const given = foundation.json.decode(Chunk, call.arena, data) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                var failure = try failure_.Failure.format(call.arena, .invalid_response, "The provider's stream chunk is not as expected: {t}", .{err});
                failure.body = data;
                return call.fail(failure);
            },
        };
        if (translator.id == null) {
            translator.id = given.id orelse try call.host.newId(call.arena);
            try translator.emit(out, .{ .created = .{ .response = try translator.response(.in_progress), .sequence_number = 0 } });
        }
        if (given.@"error") |raised| if (raised != .null) return translator.failed(try translator.stream_failure(call.arena, raised), out);
        if (given.usage) |usage| translator.usage = usage.usage();
        for (given.choices orelse &.{}) |each| if ((each.index orelse 0) == 0) return translator.choice(each, out);
    }

    /// The events that end the response once the stream has ended: every item done and the response ended as its
    /// finish reason says. A stream that gave none ends here unfinished.
    pub fn end(translator: *Translator, out: *std.ArrayList(Event)) Error!void {
        const reason = translator.finish_reason orelse return;
        const ending = endingOf(translator.endings, reason) orelse
            return translator.call.failWith(.invalid_response, "The provider finished for a reason ai does not know: {s}", .{reason});
        switch (ending) {
            .failed => |failure| return translator.failed(.{
                .octoii = failure,
                .code = reason,
                .message = try std.fmt.allocPrint(translator.call.arena, "The provider's response broke off: {s}", .{reason}),
            }, out),
            .completed => {
                try translator.endText(.completed, out);
                try translator.endCalls(.completed, out);
                try translator.emit(out, .{ .completed = .{ .response = try translator.response(.completed), .sequence_number = 0 } });
            },
            .incomplete => |why| {
                try translator.endText(.incomplete, out);
                try translator.endCalls(.incomplete, out);
                var ended = try translator.response(.incomplete);
                ended.incomplete_details = .{ .reason = why };
                try translator.emit(out, .{ .incomplete = .{ .response = ended, .sequence_number = 0 } });
            },
        }
    }

    fn choice(translator: *Translator, given: Choice, out: *std.ArrayList(Event)) Error!void {
        if (given.delta) |delta| {
            if (delta.reasoning_content orelse delta.reasoning) |reasoning| try translator.textDelta(.reasoning, .reasoning_text, reasoning, &.{}, out);
            if (delta.refusal) |refusal| try translator.textDelta(.message, .refusal, refusal, &.{}, out);
            if (delta.content) |text| try translator.textDelta(.message, .output_text, text, try logprobsOf(translator.call.arena, given), out);
            for (delta.tool_calls orelse &.{}, 0..) |fragment, position| try translator.callDelta(fragment, @intCast(position), out);
        }
        if (given.finish_reason) |reason| translator.finish_reason = reason;
    }

    /// More text of an item of `kind`: the item and its part begun where they are not open.
    fn textDelta(translator: *Translator, kind: @FieldType(TextItem, "kind"), part_kind: PartKind, delta: []const u8, logprobs: []const content.Logprob, out: *std.ArrayList(Event)) Error!void {
        if (delta.len == 0) return;
        const arena = translator.call.arena;
        if (translator.text == null or translator.text.?.kind != kind) {
            try translator.endText(.completed, out);
            try translator.beginText(kind, out);
        }
        const item = translator.text.?;
        const open = if (item.parts.items.len == 0) null else &item.parts.items[item.parts.items.len - 1];
        if (open == null or open.?.kind != part_kind) {
            if (open != null) try translator.endPart(item, @intCast(item.parts.items.len - 1), out);
            try item.parts.append(arena, .{ .kind = part_kind });
            try translator.emit(out, .{ .content_part_added = .{ .item_id = item.id, .output_index = item.output_index, .content_index = @intCast(item.parts.items.len - 1), .part = emptyPart(part_kind), .sequence_number = 0 } });
        }
        const index: u32 = @intCast(item.parts.items.len - 1);
        const part = &item.parts.items[index];
        try part.text.appendSlice(arena, delta);
        try part.logprobs.appendSlice(arena, logprobs);
        try translator.emit(out, switch (part_kind) {
            .output_text => .{ .output_text_delta = .{ .item_id = item.id, .output_index = item.output_index, .content_index = index, .delta = delta, .logprobs = try streamLogprobs(arena, logprobs), .sequence_number = 0 } },
            .refusal => .{ .refusal_delta = .{ .item_id = item.id, .output_index = item.output_index, .content_index = index, .delta = delta, .sequence_number = 0 } },
            .reasoning_text => .{ .reasoning_text_delta = .{ .item_id = item.id, .output_index = item.output_index, .content_index = index, .delta = delta, .sequence_number = 0 } },
        });
    }

    fn beginText(translator: *Translator, kind: @FieldType(TextItem, "kind"), out: *std.ArrayList(Event)) Error!void {
        const arena = translator.call.arena;
        const item = try arena.create(TextItem);
        item.* = .{ .kind = kind, .id = try translator.call.host.newId(arena), .output_index = @intCast(translator.output.items.len) };
        translator.text = item;
        const added = try textItem(arena, item, .in_progress);
        try translator.output.append(arena, added);
        try translator.emit(out, .{ .output_item_added = .{ .output_index = item.output_index, .item = added, .sequence_number = 0 } });
    }

    /// The open text item ended with `status`, its last part done.
    fn endText(translator: *Translator, status: vocabulary.items.ItemStatus, out: *std.ArrayList(Event)) Error!void {
        const item = translator.text orelse return;
        translator.text = null;
        if (item.parts.items.len > 0) try translator.endPart(item, @intCast(item.parts.items.len - 1), out);
        const done = try textItem(translator.call.arena, item, status);
        translator.output.items[item.output_index] = done;
        try translator.emit(out, .{ .output_item_done = .{ .output_index = item.output_index, .item = done, .sequence_number = 0 } });
    }

    fn endPart(translator: *Translator, item: *const TextItem, index: u32, out: *std.ArrayList(Event)) Error!void {
        const part = &item.parts.items[index];
        const text = part.text.items;
        try translator.emit(out, switch (part.kind) {
            .output_text => .{ .output_text_done = .{ .item_id = item.id, .output_index = item.output_index, .content_index = index, .text = text, .logprobs = try streamLogprobs(translator.call.arena, part.logprobs.items), .sequence_number = 0 } },
            .refusal => .{ .refusal_done = .{ .item_id = item.id, .output_index = item.output_index, .content_index = index, .refusal = text, .sequence_number = 0 } },
            .reasoning_text => .{ .reasoning_text_done = .{ .item_id = item.id, .output_index = item.output_index, .content_index = index, .text = text, .sequence_number = 0 } },
        });
        try translator.emit(out, .{ .content_part_done = .{ .item_id = item.id, .output_index = item.output_index, .content_index = index, .part = donePart(part), .sequence_number = 0 } });
    }

    /// A tool call's fragment: its call added once it has a name, and its arguments streamed.
    fn callDelta(translator: *Translator, fragment: ToolCallDelta, position: u32, out: *std.ArrayList(Event)) Error!void {
        const arena = translator.call.arena;
        const index = fragment.index orelse position;
        const slot = try translator.calls.getOrPut(arena, index);
        if (!slot.found_existing) {
            slot.value_ptr.* = try arena.create(CallItem);
            slot.value_ptr.*.* = .{ .id = try translator.call.host.newId(arena), .call_id = try translator.call.host.newId(arena) };
        }
        const item = slot.value_ptr.*;
        const function = fragment.function orelse return;
        try item.name.appendSlice(arena, function.name orelse "");
        const more = try argumentsText(arena, function.arguments);
        if (item.output_index) |output_index| {
            if (more.len == 0) return;
            try item.arguments.appendSlice(arena, more);
            return translator.emit(out, .{ .function_call_arguments_delta = .{ .item_id = item.id, .output_index = output_index, .delta = more, .sequence_number = 0 } });
        }
        try item.arguments.appendSlice(arena, more);
        if (item.name.items.len == 0) return;
        try translator.endText(.completed, out);
        const output_index: u32 = @intCast(translator.output.items.len);
        item.output_index = output_index;
        const added = callItem(item, .in_progress, "");
        try translator.output.append(arena, added);
        try translator.emit(out, .{ .output_item_added = .{ .output_index = output_index, .item = added, .sequence_number = 0 } });
        if (item.arguments.items.len > 0) {
            try translator.emit(out, .{ .function_call_arguments_delta = .{ .item_id = item.id, .output_index = output_index, .delta = try arena.dupe(u8, item.arguments.items), .sequence_number = 0 } });
        }
    }

    /// Every call added ended with `status`, its arguments done, in the order they were added.
    fn endCalls(translator: *Translator, status: vocabulary.items.ItemStatus, out: *std.ArrayList(Event)) Error!void {
        var added: std.ArrayList(*CallItem) = .empty;
        for (translator.calls.values()) |item| if (item.output_index != null) try added.append(translator.call.arena, item);
        translator.calls.clearRetainingCapacity();
        std.mem.sort(*CallItem, added.items, {}, struct {
            fn less(_: void, a: *CallItem, b: *CallItem) bool {
                return a.output_index.? < b.output_index.?;
            }
        }.less);
        for (added.items) |item| {
            const output_index = item.output_index.?;
            try translator.emit(out, .{ .function_call_arguments_done = .{ .item_id = item.id, .output_index = output_index, .name = item.name.items, .arguments = item.arguments.items, .sequence_number = 0 } });
            const done = callItem(item, status, item.arguments.items);
            translator.output.items[output_index] = done;
            try translator.emit(out, .{ .output_item_done = .{ .output_index = output_index, .item = done, .sequence_number = 0 } });
        }
    }

    /// The response failed: an `error`, then the failed response with what came, whose open items the text stream
    /// ends.
    fn failed(translator: *Translator, failure: StreamFailure, out: *std.ArrayList(Event)) Error!void {
        translator.finish_reason = null;
        try translator.emit(out, .{ .@"error" = .{ .code = failure.code, .message = failure.message, .octoii = failure.octoii, .sequence_number = 0 } });
        var ended = try translator.response(.failed);
        ended.@"error" = .{ .code = failure.code, .message = failure.message, .octoii = failure.octoii };
        try translator.emit(out, .{ .failed = .{ .response = ended, .sequence_number = 0 } });
    }

    fn response(translator: *Translator, status: vocabulary.response.ResponseStatus) Allocator.Error!vocabulary.Response {
        return .{
            .id = translator.id orelse "",
            .status = status,
            .output = try translator.call.arena.dupe(OutputItem, translator.output.items),
            .usage = translator.usage,
            .octoii = if (translator.usage) |usage| .{ .context_tokens = usage.input_tokens } else null,
        };
    }

    fn emit(translator: *Translator, out: *std.ArrayList(Event), event: Event) Allocator.Error!void {
        try out.append(translator.call.arena, event);
    }
};

fn endingOf(own: []const NamedEnding, reason: []const u8) ?Ending {
    for (own) |each| if (std.mem.eql(u8, each[0], reason)) return each[1];
    for (chat_endings) |each| if (std.mem.eql(u8, each[0], reason)) return each[1];
    return null;
}

/// A text item as it stands, with `status`.
fn textItem(arena: Allocator, item: *const TextItem, status: vocabulary.items.ItemStatus) Allocator.Error!OutputItem {
    switch (item.kind) {
        .reasoning => {
            const parts = try arena.alloc(content.ReasoningText, item.parts.items.len);
            for (item.parts.items, parts) |part, *each| each.* = .{ .text = part.text.items };
            return .{ .reasoning = .{ .id = item.id, .summary = &.{}, .content = parts, .status = status } };
        },
        .message => {
            const parts = try arena.alloc(vocabulary.OutputContent, item.parts.items.len);
            for (item.parts.items, parts) |*part, *each| each.* = switch (part.kind) {
                .refusal => .{ .refusal = .{ .refusal = part.text.items } },
                else => .{ .output_text = outputText(part) },
            };
            return .{ .output_message = .{ .type = .message, .id = item.id, .status = status, .content = .{ .parts = parts } } };
        },
    }
}

/// A text part as it ends, with its log probabilities where it has them.
fn outputText(part: *const TextPart) content.OutputText {
    return .{ .text = part.text.items, .annotations = &.{}, .logprobs = if (part.logprobs.items.len == 0) null else part.logprobs.items };
}

fn emptyPart(kind: PartKind) vocabulary.events.ContentPart {
    return switch (kind) {
        .output_text => .{ .output_text = .{ .text = "", .annotations = &.{} } },
        .refusal => .{ .refusal = .{ .refusal = "" } },
        .reasoning_text => .{ .reasoning_text = .{ .text = "" } },
    };
}

fn donePart(part: *const TextPart) vocabulary.events.ContentPart {
    return switch (part.kind) {
        .output_text => .{ .output_text = outputText(part) },
        .refusal => .{ .refusal = .{ .refusal = part.text.items } },
        .reasoning_text => .{ .reasoning_text = .{ .text = part.text.items } },
    };
}

/// A function call as it stands, with `status` and `arguments`.
fn callItem(item: *const CallItem, status: vocabulary.items.ItemStatus, arguments: []const u8) OutputItem {
    return .{ .function_call = .{ .id = item.id, .call_id = item.call_id, .name = item.name.items, .arguments = arguments, .status = status } };
}

/// A fragment of a call's arguments as text: an object a server wrote whole as its JSON.
fn argumentsText(arena: Allocator, given: ?std.json.Value) Allocator.Error![]const u8 {
    const fragment = given orelse return "";
    return switch (fragment) {
        .null => "",
        .string => |text| text,
        else => foundation.json.encode(arena, fragment),
    };
}

/// The log probabilities of a choice's text, bytes and alternatives empty where it gave none.
fn logprobsOf(arena: Allocator, given: Choice) Allocator.Error![]const content.Logprob {
    const logprobs = given.logprobs orelse return &.{};
    const entries = logprobs.content orelse return &.{};
    const made = try arena.alloc(content.Logprob, entries.len);
    for (entries, made) |entry, *each| {
        const tops = entry.top_logprobs orelse &.{};
        const top = try arena.alloc(content.TopLogprob, tops.len);
        for (tops, top) |alternative, *one| one.* = .{ .token = alternative.token, .logprob = alternative.logprob, .bytes = alternative.bytes orelse &.{} };
        each.* = .{ .token = entry.token, .logprob = entry.logprob, .bytes = entry.bytes orelse &.{}, .top_logprobs = top };
    }
    return made;
}

/// Log probabilities as a stream's events give them.
fn streamLogprobs(arena: Allocator, given: []const content.Logprob) Allocator.Error![]const vocabulary.events.StreamLogprob {
    const made = try arena.alloc(vocabulary.events.StreamLogprob, given.len);
    for (given, made) |entry, *each| {
        const top = try arena.alloc(vocabulary.events.StreamTopLogprob, entry.top_logprobs.len);
        for (entry.top_logprobs, top) |alternative, *one| one.* = .{ .token = alternative.token, .logprob = alternative.logprob, .bytes = alternative.bytes };
        each.* = .{ .token = entry.token, .logprob = entry.logprob, .bytes = entry.bytes, .top_logprobs = top };
    }
    return made;
}
