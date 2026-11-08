//! Google's interaction as the vocabulary's events: a thought a reasoning item, a model's output a message of its text
//! and images with their citations, each function call an item of its own with a `call_id` ai gives it, Gemini's id
//! kept, and a search of Google's, its call and its result, a web search call. An item whose step stopped is ended
//! once the next step starts, or the interaction ends, as the end may cut it off; the interaction's status and usage
//! end the response.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const Event = vocabulary.ResponseStreamEvent;
const OutputItem = vocabulary.OutputItem;
const ItemStatus = vocabulary.items.ItemStatus;
const content = vocabulary.content;
const Call = @import("../../driver.zig").Call;
const Error = @import("../../failure.zig").Error;
const Model = @import("../../catalogue/model.zig").Model;
const wire = @import("interactions.zig");

/// A message a `model_output` step streams into, with the text part streaming and the citations Google gave it.
const Message = struct {
    output_index: u32,
    id: []const u8,
    content: std.ArrayList(vocabulary.OutputContent) = .empty,
    text: ?struct { content_index: u32, value: std.ArrayList(u8) = .empty, annotations: std.ArrayList(Value) = .empty } = null,
};

/// A reasoning item a `thought` step streams into.
const Reasoning = struct { output_index: u32, id: []const u8, text: std.ArrayList(u8) = .empty, signature: ?[]const u8 = null };

/// A function call a `function_call` step streams into, its arguments as they come, else as its start gave them.
const FunctionCall = struct {
    output_index: u32,
    id: []const u8,
    call_id: []const u8,
    name: []const u8,
    google_id: ?[]const u8,
    started: ?Value,
    arguments: std.ArrayList(u8) = .empty,
};

/// A web search call that a `google_search_call` step opens and its `google_search_result` step ends.
const Search = struct {
    output_index: u32,
    id: []const u8,
    google_id: ?[]const u8,
    queries: []const []const u8,
    signature: ?[]const u8 = null,
    result_signature: ?[]const u8 = null,
    suggestions: ?[]const u8 = null,
};

/// An output item of the response while its stream may still add to it.
const Open = union(enum) {
    message: *Message,
    reasoning: *Reasoning,
    call: *FunctionCall,
    search: *Search,

    fn outputIndex(open: Open) u32 {
        return switch (open) {
            inline else => |item| item.output_index,
        };
    }
};

/// The item a step streams into: an open item, a search's result, or none for a step ai does not read.
const Target = union(enum) { open: Open, result: *Search, none };

pub const Answer = struct {
    call: *Call,
    model: *const Model,
    output: std.ArrayList(OutputItem) = .empty,
    steps: std.AutoHashMapUnmanaged(u32, Target) = .empty,
    /// The searches whose results have yet to end them.
    searches: std.ArrayList(*Search) = .empty,
    /// The items whose steps stopped, ended once the next step starts or the interaction ends.
    stopped: std.ArrayList(Open) = .empty,
    id: ?[]const u8 = null,

    /// The vocabulary's events one of the interaction's events stands for, onto `out`, the response created before
    /// the first.
    pub fn event(answer: *Answer, given: wire.Event, out: *std.ArrayList(Event)) Error!void {
        if (answer.id == null) {
            answer.id = (if (given == .created) given.created.id else null) orelse try answer.call.host.newId(answer.call.arena);
            try answer.emit(out, .{ .created = .{ .response = try answer.response(.in_progress, null), .sequence_number = 0 } });
        }
        switch (given) {
            .created => {},
            .step_start => |begun| {
                try answer.endStopped(.completed, out);
                try answer.start(begun.index, begun.step, out);
            },
            .step_delta => |more| try answer.delta(answer.steps.get(more.index) orelse .none, more.delta, out),
            .step_stop => |index| try answer.stop(index),
            .completed => |ended| try answer.end(ended.status, ended.usage, out),
        }
    }

    fn start(answer: *Answer, index: u32, step: wire.Step, out: *std.ArrayList(Event)) Error!void {
        const arena = answer.call.arena;
        if (std.mem.eql(u8, step.type, "model_output")) {
            const message = try answer.openMessage(index, out);
            for (step.content orelse &.{}) |block| try answer.messageContent(message, block, out);
        } else if (std.mem.eql(u8, step.type, "thought")) {
            const reasoning = try answer.openReasoning(index, out);
            for (step.summary orelse &.{}) |block| try answer.thought(reasoning, block, out);
            reasoning.signature = nonEmpty(step.signature) orelse reasoning.signature;
        } else if (std.mem.eql(u8, step.type, "function_call")) {
            const made = try arena.create(FunctionCall);
            made.* = .{ .output_index = answer.nextIndex(), .id = try answer.newId(), .call_id = try answer.newId(), .name = step.name orelse "", .google_id = step.id, .started = step.arguments };
            try answer.begin(index, .{ .call = made }, out);
        } else if (std.mem.eql(u8, step.type, "google_search_call")) {
            const made = try arena.create(Search);
            made.* = .{ .output_index = answer.nextIndex(), .id = try answer.newId(), .google_id = step.id, .queries = try queriesOf(arena, step.arguments) orelse &.{}, .signature = nonEmpty(step.signature) };
            try answer.searches.append(arena, made);
            try answer.begin(index, .{ .search = made }, out);
            try answer.emit(out, .{ .web_search_call_in_progress = .{ .item_id = made.id, .output_index = made.output_index, .sequence_number = 0 } });
        } else if (std.mem.eql(u8, step.type, "google_search_result")) {
            const search = answer.searchOf(step.call_id) orelse return answer.steps.put(arena, index, .none);
            try answer.steps.put(arena, index, .{ .result = search });
            try searchResult(arena, search, step.result, step.signature);
        } else try answer.steps.put(arena, index, .none);
    }

    fn delta(answer: *Answer, target: Target, given: wire.Delta, out: *std.ArrayList(Event)) Error!void {
        const arena = answer.call.arena;
        switch (target) {
            .none => {},
            .result => |search| try searchResult(arena, search, given.result, given.signature),
            .open => |open| switch (open) {
                .message => |message| if (std.mem.eql(u8, given.type, "text_annotation_delta")) {
                    if (message.text) |*text| try text.annotations.appendSlice(arena, given.annotations orelse &.{});
                } else try answer.messageContent(message, given.asContent(), out),
                .reasoning => |reasoning| {
                    if (std.mem.eql(u8, given.type, "thought_summary")) if (given.content) |block| try answer.thought(reasoning, block, out);
                    if (std.mem.eql(u8, given.type, "thought_signature")) reasoning.signature = nonEmpty(given.signature) orelse reasoning.signature;
                },
                .call => |made| if (std.mem.eql(u8, given.type, "arguments_delta")) if (given.arguments) |arguments| if (arguments == .string and arguments.string.len > 0) {
                    try made.arguments.appendSlice(arena, arguments.string);
                    try answer.emit(out, .{ .function_call_arguments_delta = .{ .item_id = made.id, .output_index = made.output_index, .delta = arguments.string, .sequence_number = 0 } });
                },
                .search => |search| {
                    if (try queriesOf(arena, given.arguments)) |queries| search.queries = queries;
                    search.signature = nonEmpty(given.signature) orelse search.signature;
                },
            },
        }
    }

    /// Holds the item of a step that stopped until the next starts or the interaction ends; a search ends with its
    /// result.
    fn stop(answer: *Answer, index: u32) Allocator.Error!void {
        const removed = answer.steps.fetchRemove(index) orelse return;
        switch (removed.value) {
            .none => {},
            .open => |open| if (open != .search) try answer.stopped.append(answer.call.arena, open),
            .result => |search| {
                for (answer.searches.items, 0..) |pending, at| if (pending == search) {
                    _ = answer.searches.orderedRemove(at);
                    break;
                };
                try answer.stopped.append(answer.call.arena, .{ .search = search });
            },
        }
    }

    /// Every item still open ended, cut off where the interaction ended `incomplete`, then the response completed, or
    /// incomplete at its output limit, with its usage.
    fn end(answer: *Answer, status: wire.EndStatus, usage: ?wire.Usage, out: *std.ArrayList(Event)) Error!void {
        const arena = answer.call.arena;
        var it = answer.steps.valueIterator();
        while (it.next()) |target| if (target.* == .open and target.open != .search) try answer.stopped.append(arena, target.open);
        for (answer.searches.items) |search| try answer.stopped.append(arena, .{ .search = search });
        answer.steps.clearRetainingCapacity();
        answer.searches.clearRetainingCapacity();
        try answer.endStopped(if (status == .incomplete) .incomplete else .completed, out);
        if (status == .incomplete) {
            var ended = try answer.response(.incomplete, usage);
            ended.incomplete_details = .{ .reason = .max_output_tokens };
            return answer.emit(out, .{ .incomplete = .{ .response = ended, .sequence_number = 0 } });
        }
        try answer.emit(out, .{ .completed = .{ .response = try answer.response(.completed, usage), .sequence_number = 0 } });
    }

    /// Ends every item whose step stopped, with `status`, in the order they stand.
    fn endStopped(answer: *Answer, status: ItemStatus, out: *std.ArrayList(Event)) Error!void {
        const stopped = answer.stopped.items;
        answer.stopped = .empty;
        std.mem.sort(Open, stopped, {}, struct {
            fn less(_: void, a: Open, b: Open) bool {
                return a.outputIndex() < b.outputIndex();
            }
        }.less);
        var last: ?u32 = null;
        for (stopped) |open| {
            if (last == open.outputIndex()) continue;
            last = open.outputIndex();
            try answer.close(open, status, out);
        }
    }

    fn nextIndex(answer: *const Answer) u32 {
        return @intCast(answer.output.items.len);
    }

    fn newId(answer: *Answer) Allocator.Error![]const u8 {
        return answer.call.host.newId(answer.call.arena);
    }

    /// Makes `open` the item the step at `index` streams into, holding its place in the output.
    fn begin(answer: *Answer, index: u32, open: Open, out: *std.ArrayList(Event)) Error!void {
        const arena = answer.call.arena;
        try answer.steps.put(arena, index, .{ .open = open });
        const item = try answer.itemOf(open, .in_progress);
        try answer.output.append(arena, item);
        try answer.emit(out, .{ .output_item_added = .{ .output_index = open.outputIndex(), .item = item, .sequence_number = 0 } });
    }

    fn openMessage(answer: *Answer, index: u32, out: *std.ArrayList(Event)) Error!*Message {
        const message = try answer.call.arena.create(Message);
        message.* = .{ .output_index = answer.nextIndex(), .id = try answer.newId() };
        try answer.begin(index, .{ .message = message }, out);
        return message;
    }

    /// A reasoning item opened, with its one summary part begun.
    fn openReasoning(answer: *Answer, index: u32, out: *std.ArrayList(Event)) Error!*Reasoning {
        const reasoning = try answer.call.arena.create(Reasoning);
        reasoning.* = .{ .output_index = answer.nextIndex(), .id = try answer.newId() };
        try answer.begin(index, .{ .reasoning = reasoning }, out);
        try answer.emit(out, .{ .summary_part_added = .{ .item_id = reasoning.id, .output_index = reasoning.output_index, .summary_index = 0, .part = .{ .text = "" }, .sequence_number = 0 } });
        return reasoning;
    }

    /// The search a result answers, by its call's id, else the last search opened.
    fn searchOf(answer: *const Answer, call_id: ?[]const u8) ?*Search {
        if (call_id) |id| for (answer.searches.items) |search| {
            if (search.google_id) |own| if (std.mem.eql(u8, own, id)) return search;
        };
        return if (answer.searches.items.len == 0) null else answer.searches.items[answer.searches.items.len - 1];
    }

    /// More of a message: text, in the text part streaming or a new one, or an image made, ending the text before it.
    fn messageContent(answer: *Answer, message: *Message, block: wire.Content, out: *std.ArrayList(Event)) Error!void {
        const arena = answer.call.arena;
        if (std.mem.eql(u8, block.type, "text")) {
            const text = block.text orelse return;
            try answer.messageText(message, text, out);
            if (block.annotations) |annotations| try message.text.?.annotations.appendSlice(arena, annotations);
            return;
        }
        if (!std.mem.eql(u8, block.type, "image") or (block.data == null and block.uri == null)) return;
        try answer.closeText(message, out);
        const url = if (block.data) |data| try std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ block.mime_type orelse "image/png", data }) else block.uri.?;
        const index: u32 = @intCast(message.content.items.len);
        try message.content.append(arena, .{ .output_image = .{ .image_url = url } });
        const part: vocabulary.events.ContentPart = .{ .output_image = .{ .image_url = url } };
        try answer.emit(out, .{ .content_part_added = .{ .item_id = message.id, .output_index = message.output_index, .content_index = index, .part = part, .sequence_number = 0 } });
        try answer.emit(out, .{ .content_part_done = .{ .item_id = message.id, .output_index = message.output_index, .content_index = index, .part = part, .sequence_number = 0 } });
    }

    fn messageText(answer: *Answer, message: *Message, text: []const u8, out: *std.ArrayList(Event)) Error!void {
        const arena = answer.call.arena;
        if (message.text == null) {
            message.text = .{ .content_index = @intCast(message.content.items.len) };
            try message.content.append(arena, .{ .output_text = .{ .text = "", .annotations = &.{} } });
            try answer.emit(out, .{ .content_part_added = .{ .item_id = message.id, .output_index = message.output_index, .content_index = message.text.?.content_index, .part = .{ .output_text = .{ .text = "", .annotations = &.{} } }, .sequence_number = 0 } });
        }
        if (text.len == 0) return;
        const open = &message.text.?;
        try open.value.appendSlice(arena, text);
        try answer.emit(out, .{ .output_text_delta = .{ .item_id = message.id, .output_index = message.output_index, .content_index = open.content_index, .delta = text, .logprobs = &.{}, .sequence_number = 0 } });
    }

    /// More of a thought's summary, where it is text.
    fn thought(answer: *Answer, reasoning: *Reasoning, block: wire.Content, out: *std.ArrayList(Event)) Error!void {
        if (!std.mem.eql(u8, block.type, "text")) return;
        const text = block.text orelse return;
        if (text.len == 0) return;
        try reasoning.text.appendSlice(answer.call.arena, text);
        try answer.emit(out, .{ .summary_text_delta = .{ .item_id = reasoning.id, .output_index = reasoning.output_index, .summary_index = 0, .delta = text, .sequence_number = 0 } });
    }

    /// Ends a message's text part, if one is streaming: its citations, their offsets counted again in characters,
    /// then the text.
    fn closeText(answer: *Answer, message: *Message, out: *std.ArrayList(Event)) Error!void {
        const text = message.text orelse return;
        message.text = null;
        const annotations = try citationsOf(answer.call.arena, text.annotations.items, text.value.items);
        for (annotations, 0..) |annotation, index| {
            try answer.emit(out, .{ .annotation_added = .{ .item_id = message.id, .output_index = message.output_index, .content_index = text.content_index, .annotation_index = @intCast(index), .annotation = annotation, .sequence_number = 0 } });
        }
        const done: content.OutputText = .{ .text = text.value.items, .annotations = annotations };
        message.content.items[text.content_index] = .{ .output_text = done };
        try answer.emit(out, .{ .output_text_done = .{ .item_id = message.id, .output_index = message.output_index, .content_index = text.content_index, .text = text.value.items, .logprobs = &.{}, .sequence_number = 0 } });
        try answer.emit(out, .{ .content_part_done = .{ .item_id = message.id, .output_index = message.output_index, .content_index = text.content_index, .part = .{ .output_text = done }, .sequence_number = 0 } });
    }

    /// Ends `open` with `status`: its text, summary or arguments done, then the item.
    fn close(answer: *Answer, open: Open, status: ItemStatus, out: *std.ArrayList(Event)) Error!void {
        const arena = answer.call.arena;
        switch (open) {
            .message => |message| try answer.closeText(message, out),
            .reasoning => |reasoning| {
                try answer.emit(out, .{ .summary_text_done = .{ .item_id = reasoning.id, .output_index = reasoning.output_index, .summary_index = 0, .text = reasoning.text.items, .sequence_number = 0 } });
                try answer.emit(out, .{ .summary_part_done = .{ .item_id = reasoning.id, .output_index = reasoning.output_index, .summary_index = 0, .part = .{ .text = reasoning.text.items }, .sequence_number = 0 } });
            },
            .call => |made| {
                if (made.arguments.items.len == 0) {
                    const started = made.started orelse Value{ .null = {} };
                    try made.arguments.appendSlice(arena, try foundation.json.encode(arena, if (started == .object) started else Value{ .object = .empty }));
                    try answer.emit(out, .{ .function_call_arguments_delta = .{ .item_id = made.id, .output_index = made.output_index, .delta = made.arguments.items, .sequence_number = 0 } });
                }
                try answer.emit(out, .{ .function_call_arguments_done = .{ .item_id = made.id, .output_index = made.output_index, .name = made.name, .arguments = made.arguments.items, .sequence_number = 0 } });
            },
            .search => |search| try answer.emit(out, .{ .web_search_call_completed = .{ .item_id = search.id, .output_index = search.output_index, .sequence_number = 0 } }),
        }
        const done = try answer.itemOf(open, status);
        answer.output.items[open.outputIndex()] = done;
        try answer.emit(out, .{ .output_item_done = .{ .output_index = open.outputIndex(), .item = done, .sequence_number = 0 } });
    }

    /// The output item an open item stands for, with `status`, and what Google attached to it once it is done.
    fn itemOf(answer: *Answer, open: Open, status: ItemStatus) Allocator.Error!OutputItem {
        const arena = answer.call.arena;
        const done = status != .in_progress;
        return switch (open) {
            .message => |message| .{ .output_message = .{ .type = .message, .id = message.id, .status = status, .content = .{ .parts = if (done) try arena.dupe(vocabulary.OutputContent, message.content.items) else &.{} } } },
            .reasoning => |reasoning| .{ .reasoning = .{
                .id = reasoning.id,
                .summary = if (done) try arena.dupe(content.SummaryText, &.{.{ .text = reasoning.text.items }}) else &.{},
                .format = .@"google-gemini-v1",
                .status = status,
                .signature = if (done) reasoning.signature else null,
            } },
            .call => |made| .{ .function_call = .{
                .id = made.id,
                .call_id = made.call_id,
                .name = made.name,
                .arguments = if (done) made.arguments.items else "",
                .status = status,
                .octoii = if (done) try metadataOf(arena, .{ .id = made.google_id }) else null,
            } },
            .search => |search| if (!done) .{ .web_search_call = .{ .id = search.id, .status = .in_progress } } else .{ .web_search_call = .{
                .id = search.id,
                .status = .completed,
                .action = .{ .search = .{ .query = if (search.queries.len > 0) search.queries[0] else "", .queries = search.queries } },
                .octoii = try metadataOf(arena, .{ .id = search.google_id, .signature = search.signature, .result_signature = search.result_signature, .search_suggestions = search.suggestions }),
            } },
        };
    }

    /// The response as it stands, with `status`, its usage and the tokens of its context.
    fn response(answer: *Answer, status: vocabulary.response.ResponseStatus, usage: ?wire.Usage) Allocator.Error!vocabulary.Response {
        const counted = if (usage) |given| responseUsage(answer.model, given) else null;
        return .{
            .id = answer.id orelse "",
            .status = status,
            .output = try answer.call.arena.dupe(OutputItem, answer.output.items),
            .usage = counted,
            .octoii = if (counted) |known| .{ .context_tokens = known.input_tokens } else null,
        };
    }

    fn emit(answer: *Answer, out: *std.ArrayList(Event), given: Event) Allocator.Error!void {
        try out.append(answer.call.arena, given);
    }
};

/// A search's queries, as its call's arguments give them; null where they give none.
fn queriesOf(arena: Allocator, arguments: ?Value) Allocator.Error!?[]const []const u8 {
    const given = arguments orelse return null;
    const parsed = foundation.json.decodeValue(struct { queries: ?[]const []const u8 = null }, arena, given) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return parsed.queries;
}

/// Keeps what a search's result gives: its search suggestions and its signature.
fn searchResult(arena: Allocator, search: *Search, result: ?Value, signature: ?[]const u8) Allocator.Error!void {
    if (result) |given| {
        const found = foundation.json.decodeValue([]const struct { search_suggestions: ?[]const u8 = null }, arena, given) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        if (found) |entries| for (entries) |entry| if (entry.search_suggestions) |suggestions| {
            search.suggestions = suggestions;
            break;
        };
    }
    search.result_signature = nonEmpty(signature) orelse search.result_signature;
}

/// `text` where it is not empty, as Google sends a signature it has yet to give as empty.
fn nonEmpty(text: ?[]const u8) ?[]const u8 {
    const given = text orelse return null;
    return if (given.len == 0) null else given;
}

/// An item's `octoii` holding what Google attached, where it attached anything.
fn metadataOf(arena: Allocator, metadata: anytype) Allocator.Error!?vocabulary.extensions.ItemExtension {
    const any = inline for (comptime std.meta.fieldNames(@TypeOf(metadata))) |name| {
        if (@field(metadata, name) != null) break true;
    } else false;
    if (!any) return null;
    return .{ .provider_metadata = .{ .text = try foundation.json.encode(arena, .{ .google = metadata }) } };
}

/// Google's annotations on `text` as its citations: each `url_citation` of a page over the characters its offsets in
/// bytes cover. An annotation of another kind, of no page, or past the text, cites nothing.
fn citationsOf(arena: Allocator, annotations: []const Value, text: []const u8) Allocator.Error![]const content.Annotation {
    var made: std.ArrayList(content.Annotation) = .empty;
    for (annotations) |annotation| {
        const citation = foundation.json.decodeValue(struct { type: enum { url_citation }, url: ?[]const u8 = null, title: ?[]const u8 = null, start_index: ?usize = null, end_index: ?usize = null }, arena, annotation) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        const url = citation.url orelse continue;
        const start = charIndex(text, citation.start_index orelse 0) orelse continue;
        const end = charIndex(text, citation.end_index orelse text.len) orelse continue;
        try made.append(arena, .{ .url_citation = .{ .url = url, .title = citation.title orelse url, .start_index = start, .end_index = end } });
    }
    return made.items;
}

/// The index, in UTF-16 units, of the character at `byte_offset` of `text`'s UTF-8; null past its end.
fn charIndex(text: []const u8, byte_offset: usize) ?u32 {
    var index: u32 = 0;
    var at: usize = 0;
    while (at < text.len) {
        if (at >= byte_offset) return index;
        const length = std.unicode.utf8ByteSequenceLength(text[at]) catch 1;
        index += if (length == 4) 2 else 1;
        at += length;
    }
    return if (at >= byte_offset) index else null;
}

/// The interaction's usage in the vocabulary's: the prompt's and the tools' tokens read, those its cache read, the
/// output's and the thoughts' written, and the searches; audio read, audio read from the cache and images made apart
/// where the model prices them apart.
fn responseUsage(model: *const Model, usage: wire.Usage) vocabulary.response.ResponseUsage {
    const input = (usage.total_input_tokens orelse 0) + (usage.total_tool_use_tokens orelse 0);
    const thoughts = usage.total_thought_tokens orelse 0;
    const output = (usage.total_output_tokens orelse 0) + thoughts;
    var searches: u64 = 0;
    for (usage.grounding_tool_count orelse &.{}) |each| if (each.type) |kind| if (std.mem.eql(u8, kind, "google_search")) {
        searches += each.count orelse 0;
    };
    const pricing = model.pricing;
    const cached_audio = wire.tokensOf(usage.cached_tokens_by_modality, "audio");
    var shares: vocabulary.extensions.UsageExtension = .{};
    if (pricing) |prices| {
        if (prices.audio != null) shares.input_audio_tokens = nonZero(wire.tokensOf(usage.input_tokens_by_modality, "audio") -| cached_audio);
        if (prices.input_audio_cache != null) shares.cache_read_audio_tokens = nonZero(cached_audio);
        if (prices.image_output != null) shares.output_image_tokens = nonZero(wire.tokensOf(usage.output_tokens_by_modality, "image"));
    }
    const any_share = shares.input_audio_tokens != null or shares.cache_read_audio_tokens != null or shares.output_image_tokens != null;
    return .{
        .input_tokens = input,
        .input_tokens_details = .{ .cached_tokens = usage.total_cached_tokens orelse 0 },
        .output_tokens = output,
        .output_tokens_details = .{ .reasoning_tokens = thoughts },
        .total_tokens = usage.total_tokens orelse input + output,
        .server_tool_use_details = if (searches == 0) null else .{ .web_search_requests = searches },
        .octoii = if (any_share) shares else null,
    };
}

fn nonZero(count: u64) ?u64 {
    return if (count > 0) count else null;
}

test "a citation's offsets in bytes are counted again in characters" {
    const text = "Spain won Euro 2024, defeating England 2\u{2013}1 in the final.";
    try std.testing.expectEqual(@as(?u32, 20), charIndex(text, 20));
    try std.testing.expectEqual(@as(?u32, 56), charIndex(text, 58));
    try std.testing.expectEqual(null, charIndex(text, 99));
}
