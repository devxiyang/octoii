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
    return textAt(call, model, request, base_url, &.{.{ .name = "x-api-key", .value = try call.apiKey() }});
}

/// The events of `request` as a server of Anthropic's Messages API at `default_url` — unless its provider names
/// another — answers them, its requests sent with `given` besides the API's own headers: who asks, and what else the
/// server takes; for a driver whose server speaks Anthropic's API.
pub fn textAt(call: *seam.Call, model: *const Model, request: *const vocabulary.ResponsesRequest, default_url: []const u8, given: []const foundation.http.Header) Error!seam.TextSource {
    const built = try request_.build(call, model, request.*);
    var headers: std.ArrayList(foundation.http.Header) = .empty;
    try headers.appendSlice(call.arena, given);
    try headers.appendSlice(call.arena, &.{
        .{ .name = "anthropic-version", .value = wire.api_version },
        .{ .name = "accept", .value = "text/event-stream" },
        .{ .name = "content-type", .value = "application/json" },
    });
    if (built.betas.len > 0) try headers.append(call.arena, .{ .name = "anthropic-beta", .value = try std.mem.join(call.arena, ",", built.betas) });
    const source = try call.arena.create(Source);
    source.* = .{
        .call = call,
        .url = try call.arena.print("{s}/messages", .{call.baseUrl(default_url)}),
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
    /// Where its requests go.
    url: []const u8,
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
            .url = source.url,
            .headers = source.headers,
            .body = try foundation.json.encode(call.arena, body),
        });
        if (response.status < 200 or response.status >= 300) {
            const used_up = usedUp(response.headers);
            var failure = try http.failureOf(call, response, details);
            if (used_up) |limit| {
                failure.kind = .quota;
                failure.retryable = false;
                failure.reset_at_ms = limit.reset_at_ms orelse failure.reset_at_ms;
                failure.window_minutes = limit.window_minutes;
            }
            return call.fail(failure);
        }
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

/// A plan's limit used up, as Anthropic's unified limits tell of a request they refused: when it is given again, in
/// milliseconds since the epoch, and the minutes of the window of the limit it hit, each where they say.
const UsedUp = struct { reset_at_ms: ?i64, window_minutes: ?u32 };

/// The plan's limit a refused request used up, by its unified limits' headers; none where they say none was.
fn usedUp(headers: []const foundation.http.Header) ?UsedUp {
    const status = foundation.http.find(headers, "anthropic-ratelimit-unified-status") orelse return null;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, status, " "), "rejected")) return null;
    const reset = foundation.http.find(headers, "anthropic-ratelimit-unified-reset");
    const seconds = if (reset) |given| std.fmt.parseInt(i64, std.mem.trim(u8, given, " "), 10) catch null else null;
    const claim = foundation.http.find(headers, "anthropic-ratelimit-unified-representative-claim");
    return .{ .reset_at_ms = if (seconds) |at| at * std.time.ms_per_s else null, .window_minutes = if (claim) |name| windowMinutesOf(std.mem.trim(u8, name, " ")) else null };
}

/// The minutes of the window a unified limit's claim is counted over: five hours, or a week, whatever models it holds.
fn windowMinutesOf(claim: []const u8) ?u32 {
    if (std.mem.eql(u8, claim, "five_hour")) return 5 * 60;
    if (std.mem.startsWith(u8, claim, "seven_day")) return 7 * 24 * 60;
    return null;
}

/// What Anthropic's body says of a refusal before the stream: its kind by its error's type, its message and its code;
/// for a driver whose server speaks Anthropic's API.
pub fn details(arena: Allocator, body: []const u8) ?http.Details {
    const parsed = foundation.json.decode(struct { type: []const u8, @"error": wire.Error }, arena, body) catch return null;
    if (!std.mem.eql(u8, parsed.type, "error")) return null;
    return .{ .kind = stream.kindOf(parsed.@"error"), .message = parsed.@"error".message, .code = parsed.@"error".type };
}
