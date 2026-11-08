//! An output item as its stream builds it: the item as it was added, and its text, arguments, input, parts and summary
//! growing in place as their events come, made whole on asking — so that a long answer's deltas cost what they hold,
//! not a copy each. An item a response ended before it was done is ended with what came of it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vocabulary = @import("vocabulary");
const content = vocabulary.content;
const OutputItem = vocabulary.OutputItem;
const Event = vocabulary.ResponseStreamEvent;

/// A part of a message's or a reasoning item's content, or of a reasoning summary, its text growing.
const Part = struct {
    part: vocabulary.events.ContentPart,
    text: std.ArrayList(u8) = .empty,
    annotations: std.ArrayList(content.Annotation) = .empty,
};

pub const Builder = struct {
    item: OutputItem,
    /// Whether it was added and is not yet done.
    open: bool,
    /// A message's content or a reasoning item's, by its index.
    parts: std.ArrayList(Part) = .empty,
    /// A reasoning item's summary, by its index.
    summary: std.ArrayList(Part) = .empty,
    /// A function call's arguments or a custom tool call's input.
    text: std.ArrayList(u8) = .empty,

    /// A builder of `item`, begun with what it holds already.
    pub fn init(arena: Allocator, item: OutputItem, open: bool) Allocator.Error!Builder {
        var builder: Builder = .{ .item = item, .open = open };
        switch (item) {
            .output_message => |message| switch (message.content) {
                .text => {},
                .parts => |parts| for (parts) |part| try builder.parts.append(arena, try partOf(arena, switch (part) {
                    .output_text => |text| .{ .output_text = text },
                    .output_image => |image| .{ .output_image = image },
                    .refusal => |refusal| .{ .refusal = refusal },
                })),
            },
            .reasoning => |reasoning| {
                for (reasoning.content orelse &.{}) |part| try builder.parts.append(arena, try partOf(arena, .{ .reasoning_text = part }));
                for (reasoning.summary orelse &.{}) |part| try builder.summary.append(arena, try partOf(arena, .{ .reasoning_text = .{ .text = part.text } }));
            },
            .function_call => |call| try builder.text.appendSlice(arena, call.arguments),
            .custom_tool_call => |call| try builder.text.appendSlice(arena, call.input),
            else => {},
        }
        return builder;
    }

    /// Applies an event of the item: more of its text, arguments or input, a part begun or ended, or its search's
    /// progress. An event of what the item does not hold, or at an index past its parts' end, changes nothing.
    pub fn apply(builder: *Builder, arena: Allocator, event: Event) Allocator.Error!void {
        switch (event) {
            inline .content_part_added, .content_part_done => |given| try place(arena, &builder.parts, given.content_index, given.part),
            .output_text_delta => |delta| if (at(&builder.parts, delta.content_index, .output_text)) |part| try part.text.appendSlice(arena, delta.delta),
            .output_text_done => |done| if (at(&builder.parts, done.content_index, .output_text)) |part| try replace(arena, &part.text, done.text),
            .annotation_added => |added| if (at(&builder.parts, added.content_index, .output_text)) |part| {
                if (added.annotation_index < part.annotations.items.len) {
                    part.annotations.items[added.annotation_index] = added.annotation;
                } else if (added.annotation_index == part.annotations.items.len) try part.annotations.append(arena, added.annotation);
            },
            .refusal_delta => |delta| if (at(&builder.parts, delta.content_index, .refusal)) |part| try part.text.appendSlice(arena, delta.delta),
            .refusal_done => |done| if (at(&builder.parts, done.content_index, .refusal)) |part| try replace(arena, &part.text, done.refusal),
            .reasoning_text_delta => |delta| if (at(&builder.parts, delta.content_index, .reasoning_text)) |part| try part.text.appendSlice(arena, delta.delta),
            .reasoning_text_done => |done| if (at(&builder.parts, done.content_index, .reasoning_text)) |part| try replace(arena, &part.text, done.text),
            .summary_part_added => |given| try place(arena, &builder.summary, given.summary_index, .{ .reasoning_text = .{ .text = given.part.text } }),
            .summary_part_done => |given| try place(arena, &builder.summary, given.summary_index, .{ .reasoning_text = .{ .text = given.part.text } }),
            .summary_text_delta => |delta| if (at(&builder.summary, delta.summary_index, .reasoning_text)) |part| try part.text.appendSlice(arena, delta.delta),
            .summary_text_done => |done| if (at(&builder.summary, done.summary_index, .reasoning_text)) |part| try replace(arena, &part.text, done.text),
            .function_call_arguments_delta => |delta| if (builder.item == .function_call) try builder.text.appendSlice(arena, delta.delta),
            .function_call_arguments_done => |done| if (builder.item == .function_call) try replace(arena, &builder.text, done.arguments),
            .custom_tool_call_input_delta => |delta| if (builder.item == .custom_tool_call) try builder.text.appendSlice(arena, delta.delta),
            .custom_tool_call_input_done => |done| if (builder.item == .custom_tool_call) try replace(arena, &builder.text, done.input),
            .web_search_call_in_progress => builder.searching(.in_progress),
            .web_search_call_searching => builder.searching(.searching),
            .web_search_call_completed => builder.searching(.completed),
            else => {},
        }
    }

    fn searching(builder: *Builder, status: @FieldType(vocabulary.items.WebSearchCall, "status")) void {
        if (builder.item == .web_search_call) builder.item.web_search_call.status = status;
    }

    /// The item as its events built it.
    pub fn whole(builder: *const Builder, arena: Allocator) Allocator.Error!OutputItem {
        var item = builder.item;
        switch (item) {
            .output_message => |*message| if (builder.parts.items.len > 0 or message.content == .parts) {
                const parts = try arena.alloc(content.OutputContent, builder.parts.items.len);
                var count: usize = 0;
                for (builder.parts.items) |*part| if (try messagePart(arena, part)) |made| {
                    parts[count] = made;
                    count += 1;
                };
                message.content = .{ .parts = parts[0..count] };
            },
            .reasoning => |*reasoning| {
                if (builder.parts.items.len > 0) reasoning.content = try texts(content.ReasoningText, arena, builder.parts.items);
                if (builder.summary.items.len > 0) reasoning.summary = try texts(content.SummaryText, arena, builder.summary.items);
            },
            .function_call => |*call| call.arguments = try arena.dupe(u8, builder.text.items),
            .custom_tool_call => |*call| call.input = try arena.dupe(u8, builder.text.items),
            else => {},
        }
        return item;
    }
};

/// `item` ended before it was done, with what came of it: `incomplete`, or a web search `failed`, as its status has
/// no `incomplete`. An item without a status of its own is left as it came.
pub fn endedIncomplete(item: OutputItem) OutputItem {
    var ended = item;
    switch (ended) {
        .output_message => |*message| message.status = .incomplete,
        .function_call => |*call| call.status = .incomplete,
        .custom_tool_call => |*call| call.status = .incomplete,
        .reasoning => |*reasoning| reasoning.status = .incomplete,
        .tool_search_call => |*call| call.status = .incomplete,
        .tool_search_output => |*output| output.status = .incomplete,
        .openrouter_web_search => |*search| search.status = .incomplete,
        .openrouter_tool_search => |*search| search.status = .incomplete,
        .web_search_call => |*search| search.status = .failed,
        .compaction, .context_compaction, .armor_blocked => {},
    }
    return ended;
}

fn partOf(arena: Allocator, part: vocabulary.events.ContentPart) Allocator.Error!Part {
    var made: Part = .{ .part = part };
    switch (part) {
        .output_text => |text| {
            try made.text.appendSlice(arena, text.text);
            try made.annotations.appendSlice(arena, text.annotations orelse &.{});
        },
        .refusal => |refusal| try made.text.appendSlice(arena, refusal.refusal),
        .reasoning_text => |text| try made.text.appendSlice(arena, text.text),
        .output_image => {},
    }
    return made;
}

/// Sets the part at `index`, or adds it at the end; an index past the end changes nothing.
fn place(arena: Allocator, parts: *std.ArrayList(Part), index: u32, part: vocabulary.events.ContentPart) Allocator.Error!void {
    if (index > parts.items.len) return;
    const made = try partOf(arena, part);
    if (index == parts.items.len) return parts.append(arena, made);
    parts.items[index] = made;
}

/// The part at `index`, where it is of `kind`.
fn at(parts: *std.ArrayList(Part), index: u32, kind: std.meta.Tag(vocabulary.events.ContentPart)) ?*Part {
    if (index >= parts.items.len) return null;
    const part = &parts.items[index];
    return if (part.part == kind) part else null;
}

fn replace(arena: Allocator, text: *std.ArrayList(u8), whole_text: []const u8) Allocator.Error!void {
    text.clearRetainingCapacity();
    try text.appendSlice(arena, whole_text);
}

/// A message's part as its events built it; null for a reasoning text, which a message does not hold.
fn messagePart(arena: Allocator, part: *const Part) Allocator.Error!?content.OutputContent {
    return switch (part.part) {
        .output_text => |text| .{ .output_text = .{
            .text = try arena.dupe(u8, part.text.items),
            .annotations = if (part.annotations.items.len > 0 or text.annotations != null) try arena.dupe(content.Annotation, part.annotations.items) else null,
            .logprobs = text.logprobs,
        } },
        .refusal => .{ .refusal = .{ .refusal = try arena.dupe(u8, part.text.items) } },
        .output_image => |image| .{ .output_image = image },
        .reasoning_text => null,
    };
}

fn texts(comptime T: type, arena: Allocator, parts: []const Part) Allocator.Error![]const T {
    const made = try arena.alloc(T, parts.len);
    for (parts, made) |part, *text| text.* = .{ .text = try arena.dupe(u8, part.text.items) };
    return made;
}

test "an item's text grows with its deltas and is made whole on asking" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var builder: Builder = try .init(a, .{ .output_message = .{ .id = "m", .content = .{ .parts = &.{} } } }, true);
    try builder.apply(a, .{ .content_part_added = .{ .item_id = "m", .output_index = 0, .sequence_number = 1, .content_index = 0, .part = .{ .output_text = .{ .text = "" } } } });
    try builder.apply(a, .{ .output_text_delta = .{ .item_id = "m", .output_index = 0, .sequence_number = 2, .content_index = 0, .delta = "hel", .logprobs = &.{} } });
    try builder.apply(a, .{ .output_text_delta = .{ .item_id = "m", .output_index = 0, .sequence_number = 3, .content_index = 0, .delta = "lo", .logprobs = &.{} } });
    // A delta of a part past the end changes nothing.
    try builder.apply(a, .{ .output_text_delta = .{ .item_id = "m", .output_index = 0, .sequence_number = 4, .content_index = 3, .delta = "x", .logprobs = &.{} } });
    const made = endedIncomplete(try builder.whole(a));
    try std.testing.expectEqualStrings("hello", made.output_message.content.parts[0].output_text.text);
    try std.testing.expectEqual(.incomplete, made.output_message.status.?);
}

test "a call's arguments and a reasoning summary grow in place" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var call: Builder = try .init(a, .{ .function_call = .{ .call_id = "c", .name = "read", .arguments = "" } }, true);
    try call.apply(a, .{ .function_call_arguments_delta = .{ .item_id = "f", .output_index = 1, .sequence_number = 0, .delta = "{\"a\"" } });
    try call.apply(a, .{ .function_call_arguments_delta = .{ .item_id = "f", .output_index = 1, .sequence_number = 1, .delta = ":1}" } });
    try std.testing.expectEqualStrings("{\"a\":1}", (try call.whole(a)).function_call.arguments);
    var reasoning: Builder = try .init(a, .{ .reasoning = .{ .id = "r", .summary = &.{} } }, true);
    try reasoning.apply(a, .{ .summary_part_added = .{ .item_id = "r", .output_index = 0, .sequence_number = 0, .summary_index = 0, .part = .{ .text = "" } } });
    try reasoning.apply(a, .{ .summary_text_delta = .{ .item_id = "r", .output_index = 0, .sequence_number = 1, .summary_index = 0, .delta = "why" } });
    try std.testing.expectEqualStrings("why", (try reasoning.whole(a)).reasoning.summary.?[0].text);
}
