//! A text request's stream, made whole and safe. Its first read sends the request: the model found, the request
//! checked against it and prepared for it, the driver's stream begun. Then each event of the provider's is numbered
//! from 0 without a gap and stamped with the model that wrote it; the calls of a response get unique `call_id`s, one
//! empty or another call's given a new one from the host's mint — every other id the provider gave is carried as it
//! came, as its data, which a provider takes back only as its own. A response that ends, whatever its status, ends every item it began and
//! carries each in its output. A provider that fails, stops early or sends an error has every item it began ended,
//! then `error` and `response.failed` carrying the failure, the output begun and the usage reported. Nothing follows
//! the last event. The stream never fails but for memory; what it gives lives in its arena.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vocabulary = @import("vocabulary");
const Event = vocabulary.ResponseStreamEvent;
const Response = vocabulary.Response;
const OutputItem = vocabulary.OutputItem;
const ErrorEvent = vocabulary.events.ErrorEvent;
const ResponseError = vocabulary.response.ResponseError;
const driver = @import("../driver.zig");
const Failure = @import("../failure.zig").Failure;
const Models = @import("../Models.zig");
const Builder = @import("items.zig").Builder;
const endedIncomplete = @import("items.zig").endedIncomplete;
const check = @import("check.zig");
const prepare = @import("prepare.zig");
const pricing = @import("../catalogue/pricing.zig");

/// How long a response may take to begin.
pub const start_timeout_ms = 5 * std.time.ms_per_min;

/// How long a response may fall silent, as a model may reason that long without a word.
pub const idle_timeout_ms = 15 * std.time.ms_per_min;

pub const TextStream = struct {
    models: *Models,
    arena: Allocator,
    request: vocabulary.ResponsesRequest,
    call: driver.Call,
    state: enum { unsent, streaming, finished } = .unsent,
    source: ?driver.TextSource = null,
    /// Events numbered and ready to give, from `head`.
    ready: std.ArrayList(Event) = .empty,
    head: usize = 0,
    /// Each item the stream added, by its index in the output.
    items: std.AutoArrayHashMapUnmanaged(u32, Builder) = .empty,
    /// The `call_id` each call of the response goes by, by its index in the output.
    call_ids: std.AutoArrayHashMapUnmanaged(u32, []const u8) = .empty,
    /// The response as the provider last sent it before it ended.
    latest: ?Response = null,
    /// An `error` the provider sent, which ends the response with the failed response that may follow it.
    held: ?ErrorEvent = null,
    sequence: u64 = 0,
    /// The last event's response, once the stream ended.
    last: ?Response = null,
    /// The model the request was sent to, and when, which price a response its provider gave no cost for.
    model: ?*const @import("../catalogue/model.zig").Model = null,
    sent_at_ms: i64 = 0,

    pub fn init(models: *Models, arena: Allocator, request: vocabulary.ResponsesRequest) TextStream {
        return .{
            .models = models,
            .arena = arena,
            .request = request,
            .call = .{ .arena = arena, .provider = undefined, .host = &models.host, .wait = .{ .head_ms = start_timeout_ms, .idle_ms = idle_timeout_ms } },
        };
    }

    /// The next event, or null once the last was given.
    pub fn next(stream: *TextStream) Allocator.Error!?Event {
        while (stream.head == stream.ready.items.len) {
            if (stream.state == .finished) return null;
            try stream.pull();
        }
        defer stream.head += 1;
        return stream.ready.items[stream.head];
    }

    /// The response the last event carried; null before it.
    pub fn response(stream: *const TextStream) ?Response {
        return stream.last;
    }

    /// Lets the provider's stream go, read to its end or not.
    pub fn close(stream: *TextStream) void {
        stream.stopSource();
        stream.state = .finished;
    }

    fn pull(stream: *TextStream) Allocator.Error!void {
        if (stream.state == .unsent) return stream.send() catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Failed => stream.fail(stream.call.failure.?),
        };
        const given = stream.source.?.next() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Failed => return stream.fail(stream.call.failure.?),
        };
        if (given) |event| return stream.accept(event);
        // An error the provider sent is its failure, whatever came after it.
        if (stream.held) |held| return stream.fail(Failure.ofError(held.code, held.message, held.octoii));
        return stream.fail(.init(.transport, "The response ended before it was whole"));
    }

    /// Sends the request: its model found, the request checked and prepared for it, the driver's stream begun.
    fn send(stream: *TextStream) @import("../failure.zig").Error!void {
        const call = &stream.call;
        const served = try stream.models.served(call, stream.request.model, .text);
        call.provider = served.provider;
        const text = served.provider.driver.text orelse return call.failWith(.invalid_request, "The provider {s} serves no text requests", .{served.provider.id});
        const model = try stream.arena.create(@import("../catalogue/model.zig").Model);
        model.* = served.model;
        stream.model = model;
        stream.sent_at_ms = call.nowMs();
        try check.request(call, model, &stream.request);
        const prepared = try stream.arena.create(vocabulary.ResponsesRequest);
        prepared.* = try prepare.request(call, model, stream.request, .{ .models = stream.models, .provider = served.provider, .reference = stream.request.model });
        try check.inputLimits(call, model, prepared);
        stream.source = try text(call, model, prepared);
        stream.state = .streaming;
    }

    /// Takes the provider's event: numbered, stamped and given, or ending the response.
    fn accept(stream: *TextStream, event: Event) Allocator.Error!void {
        if (stream.held) |held| {
            // An error ends the response: only the failed response may follow it.
            if (event == .failed) return stream.endFailed(event.failed.response, held);
            return stream.fail(Failure.ofError(held.code, held.message, held.octoii));
        }
        switch (event) {
            .@"error" => |given| stream.held = given,
            inline .completed, .incomplete => |given, tag| {
                try stream.endOpenItems();
                var ended = given;
                ended.response = try stream.final(given.response, try stream.withItemsBegun(given.response.output));
                try stream.emit(@unionInit(Event, @tagName(tag), ended));
                stream.finish(ended.response);
            },
            .failed => |given| try stream.endFailed(given.response, null),
            inline .created, .in_progress => |given, tag| {
                stream.latest = given.response;
                var marked = given;
                marked.response = try stream.stamped(given.response);
                try stream.emit(@unionInit(Event, @tagName(tag), marked));
            },
            inline .output_item_added, .output_item_done => |given, tag| {
                var placed = given;
                placed.item = try stream.withUniqueCallId(given.output_index, try stream.stampedItem(given.item));
                const builder: Builder = try .init(stream.arena, placed.item, tag == .output_item_added);
                try stream.items.put(stream.arena, given.output_index, builder);
                try stream.emit(@unionInit(Event, @tagName(tag), placed));
            },
            else => {
                try stream.follow(event);
                try stream.emit(event);
            },
        }
    }

    /// Applies an event of an open item to what its events built.
    fn follow(stream: *TextStream, event: Event) Allocator.Error!void {
        const index = switch (event) {
            inline else => |given| if (@hasField(@TypeOf(given), "output_index")) given.output_index else return,
        };
        const builder = stream.items.getPtr(index) orelse return;
        if (builder.open) try builder.apply(stream.arena, event);
    }

    /// Ends the stream with the provider's failed response, every open item ended and carried in its output, after
    /// the `error` it sent or one made of the response's error.
    fn endFailed(stream: *TextStream, given: Response, held: ?ErrorEvent) Allocator.Error!void {
        try stream.endOpenItems();
        const failed_error: ResponseError = given.@"error" orelse if (held) |event|
            .{ .code = event.code, .message = event.message, .octoii = event.octoii }
        else
            Failure.init(.invalid_response, "The response failed without saying why").responseError();
        var failed = given;
        failed.status = .failed;
        failed.@"error" = failed_error;
        failed = try stream.final(failed, try stream.withItemsBegun(given.output));
        try stream.emit(.{ .@"error" = held orelse errorEvent(failed_error, null) });
        try stream.emit(.{ .failed = .{ .response = failed, .sequence_number = 0 } });
        stream.finish(failed);
    }

    /// Ends the stream with `failure`: every open item ended, then `error`, then the failed response with what came
    /// before — but where its caller cut it off, an answer cut short, not one that failed.
    fn fail(stream: *TextStream, failure: Failure) Allocator.Error!void {
        if (failure.kind == .aborted) return stream.endCancelled();
        try stream.endOpenItems();
        const failed_error = failure.responseError();
        var failed: Response = stream.latest orelse .{ .id = try stream.newId(), .status = .failed, .output = &.{} };
        failed.status = .failed;
        failed.incomplete_details = null;
        failed.@"error" = failed_error;
        failed = try stream.final(failed, try stream.withItemsBegun(&.{}));
        try stream.emit(.{ .@"error" = errorEvent(failed_error, if (stream.held) |held| held.param else null) });
        try stream.emit(.{ .failed = .{ .response = failed, .sequence_number = 0 } });
        stream.finish(failed);
    }

    /// Ends the stream its caller cut off: every open item ended, then the response as it stood — what came of it —
    /// incomplete, for its caller cancelled it, with no error.
    fn endCancelled(stream: *TextStream) Allocator.Error!void {
        try stream.endOpenItems();
        var cut: Response = stream.latest orelse .{ .id = try stream.newId(), .status = .incomplete, .output = &.{} };
        cut.status = .incomplete;
        cut.incomplete_details = .{ .reason = .cancelled };
        cut.@"error" = null;
        cut = try stream.final(cut, try stream.withItemsBegun(&.{}));
        try stream.emit(.{ .incomplete = .{ .response = cut, .sequence_number = 0 } });
        stream.finish(cut);
    }

    /// Ends every item still open, in the order of the output, with what came of it.
    fn endOpenItems(stream: *TextStream) Allocator.Error!void {
        for (try stream.indexes()) |index| {
            const builder = stream.items.getPtr(index).?;
            if (!builder.open) continue;
            const ended = endedIncomplete(try builder.whole(stream.arena));
            builder.* = try .init(stream.arena, ended, false);
            try stream.emit(.{ .output_item_done = .{ .item = ended, .output_index = index, .sequence_number = 0 } });
        }
    }

    /// `output` with each item the stream added at its index, as the stream last gave it; an item past the end of
    /// `output` follows it.
    fn withItemsBegun(stream: *TextStream, output: []const OutputItem) Allocator.Error![]const OutputItem {
        var merged: std.ArrayList(OutputItem) = .empty;
        try merged.appendSlice(stream.arena, output);
        for (try stream.indexes()) |index| {
            const item = try stream.items.getPtr(index).?.whole(stream.arena);
            if (index < merged.items.len) merged.items[index] = item else try merged.append(stream.arena, item);
        }
        return merged.items;
    }

    /// The indexes of the items the stream added, in order.
    fn indexes(stream: *TextStream) Allocator.Error![]const u32 {
        const sorted = try stream.arena.dupe(u32, stream.items.keys());
        std.mem.sort(u32, sorted, {}, std.sort.asc(u32));
        return sorted;
    }

    /// A last response: `output` its output, stamped, its calls' `call_id`s unique, and priced from the catalogue
    /// where its provider gave no cost.
    fn final(stream: *TextStream, given: Response, output: []const OutputItem) Allocator.Error!Response {
        var ended = given;
        ended.output = output;
        ended = try stream.stamped(ended);
        const items = try stream.arena.dupe(OutputItem, ended.output);
        for (items, 0..) |*item, index| item.* = try stream.withUniqueCallId(@intCast(index), item.*);
        ended.output = items;
        if (ended.usage) |usage| if (usage.cost == null) if (stream.model) |model| {
            const context_tokens = if (ended.octoii) |extension| extension.context_tokens else null;
            var priced = usage;
            priced.cost = pricing.cost(model, vocabulary.Usage.ofResponse(ended), .{ .context_tokens = context_tokens, .sent_at_ms = stream.sent_at_ms });
            ended.usage = priced;
        };
        return ended;
    }

    /// `given` and its output items stamped with the model's reference.
    fn stamped(stream: *TextStream, given: Response) Allocator.Error!Response {
        var marked = given;
        const items = try stream.arena.alloc(OutputItem, given.output.len);
        for (given.output, items) |item, *copy| copy.* = try stream.stampedItem(item);
        marked.output = items;
        var extension = given.octoii orelse vocabulary.extensions.ResponseExtension{};
        extension.model = stream.request.model;
        marked.octoii = extension;
        return marked;
    }

    /// `item` stamped with the reference of the model that wrote it.
    fn stampedItem(stream: *TextStream, item: OutputItem) Allocator.Error!OutputItem {
        var marked = item;
        switch (marked) {
            inline else => |*payload| {
                var extension = payload.octoii orelse vocabulary.extensions.ItemExtension{};
                extension.model = stream.request.model;
                payload.octoii = extension;
            },
        }
        return marked;
    }

    /// `item`, at `index` in the output, with the `call_id` its call goes by: the one it was first given, its own
    /// where no other call of the response has it and it is not empty, else `call_` and a new id.
    fn withUniqueCallId(stream: *TextStream, index: u32, item: OutputItem) Allocator.Error!OutputItem {
        var unique = item;
        switch (unique) {
            inline .function_call, .custom_tool_call => |*call| {
                call.call_id = stream.call_ids.get(index) orelse try stream.newCallId(index, call.call_id);
            },
            else => {},
        }
        return unique;
    }

    fn newCallId(stream: *TextStream, index: u32, asked: []const u8) Allocator.Error![]const u8 {
        const taken = asked.len == 0 or for (stream.call_ids.values()) |given| {
            if (std.mem.eql(u8, given, asked)) break true;
        } else false;
        const call_id = if (taken) try stream.newId() else asked;
        try stream.call_ids.put(stream.arena, index, call_id);
        return call_id;
    }

    /// A new id from the host's mint.
    fn newId(stream: *TextStream) Allocator.Error![]const u8 {
        return stream.models.host.newId(stream.arena);
    }

    /// Numbers `event` and makes it ready to give.
    fn emit(stream: *TextStream, event: Event) Allocator.Error!void {
        var numbered = event;
        switch (numbered) {
            inline else => |*payload| payload.sequence_number = stream.sequence,
        }
        stream.sequence += 1;
        try stream.ready.append(stream.arena, numbered);
    }

    /// Ends the stream with its last response, the provider's stream let go.
    fn finish(stream: *TextStream, last: Response) void {
        stream.last = last;
        stream.state = .finished;
        stream.stopSource();
    }

    fn stopSource(stream: *TextStream) void {
        if (stream.source) |source| source.close();
        stream.source = null;
    }
};

/// The `error` event of a response's error.
fn errorEvent(given: ResponseError, param: ?[]const u8) ErrorEvent {
    return .{ .code = given.code, .message = given.message, .param = param, .octoii = given.octoii, .sequence_number = 0 };
}
