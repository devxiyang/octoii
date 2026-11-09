//! The invariants of a text stream, checked on any list of its events, which every driver's tests run on the streams
//! they translate: sequence numbers from 0 without a gap; each output item added once, streamed while open and done
//! once, at its position; each part of an item begun before its text streams and done once; one terminal event, last,
//! after an `error` where it failed, carrying the whole response.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vocabulary = @import("vocabulary");
const Event = vocabulary.ResponseStreamEvent;

/// Where a part stands as the events are read.
const PartState = enum { open, done };

/// Where an item stands as the events are read.
const ItemState = struct { added: std.meta.Tag(vocabulary.OutputItem), id: ?[]const u8, done: bool = false };

/// Every way `events` break the stream's invariants, one line each; none for a whole stream.
pub fn problems(arena: Allocator, events: []const Event) Allocator.Error![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    var items: std.AutoArrayHashMapUnmanaged(u32, ItemState) = .empty;
    var parts: std.StringHashMapUnmanaged(PartState) = .empty;
    for (events, 0..) |event, index| {
        const sequence = switch (event) {
            inline else => |given| given.sequence_number,
        };
        if (sequence != index) try found.append(arena, try arena.print("event {d} ({t}) has sequence_number {d}", .{ index, event, sequence }));
        const terminal = event == .completed or event == .incomplete or event == .failed;
        if (terminal and index != events.len - 1) try found.append(arena, try arena.print("event {d} ({t}) ends the response, and events follow it", .{ index, event }));
        if (event == .@"error" and (index + 2 != events.len or events[events.len - 1] != .failed)) {
            try found.append(arena, try arena.print("event {d} (error) does not come right before the response.failed that ends the stream", .{index}));
        }
        switch (event) {
            .output_item_added => |added| {
                const entry = try items.getOrPut(arena, added.output_index);
                if (entry.found_existing) {
                    try found.append(arena, try arena.print("event {d} adds output_index {d} a second time", .{ index, added.output_index }));
                } else entry.value_ptr.* = .{ .added = added.item, .id = idOf(added.item) };
            },
            .output_item_done => |done| {
                const state = items.getPtr(done.output_index) orelse {
                    try found.append(arena, try arena.print("event {d} ends output_index {d}, which was never added", .{ index, done.output_index }));
                    continue;
                };
                if (state.done) try found.append(arena, try arena.print("event {d} ends output_index {d} a second time", .{ index, done.output_index }));
                if (state.added != done.item) try found.append(arena, try arena.print("event {d} ends a {t} item as a {t}", .{ index, state.added, done.item }));
                state.done = true;
            },
            else => try itemEvent(arena, &found, &items, &parts, event, index),
        }
    }
    try end(arena, &found, &items, events);
    return found.items;
}

fn idOf(item: vocabulary.OutputItem) ?[]const u8 {
    return switch (item) {
        inline else => |given| given.id,
    };
}

/// Reads an event of an item: the item open, of the same id, and the event's part open where it belongs to one.
fn itemEvent(
    arena: Allocator,
    found: *std.ArrayList([]const u8),
    items: *std.AutoArrayHashMapUnmanaged(u32, ItemState),
    parts: *std.StringHashMapUnmanaged(PartState),
    event: Event,
    index: usize,
) Allocator.Error!void {
    switch (event) {
        inline else => |given| {
            const Given = @TypeOf(given);
            if (!@hasField(Given, "output_index") or !@hasField(Given, "item_id")) return;
            const state = items.get(given.output_index);
            if (state == null or state.?.done) {
                return found.append(arena, try arena.print("event {d} ({t}) streams output_index {d}, which is not open", .{ index, event, given.output_index }));
            }
            if (state.?.id) |id| if (!std.mem.eql(u8, id, given.item_id)) {
                try found.append(arena, try arena.print("event {d} names item {s}, and output_index {d} is {s}", .{ index, given.item_id, given.output_index, id }));
            };
            const kind: ?[]const u8 = if (@hasField(Given, "content_index")) "content" else if (@hasField(Given, "summary_index")) "summary" else null;
            const named = kind orelse return;
            const part_index = if (@hasField(Given, "content_index")) given.content_index else given.summary_index;
            const key = try arena.print("{d}/{s}/{d}", .{ given.output_index, named, part_index });
            const tag = @tagName(event);
            if (std.mem.endsWith(u8, tag, "_part_added")) {
                if (parts.contains(key)) try found.append(arena, try arena.print("event {d} begins part {s} a second time", .{ index, key }));
                try parts.put(arena, key, .open);
            } else if (std.mem.endsWith(u8, tag, "_part_done")) {
                if (parts.get(key) != .open) try found.append(arena, try arena.print("event {d} ends part {s}, which is not open", .{ index, key }));
                try parts.put(arena, key, .done);
            } else if (parts.get(key) != .open) {
                try found.append(arena, try arena.print("event {d} ({t}) streams part {s}, which is not open", .{ index, event, key }));
            }
        },
    }
}

/// Checks the end: one terminal event, after an `error` where it failed, every item done, the items without a gap.
fn end(arena: Allocator, found: *std.ArrayList([]const u8), items: *std.AutoArrayHashMapUnmanaged(u32, ItemState), events: []const Event) Allocator.Error!void {
    if (events.len == 0) return found.append(arena, "The stream has no events");
    const last = events[events.len - 1];
    const response = switch (last) {
        .completed => |given| given.response,
        .incomplete => |given| given.response,
        .failed => |given| given.response,
        else => return found.append(arena, "The stream does not end with response.completed, response.incomplete or response.failed"),
    };
    const status: vocabulary.response.ResponseStatus = switch (last) {
        .completed => .completed,
        .incomplete => .incomplete,
        else => .failed,
    };
    if (response.status != status) try found.append(arena, try arena.print("{t} carries a response whose status is {t}", .{ last, response.status }));
    if (last == .failed and (events.len < 2 or events[events.len - 2] != .@"error")) try found.append(arena, "response.failed does not follow an error");
    for (items.keys(), items.values()) |output_index, state| {
        if (!state.done) try found.append(arena, try arena.print("output_index {d} is never done", .{output_index}));
        if (output_index >= items.count()) try found.append(arena, try arena.print("output_index {d} leaves a gap", .{output_index}));
    }
}
