//! Anthropic's stream as the vocabulary's events. Its content blocks become output items: text blocks one message,
//! citations its annotations; each thinking block a reasoning item; each `tool_use` a function call; each search with
//! its results a web search call, or a tool search's call and output. An item keeps the blocks it came as where the
//! model needs them back. A paused answer's pieces make one response: its items go on, its usage adds up, and the
//! blocks so far are ready to send back so that the model goes on from them.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const Event = vocabulary.ResponseStreamEvent;
const OutputItem = vocabulary.OutputItem;
const failure_ = @import("../../failure.zig");
const Error = failure_.Error;
const Call = @import("../../driver.zig").Call;
const wire = @import("wire.zig");

/// The format of Anthropic's reasoning.
const reasoning_format: vocabulary.items.ReasoningFormat = .@"anthropic-claude-v1";

/// What a request used, as Anthropic counts it.
const Counts = struct {
    input: u64 = 0,
    output: u64 = 0,
    written: u64 = 0,
    read: u64 = 0,
    written_long: u64 = 0,
    searches: u64 = 0,

    /// The counts with what `usage` says in their place, as each event gives the counts that changed.
    fn with(counts: Counts, given: wire.Usage) Counts {
        return .{
            .input = given.input_tokens orelse counts.input,
            .output = given.output_tokens orelse counts.output,
            .written = given.cache_creation_input_tokens orelse counts.written,
            .read = given.cache_read_input_tokens orelse counts.read,
            .written_long = (if (given.cache_creation) |creation| creation.ephemeral_1h_input_tokens else null) orelse counts.written_long,
            .searches = (if (given.server_tool_use) |used| used.web_search_requests else null) orelse counts.searches,
        };
    }

    fn plus(a: Counts, b: Counts) Counts {
        return .{ .input = a.input + b.input, .output = a.output + b.output, .written = a.written + b.written, .read = a.read + b.read, .written_long = a.written_long + b.written_long, .searches = a.searches + b.searches };
    }

    /// The tokens of a request's input, those read from the cache and written to it among them.
    fn inputTokens(counts: Counts) u64 {
        return counts.input + counts.written + counts.read;
    }

    /// The counts as the vocabulary's usage.
    fn usage(counts: Counts) vocabulary.response.ResponseUsage {
        const input = counts.inputTokens();
        return .{
            .input_tokens = input,
            .input_tokens_details = .{ .cached_tokens = counts.read, .cache_write_tokens = counts.written },
            .output_tokens = counts.output,
            // Anthropic counts no reasoning tokens apart from the others it writes.
            .output_tokens_details = .{ .reasoning_tokens = 0 },
            .total_tokens = input + counts.output,
            .server_tool_use_details = if (counts.searches == 0) null else .{ .web_search_requests = counts.searches },
            .octoii = if (counts.written_long == 0) null else .{ .cache_write_long_tokens = counts.written_long },
        };
    }
};

/// A block of the piece under way: the JSON it came as, kept to send back, and what it makes.
const Block = struct {
    raw: *Value,
    kind: union(enum) {
        text: struct { start: u32 },
        thinking: struct { output_index: u32 },
        redacted: struct { output_index: u32 },
        call: struct { output_index: u32 },
        search: struct { output_index: u32, call_id: []const u8 },
        tool_search: struct { output_index: u32, call_id: []const u8 },
        result,
    },
    /// The text, thinking, signature or input it has streamed so far.
    text: std.ArrayList(u8) = .empty,
    signature: std.ArrayList(u8) = .empty,
};

/// The message the text blocks make, open while they come one after another.
const Message = struct {
    output_index: u32,
    id: []const u8,
    text: std.ArrayList(u8) = .empty,
    annotations: std.ArrayList(vocabulary.content.Annotation) = .empty,
    blocks: std.ArrayList(*Value) = .empty,
    cited: bool = false,
};

/// A web search that awaits its results.
const PendingSearch = struct { output_index: u32, raw: *Value, query: []const u8 };

/// How a piece of the answer ended: not yet, paused for the model to go on, or whole.
pub const Ending = enum { open, paused, ended };

pub const Translator = struct {
    call: *Call,
    /// The functions the request declares, by name, which a tool search's references name.
    tools: std.StringHashMapUnmanaged(vocabulary.Tool) = .empty,
    output: std.ArrayList(OutputItem) = .empty,
    blocks: std.AutoHashMapUnmanaged(u32, *Block) = .empty,
    searches: std.StringHashMapUnmanaged(PendingSearch) = .empty,
    /// Every block of the response so far, as it came, which a paused answer sends back.
    sent: std.ArrayList(*Value) = .empty,
    total: Counts = .{},
    piece: Counts = .{},
    message: ?*Message = null,
    response_id: ?[]const u8 = null,
    stop_reason: ?[]const u8 = null,
    context_tokens: u64 = 0,
    ending: Ending = .open,

    pub fn init(call: *Call, request: *const vocabulary.ResponsesRequest) Allocator.Error!Translator {
        var translator: Translator = .{ .call = call };
        for (request.tools orelse &.{}) |tool| if (tool == .function) try translator.tools.put(call.arena, tool.function.name, tool);
        for (@import("../../text/check.zig").inputItems(request)) |item| if (item == .additional_tools) for (item.additional_tools.tools) |tool| {
            if (tool == .function) try translator.tools.put(call.arena, tool.function.name, tool);
        };
        return translator;
    }

    /// Begins the next piece of a paused answer.
    pub fn nextPiece(translator: *Translator) void {
        translator.ending = .open;
        translator.stop_reason = null;
        translator.piece = .{};
        translator.blocks.clearRetainingCapacity();
    }

    /// The vocabulary's events one event of Anthropic's stands for, onto `out`.
    pub fn translate(translator: *Translator, data: []const u8, out: *std.ArrayList(Event)) Error!void {
        const call = translator.call;
        const value = try @import("../../wire/json.zig").parseObject(call, data);
        const kind = value.object.get("type").?.string;
        const known = for (wire.known_events) |each| {
            if (std.mem.eql(u8, each, kind)) break true;
        } else false;
        if (!known) return;
        const event = foundation.json.decodeValue(wire.Event, call.arena, value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return translator.invalid("an event that is not as Anthropic's stream defines it", .{}),
        };
        switch (event) {
            .message_start => |start| try translator.started(start.message.id, start.message.usage, out),
            .content_block_start => |start| try translator.blockStarted(start.index, start.content_block, out),
            .content_block_delta => |change| try translator.blockChanged(change.index, change.delta, out),
            .content_block_stop => |stop| try translator.blockStopped(stop.index, out),
            .message_delta => |delta| {
                if (delta.delta.stop_reason) |reason| translator.stop_reason = reason;
                if (delta.usage) |usage| translator.piece = translator.piece.with(usage);
            },
            .message_stop => try translator.stopped(out),
            .ping => {},
            .@"error" => |given| try translator.failed(given.@"error", out),
        }
    }

    fn invalid(translator: *Translator, comptime what: []const u8, arguments: anytype) Error {
        return translator.call.failWith(.invalid_response, "The provider sent " ++ what, arguments);
    }

    fn emit(translator: *Translator, out: *std.ArrayList(Event), event: Event) Allocator.Error!void {
        try out.append(translator.call.arena, event);
    }

    fn started(translator: *Translator, id: []const u8, usage: ?wire.Usage, out: *std.ArrayList(Event)) Error!void {
        translator.piece = (Counts{}).with(usage orelse .{});
        if (translator.response_id != null) return;
        translator.response_id = id;
        try translator.emit(out, .{ .created = .{ .response = try translator.response(.in_progress, null), .sequence_number = 0 } });
    }

    fn blockStarted(translator: *Translator, index: u32, given: Value, out: *std.ArrayList(Event)) Error!void {
        const arena = translator.call.arena;
        if (given != .object) return translator.invalid("a content block that is no object", .{});
        const raw = try arena.create(Value);
        raw.* = given;
        try translator.sent.append(arena, raw);
        const kind = (given.object.get("type") orelse return translator.invalid("a content block without its type", .{})).string;
        if (!std.mem.eql(u8, kind, "text")) try translator.closeMessage(.completed, out);
        if (std.mem.eql(u8, kind, "text")) return translator.textStarted(index, raw, out);
        if (std.mem.eql(u8, kind, "thinking") or std.mem.eql(u8, kind, "redacted_thinking")) return translator.reasoningStarted(index, raw, out);
        if (std.mem.eql(u8, kind, "tool_use")) return translator.callStarted(index, raw, out);
        if (std.mem.eql(u8, kind, "server_tool_use")) return translator.serverCallStarted(index, raw, out);
        if (std.mem.eql(u8, kind, "web_search_tool_result")) return translator.searchFound(index, raw, out);
        if (std.mem.eql(u8, kind, "tool_search_tool_result")) return translator.toolsFound(index, raw, out);
        return translator.invalid("a content block of the type {s}, which ai does not know", .{kind});
    }

    fn newBlock(translator: *Translator, index: u32, block: Block) Allocator.Error!*Block {
        const made = try translator.call.arena.create(Block);
        made.* = block;
        try translator.blocks.put(translator.call.arena, index, made);
        return made;
    }

    fn textStarted(translator: *Translator, index: u32, raw: *Value, out: *std.ArrayList(Event)) Error!void {
        const arena = translator.call.arena;
        const given = textOf(raw.*, "text") orelse return translator.invalid("a text block without its text", .{});
        if (translator.message == null) {
            const output_index: u32 = @intCast(translator.output.items.len);
            const message = try arena.create(Message);
            message.* = .{ .output_index = output_index, .id = try arena.print("msg_{s}_{d}", .{ translator.response_id orelse "", output_index }) };
            translator.message = message;
            const item: OutputItem = .{ .output_message = .{ .type = .message, .id = message.id, .status = .in_progress, .content = .{ .parts = &.{} } } };
            try translator.output.append(arena, item);
            try translator.emit(out, .{ .output_item_added = .{ .item = item, .output_index = output_index, .sequence_number = 0 } });
            try translator.emit(out, .{ .content_part_added = .{ .item_id = message.id, .output_index = output_index, .sequence_number = 0, .content_index = 0, .part = .{ .output_text = .{ .text = "", .annotations = &.{} } } } });
        }
        const message = translator.message.?;
        try message.blocks.append(arena, raw);
        const block = try translator.newBlock(index, .{ .raw = raw, .kind = .{ .text = .{ .start = utf16Length(message.text.items) } } });
        try translator.textAdded(block, given, out);
    }

    /// More text of the open message, from `block`.
    fn textAdded(translator: *Translator, block: *Block, given: []const u8, out: *std.ArrayList(Event)) Error!void {
        const message = translator.message orelse return;
        if (given.len == 0) return;
        const arena = translator.call.arena;
        try block.text.appendSlice(arena, given);
        try message.text.appendSlice(arena, given);
        try translator.emit(out, .{ .output_text_delta = .{ .item_id = message.id, .output_index = message.output_index, .sequence_number = 0, .content_index = 0, .delta = given, .logprobs = &.{} } });
    }

    fn reasoningStarted(translator: *Translator, index: u32, raw: *Value, out: *std.ArrayList(Event)) Error!void {
        const arena = translator.call.arena;
        const output_index: u32 = @intCast(translator.output.items.len);
        const id = try arena.print("rs_{s}_{d}", .{ translator.response_id orelse "", output_index });
        if (textOf(raw.*, "data")) |data| {
            const item: OutputItem = .{ .reasoning = .{ .id = id, .summary = &.{}, .encrypted_content = data, .format = reasoning_format, .status = .in_progress } };
            try translator.output.append(arena, item);
            _ = try translator.newBlock(index, .{ .raw = raw, .kind = .{ .redacted = .{ .output_index = output_index } } });
            return translator.emit(out, .{ .output_item_added = .{ .item = item, .output_index = output_index, .sequence_number = 0 } });
        }
        const thinking = textOf(raw.*, "thinking") orelse return translator.invalid("a thinking block without its text", .{});
        const item: OutputItem = .{ .reasoning = .{ .id = id, .summary = &.{}, .format = reasoning_format, .status = .in_progress } };
        try translator.output.append(arena, item);
        const block = try translator.newBlock(index, .{ .raw = raw, .kind = .{ .thinking = .{ .output_index = output_index } } });
        try block.signature.appendSlice(arena, textOf(raw.*, "signature") orelse "");
        try translator.emit(out, .{ .output_item_added = .{ .item = item, .output_index = output_index, .sequence_number = 0 } });
        try translator.thought(block, thinking, out);
    }

    /// More of a thinking block's text, its summary begun with the first of it.
    fn thought(translator: *Translator, block: *Block, given: []const u8, out: *std.ArrayList(Event)) Error!void {
        if (given.len == 0) return;
        const output_index = block.kind.thinking.output_index;
        const id = translator.output.items[output_index].reasoning.id;
        if (block.text.items.len == 0) {
            try translator.emit(out, .{ .summary_part_added = .{ .item_id = id, .output_index = output_index, .sequence_number = 0, .summary_index = 0, .part = .{ .text = "" } } });
        }
        try block.text.appendSlice(translator.call.arena, given);
        try translator.emit(out, .{ .summary_text_delta = .{ .item_id = id, .output_index = output_index, .sequence_number = 0, .summary_index = 0, .delta = given } });
    }

    fn callStarted(translator: *Translator, index: u32, raw: *Value, out: *std.ArrayList(Event)) Error!void {
        const arena = translator.call.arena;
        const call_id = textOf(raw.*, "id") orelse return translator.invalid("a tool_use block without its id or name", .{});
        const name = textOf(raw.*, "name") orelse return translator.invalid("a tool_use block without its id or name", .{});
        const output_index: u32 = @intCast(translator.output.items.len);
        const item: OutputItem = .{ .function_call = .{ .id = try arena.print("fc_{s}", .{call_id}), .call_id = call_id, .name = name, .arguments = "", .status = .in_progress } };
        try translator.output.append(arena, item);
        const block = try translator.newBlock(index, .{ .raw = raw, .kind = .{ .call = .{ .output_index = output_index } } });
        if (raw.object.get("input")) |input| {
            const empty = input == .object and input.object.count() == 0;
            if (!empty) try block.text.appendSlice(arena, try foundation.json.encode(arena, input));
        }
        try translator.emit(out, .{ .output_item_added = .{ .item = item, .output_index = output_index, .sequence_number = 0 } });
    }

    fn serverCallStarted(translator: *Translator, index: u32, raw: *Value, out: *std.ArrayList(Event)) Error!void {
        const arena = translator.call.arena;
        const call_id = textOf(raw.*, "id") orelse return translator.invalid("a server_tool_use block without its id or name", .{});
        const name = textOf(raw.*, "name") orelse return translator.invalid("a server_tool_use block without its id or name", .{});
        const output_index: u32 = @intCast(translator.output.items.len);
        if (std.mem.eql(u8, name, wire.web_search_name)) {
            const id = try arena.print("ws_{s}", .{call_id});
            const item: OutputItem = .{ .web_search_call = .{ .id = id, .status = .in_progress } };
            try translator.output.append(arena, item);
            _ = try translator.newBlock(index, .{ .raw = raw, .kind = .{ .search = .{ .output_index = output_index, .call_id = call_id } } });
            try translator.emit(out, .{ .output_item_added = .{ .item = item, .output_index = output_index, .sequence_number = 0 } });
            return translator.emit(out, .{ .web_search_call_in_progress = .{ .item_id = id, .output_index = output_index, .sequence_number = 0 } });
        }
        const searches = for (wire.tool_search_names) |each| {
            if (std.mem.eql(u8, each, name)) break true;
        } else false;
        if (!searches) return translator.invalid("a call of the server tool {s}, which the request did not declare", .{name});
        const item: OutputItem = .{ .tool_search_call = .{ .id = try arena.print("ts_{s}", .{call_id}), .call_id = call_id, .execution = .server, .status = .in_progress } };
        try translator.output.append(arena, item);
        _ = try translator.newBlock(index, .{ .raw = raw, .kind = .{ .tool_search = .{ .output_index = output_index, .call_id = call_id } } });
        try translator.emit(out, .{ .output_item_added = .{ .item = item, .output_index = output_index, .sequence_number = 0 } });
    }

    fn searchFound(translator: *Translator, index: u32, raw: *Value, out: *std.ArrayList(Event)) Error!void {
        const arena = translator.call.arena;
        _ = try translator.newBlock(index, .{ .raw = raw, .kind = .result });
        const tool_use_id = textOf(raw.*, "tool_use_id") orelse return translator.invalid("a web_search_tool_result block without its results", .{});
        const search = translator.searches.fetchRemove(tool_use_id) orelse return translator.invalid("the results of the search {s}, which the stream did not begin", .{tool_use_id});
        const results = raw.object.get("content") orelse return translator.invalid("a web_search_tool_result block without its results", .{});
        var sources: std.ArrayList(vocabulary.items.WebSearchSource) = .empty;
        if (results == .array) for (results.array.items) |result| if (textOf(result, "url")) |url| try sources.append(arena, .{ .url = url });
        const id = translator.output.items[search.value.output_index].web_search_call.id;
        const item: OutputItem = .{ .web_search_call = .{
            .id = id,
            .status = if (results == .array) .completed else .failed,
            .action = .{ .search = .{ .query = search.value.query, .sources = sources.items } },
            .octoii = try blocksMetadata(arena, &.{ search.value.raw, raw }),
        } };
        try translator.emit(out, .{ .web_search_call_completed = .{ .item_id = id, .output_index = search.value.output_index, .sequence_number = 0 } });
        try translator.done(search.value.output_index, item, out);
    }

    fn toolsFound(translator: *Translator, index: u32, raw: *Value, out: *std.ArrayList(Event)) Error!void {
        const arena = translator.call.arena;
        _ = try translator.newBlock(index, .{ .raw = raw, .kind = .result });
        const tool_use_id = textOf(raw.*, "tool_use_id") orelse return translator.invalid("a tool_search_tool_result block without its results", .{});
        const content = raw.object.get("content") orelse return translator.invalid("a tool_search_tool_result block without its results", .{});
        const references = if (content == .object) content.object.get("tool_references") else null;
        var tools: std.ArrayList(vocabulary.Tool) = .empty;
        if (references) |found| if (found == .array) for (found.array.items) |reference| {
            const name = textOf(reference, "tool_name") orelse continue;
            if (translator.tools.get(name)) |tool| try tools.append(arena, tool);
        };
        const output_index: u32 = @intCast(translator.output.items.len);
        const item: OutputItem = .{ .tool_search_output = .{
            .id = try arena.print("tso_{s}", .{tool_use_id}),
            .call_id = tool_use_id,
            .execution = .server,
            .tools = tools.items,
            .status = if (references == null) .incomplete else .completed,
            .octoii = try blocksMetadata(arena, &.{raw}),
        } };
        try translator.output.append(arena, item);
        try translator.emit(out, .{ .output_item_added = .{ .item = item, .output_index = output_index, .sequence_number = 0 } });
        try translator.emit(out, .{ .output_item_done = .{ .item = item, .output_index = output_index, .sequence_number = 0 } });
    }

    fn blockChanged(translator: *Translator, index: u32, delta: wire.Delta, out: *std.ArrayList(Event)) Error!void {
        const arena = translator.call.arena;
        const block = translator.blocks.get(index) orelse return translator.invalid("a change to the block {d}, which the stream did not begin", .{index});
        switch (delta) {
            .text_delta => |given| if (block.kind == .text) try translator.textAdded(block, given.text, out),
            .citations_delta => |given| {
                const citations = try block.raw.object.getOrPut(arena, "citations");
                if (!citations.found_existing or citations.value_ptr.* != .array) citations.value_ptr.* = .{ .array = std.json.Array.init(arena) };
                try citations.value_ptr.array.append(given.citation);
            },
            .thinking_delta => |given| if (block.kind == .thinking) try translator.thought(block, given.thinking, out),
            .signature_delta => |given| if (block.kind == .thinking) try block.signature.appendSlice(arena, given.signature),
            .input_json_delta => |given| switch (block.kind) {
                .call => |state| {
                    try block.text.appendSlice(arena, given.partial_json);
                    if (given.partial_json.len == 0) return;
                    const id = translator.output.items[state.output_index].function_call.id.?;
                    try translator.emit(out, .{ .function_call_arguments_delta = .{ .item_id = id, .output_index = state.output_index, .sequence_number = 0, .delta = given.partial_json } });
                },
                .search, .tool_search => try block.text.appendSlice(arena, given.partial_json),
                else => {},
            },
        }
    }

    fn blockStopped(translator: *Translator, index: u32, out: *std.ArrayList(Event)) Error!void {
        const arena = translator.call.arena;
        const block = translator.blocks.get(index) orelse return translator.invalid("the end of the block {d}, which the stream did not begin", .{index});
        switch (block.kind) {
            .text => |state| {
                try block.raw.object.put(arena, "text", .{ .string = block.text.items });
                try translator.cited(block, state.start, out);
            },
            .thinking => |state| try translator.thinkingStopped(block, state.output_index, out),
            .redacted => |state| {
                var item = translator.output.items[state.output_index];
                item.reasoning.status = .completed;
                try translator.done(state.output_index, item, out);
            },
            .call => |state| {
                const text = if (block.text.items.len == 0) "{}" else block.text.items;
                const input = parsed(arena, text);
                const whole = input != null and input.? == .object;
                try block.raw.object.put(arena, "input", if (whole) input.? else .{ .object = .empty });
                var item = translator.output.items[state.output_index];
                item.function_call.arguments = text;
                item.function_call.status = if (whole) .completed else .incomplete;
                try translator.emit(out, .{ .function_call_arguments_done = .{ .item_id = item.function_call.id.?, .output_index = state.output_index, .sequence_number = 0, .name = item.function_call.name, .arguments = text } });
                try translator.done(state.output_index, item, out);
            },
            .search => |state| {
                const input = parsed(arena, if (block.text.items.len == 0) "{}" else block.text.items) orelse Value{ .object = .empty };
                try block.raw.object.put(arena, "input", input);
                try translator.searches.put(arena, state.call_id, .{ .output_index = state.output_index, .raw = block.raw, .query = textOf(input, "query") orelse "" });
                try translator.emit(out, .{ .web_search_call_searching = .{ .item_id = translator.output.items[state.output_index].web_search_call.id, .output_index = state.output_index, .sequence_number = 0 } });
            },
            .tool_search => |state| {
                const input = parsed(arena, if (block.text.items.len == 0) "{}" else block.text.items);
                try block.raw.object.put(arena, "input", input orelse Value{ .object = .empty });
                var item = translator.output.items[state.output_index];
                item.tool_search_call.status = .completed;
                if (input) |given| item.tool_search_call.arguments = .{ .text = try foundation.json.encode(arena, given) };
                item.tool_search_call.octoii = try blocksMetadata(arena, &.{block.raw});
                try translator.done(state.output_index, item, out);
            },
            .result => {},
        }
    }

    /// A text block ended: the sources it cites become annotations of the whole of its text.
    fn cited(translator: *Translator, block: *Block, start: u32, out: *std.ArrayList(Event)) Error!void {
        const message = translator.message orelse return;
        const citations = block.raw.object.get("citations") orelse return;
        if (citations != .array or citations.array.items.len == 0) return;
        message.cited = true;
        for (citations.array.items) |citation| {
            const kind = textOf(citation, "type") orelse continue;
            if (!std.mem.eql(u8, kind, "web_search_result_location")) continue;
            const url = textOf(citation, "url") orelse continue;
            const annotation: vocabulary.content.Annotation = .{ .url_citation = .{ .url = url, .title = textOf(citation, "title") orelse url, .start_index = start, .end_index = utf16Length(message.text.items) } };
            try message.annotations.append(translator.call.arena, annotation);
            try translator.emit(out, .{ .annotation_added = .{ .item_id = message.id, .output_index = message.output_index, .sequence_number = 0, .content_index = 0, .annotation_index = @intCast(message.annotations.items.len - 1), .annotation = annotation } });
        }
    }

    fn thinkingStopped(translator: *Translator, block: *Block, output_index: u32, out: *std.ArrayList(Event)) Error!void {
        const arena = translator.call.arena;
        try block.raw.object.put(arena, "thinking", .{ .string = block.text.items });
        try block.raw.object.put(arena, "signature", .{ .string = block.signature.items });
        var item = translator.output.items[output_index];
        const id = item.reasoning.id;
        if (block.text.items.len > 0) {
            try translator.emit(out, .{ .summary_text_done = .{ .item_id = id, .output_index = output_index, .sequence_number = 0, .summary_index = 0, .text = block.text.items } });
            try translator.emit(out, .{ .summary_part_done = .{ .item_id = id, .output_index = output_index, .sequence_number = 0, .summary_index = 0, .part = .{ .text = block.text.items } } });
            item.reasoning.summary = try arena.dupe(vocabulary.content.SummaryText, &.{.{ .text = block.text.items }});
        }
        if (block.signature.items.len > 0) item.reasoning.signature = block.signature.items;
        item.reasoning.status = if (block.signature.items.len == 0) .incomplete else .completed;
        try translator.done(output_index, item, out);
    }

    /// The piece ended: the open message ended with it, its usage added, and the response ended unless it paused.
    fn stopped(translator: *Translator, out: *std.ArrayList(Event)) Error!void {
        const reason = translator.stop_reason;
        const incomplete: @FieldType(vocabulary.response.IncompleteDetails, "reason") = if (reason) |given| (if (std.mem.eql(u8, given, "max_tokens") or std.mem.eql(u8, given, "model_context_window_exceeded")) .max_output_tokens else if (std.mem.eql(u8, given, "refusal")) .content_filter else null) else null;
        try translator.closeMessage(if (incomplete == null) .completed else .incomplete, out);
        translator.total = translator.total.plus(translator.piece);
        translator.context_tokens = translator.piece.inputTokens();
        const given = reason orelse return translator.invalid("a response that ended for no reason", .{});
        if (std.mem.eql(u8, given, "pause_turn")) {
            translator.ending = .paused;
            return;
        }
        const whole = for ([_][]const u8{ "end_turn", "tool_use", "stop_sequence" }) |each| {
            if (std.mem.eql(u8, each, given)) break true;
        } else false;
        if (incomplete == null and !whole) return translator.call.failWith(.invalid_response, "The response ended for a reason ai does not know: {s}", .{given});
        translator.ending = .ended;
        if (incomplete) |why| return translator.emit(out, .{ .incomplete = .{ .response = try translator.response(.incomplete, .{ .reason = why }), .sequence_number = 0 } });
        try translator.emit(out, .{ .completed = .{ .response = try translator.response(.completed, null), .sequence_number = 0 } });
    }

    /// The stream's error, then the response failed with it and the usage so far.
    fn failed(translator: *Translator, given: wire.Error, out: *std.ArrayList(Event)) Error!void {
        const extension = failureOf(given);
        translator.total = translator.total.plus(translator.piece);
        translator.piece = .{};
        translator.ending = .ended;
        var failed_response = try translator.response(.failed, null);
        failed_response.output = &.{};
        failed_response.@"error" = .{ .code = given.type, .message = given.message, .octoii = extension };
        try translator.emit(out, .{ .@"error" = .{ .code = given.type, .message = given.message, .octoii = extension, .sequence_number = 0 } });
        try translator.emit(out, .{ .failed = .{ .response = failed_response, .sequence_number = 0 } });
    }

    /// Ends the open message, `status` as the response ended.
    fn closeMessage(translator: *Translator, status: vocabulary.items.ItemStatus, out: *std.ArrayList(Event)) Error!void {
        const message = translator.message orelse return;
        translator.message = null;
        const arena = translator.call.arena;
        const part: vocabulary.content.OutputText = .{ .text = message.text.items, .annotations = message.annotations.items };
        try translator.emit(out, .{ .output_text_done = .{ .item_id = message.id, .output_index = message.output_index, .sequence_number = 0, .content_index = 0, .text = message.text.items, .logprobs = &.{} } });
        try translator.emit(out, .{ .content_part_done = .{ .item_id = message.id, .output_index = message.output_index, .sequence_number = 0, .content_index = 0, .part = .{ .output_text = part } } });
        const item: OutputItem = .{ .output_message = .{
            .type = .message,
            .id = message.id,
            .status = status,
            .content = .{ .parts = try arena.dupe(vocabulary.OutputContent, &.{.{ .output_text = part }}) },
            .octoii = if (message.cited) try blocksMetadata(arena, message.blocks.items) else null,
        } };
        try translator.done(message.output_index, item, out);
    }

    fn done(translator: *Translator, output_index: u32, item: OutputItem, out: *std.ArrayList(Event)) Allocator.Error!void {
        translator.output.items[output_index] = item;
        try translator.emit(out, .{ .output_item_done = .{ .item = item, .output_index = output_index, .sequence_number = 0 } });
    }

    /// The response as it stands: its items, its usage so far, and the input of its last request.
    fn response(translator: *Translator, status: vocabulary.response.ResponseStatus, incomplete: ?vocabulary.response.IncompleteDetails) Allocator.Error!vocabulary.Response {
        const begun = translator.response_id != null;
        // Under way, the response has used what the pieces before used and what this one has so far.
        const counts = if (status == .in_progress) translator.total.plus(translator.piece) else translator.total;
        return .{
            .id = translator.response_id orelse "",
            .status = status,
            .incomplete_details = incomplete,
            .output = try translator.call.arena.dupe(OutputItem, translator.output.items),
            .usage = if (begun) counts.usage() else null,
            .octoii = if (status == .in_progress) null else .{ .context_tokens = translator.context_tokens },
        };
    }
};

/// The failure kind of each of Anthropic's error types.
const error_types = std.StaticStringMap(failure_.Kind).initComptime(.{
    .{ "invalid_request_error", .invalid_request }, .{ "not_found_error", .invalid_request },
    .{ "authentication_error", .auth },             .{ "permission_error", .forbidden },
    .{ "billing_error", .quota },                   .{ "request_too_large", .payload_too_large },
    .{ "rate_limit_error", .rate_limit },           .{ "api_error", .server },
    .{ "overloaded_error", .server },               .{ "timeout_error", .server },
});

/// The kind of an error by its type, and a prompt too long for the model's window as `context_overflow`, in whichever
/// words Anthropic puts it; null for a type ai does not know.
pub fn kindOf(given: wire.Error) ?failure_.Kind {
    const kind = error_types.get(given.type) orelse return null;
    if (kind != .invalid_request) return kind;
    var lowered: [512]u8 = undefined;
    const message = std.ascii.lowerString(&lowered, given.message[0..@min(given.message.len, lowered.len)]);
    const too_long = std.mem.indexOf(u8, message, "prompt is too long") != null or
        std.mem.indexOf(u8, message, "context window") != null or
        std.mem.indexOf(u8, message, "context length") != null or
        (std.mem.indexOf(u8, message, "exceed") != null and std.mem.indexOf(u8, message, "context limit") != null);
    return if (too_long) .context_overflow else kind;
}

fn failureOf(given: wire.Error) vocabulary.extensions.FailureExtension {
    const kind = kindOf(given) orelse .server;
    return .{ .kind = kind, .retryable = failure_.retryableKind(kind) };
}

/// An item's provider metadata that keeps the blocks it came as.
fn blocksMetadata(arena: Allocator, blocks: []const *Value) Allocator.Error!vocabulary.extensions.ItemExtension {
    var list = std.json.Array.init(arena);
    for (blocks) |block| try list.append(block.*);
    var own: Value = .{ .object = .empty };
    try own.object.put(arena, "blocks", .{ .array = list });
    var metadata: Value = .{ .object = .empty };
    try metadata.object.put(arena, "anthropic", own);
    return .{ .provider_metadata = .{ .text = try foundation.json.encode(arena, metadata) } };
}

fn textOf(value: Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const member = value.object.get(key) orelse return null;
    return if (member == .string) member.string else null;
}

fn parsed(arena: Allocator, text: []const u8) ?Value {
    return std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always }) catch null;
}

/// The length of text in UTF-16 code units, the unit an annotation's indexes count in.
fn utf16Length(text: []const u8) u32 {
    var length: u32 = 0;
    for (text) |byte| {
        if (byte & 0xC0 != 0x80) length += 1;
        if (byte & 0xF8 == 0xF0) length += 1;
    }
    return length;
}
