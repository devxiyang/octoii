//! `anthropic`: Anthropic's Messages API, reached with an API key, as a stream. A request goes in Anthropic's form;
//! its events come back as the vocabulary's, its failures classified by their error's type. An answer Anthropic pauses
//! is asked to go on from what it wrote so far, and its pieces make one response.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const Event = vocabulary.ResponseStreamEvent;
const seam = @import("../driver.zig");
const Error = @import("../failure.zig").Error;
const Model = @import("../catalogue/model.zig").Model;
const http = @import("../wire/http.zig");
const json = @import("../wire/json.zig");
const wire = @import("anthropic/wire.zig");
const request_ = @import("anthropic/request.zig");
const stream = @import("anthropic/stream.zig");

/// Where Anthropic's API is.
pub const base_url = "https://api.anthropic.com/v1";

pub const driver: seam.Driver = .{ .id = "anthropic", .name = "Anthropic", .catalogue = "anthropic", .text = text };

/// The request as it goes to Anthropic for `model`, and the betas it needs; for tests that read it.
pub const build = request_.build;

fn text(call: *seam.Call, model: *const Model, request: *const vocabulary.ResponsesRequest) Error!seam.TextSource {
    const built = try request_.build(call, model, request.*);
    const key = try call.apiKey();
    var headers: std.ArrayList(foundation.http.Header) = .empty;
    try headers.appendSlice(call.arena, &.{
        .{ .name = "x-api-key", .value = key },
        .{ .name = "anthropic-version", .value = wire.api_version },
        .{ .name = "accept", .value = "text/event-stream" },
        .{ .name = "content-type", .value = "application/json" },
    });
    if (built.betas.len > 0) try headers.append(call.arena, .{ .name = "anthropic-beta", .value = try std.mem.join(call.arena, ",", built.betas) });
    const source = try call.arena.create(Source);
    source.* = .{
        .call = call,
        .request = built.request,
        .options = try json.ownOptions(call.arena, request, "anthropic"),
        .headers = headers.items,
        .translator = try .init(call, request),
    };
    try source.send();
    return .{ .context = source, .vtable = &.{ .next = Source.next, .close = Source.close } };
}

/// The events of one response, each piece of a paused answer asked for in turn.
const Source = struct {
    call: *seam.Call,
    request: wire.Request,
    /// The request's own settings for Anthropic, set over its body.
    options: ?std.json.ObjectMap,
    headers: []const foundation.http.Header,
    translator: stream.Translator,
    events: ?http.Events = null,
    pending: std.ArrayList(Event) = .empty,
    head: usize = 0,

    /// Sends the request, as it stands now.
    fn send(source: *Source) Error!void {
        const call = source.call;
        const body = foundation.json.merged(.{ source.request, source.options });
        const response = try http.send(call, .{
            .method = .POST,
            .url = try std.fmt.allocPrint(call.arena, "{s}/messages", .{call.baseUrl(base_url)}),
            .headers = source.headers,
            .body = try foundation.json.encode(call.arena, body),
        });
        if (response.status < 200 or response.status >= 300) return call.fail(try http.failureOf(call, response, details));
        source.events = .init(call, response);
    }

    fn next(context: *anyopaque) Error!?Event {
        const source: *Source = @ptrCast(@alignCast(context));
        while (source.head == source.pending.items.len) {
            source.pending.clearRetainingCapacity();
            source.head = 0;
            const events = &(source.events orelse return null);
            if (try events.next()) |event| {
                try source.translator.translate(try source.call.arena.dupe(u8, event.data), &source.pending);
                continue;
            }
            events.close();
            source.events = null;
            if (source.translator.ending != .paused) return null;
            try source.goOn();
        }
        defer source.head += 1;
        return source.pending.items[source.head];
    }

    /// Asks the model to go on from the answer so far, the last assistant message of the request.
    fn goOn(source: *Source) Error!void {
        const arena = source.call.arena;
        const so_far = source.translator.sent.items;
        const blocks = try arena.alloc(wire.Block, so_far.len);
        for (so_far, blocks) |block, *each| each.* = .{ .raw = .{ .text = try foundation.json.encode(arena, block.*) } };
        var messages: std.ArrayList(wire.Message) = .empty;
        try messages.appendSlice(arena, source.request.messages);
        try messages.append(arena, .{ .role = .assistant, .content = blocks });
        source.request.messages = messages.items;
        source.translator.nextPiece();
        try source.send();
    }

    fn close(context: *anyopaque) void {
        const source: *Source = @ptrCast(@alignCast(context));
        if (source.events) |*events| events.close();
        source.events = null;
    }
};

/// What Anthropic's body says of a refusal before the stream: its kind by its error's type, its message and its code.
fn details(arena: Allocator, body: []const u8) ?http.Details {
    const parsed = foundation.json.decode(struct { type: []const u8, @"error": wire.Error }, arena, body) catch return null;
    if (!std.mem.eql(u8, parsed.type, "error")) return null;
    return .{ .kind = stream.kindOf(parsed.@"error"), .message = parsed.@"error".message, .code = parsed.@"error".type };
}
