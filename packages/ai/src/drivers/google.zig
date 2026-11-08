//! `google`: Google's Gemini API, reached with an API key, through its Interactions API. A text request goes as the
//! interaction `request.zig` makes of it, with Google's own options set over it and kept nowhere; its steps come back
//! as the vocabulary's items, as `stream.zig` reads them.
const std = @import("std");
const vocabulary = @import("vocabulary");
const Event = vocabulary.ResponseStreamEvent;
const seam = @import("../driver.zig");
const Call = seam.Call;
const Error = @import("../failure.zig").Error;
const Model = @import("../catalogue/model.zig").Model;
const check = @import("../text/check.zig");
const json = @import("../wire/json.zig");
pub const interactions = @import("google/interactions.zig");
pub const request = @import("google/request.zig");
const stream = @import("google/stream.zig");

pub const base_url = interactions.base_url;

pub const driver: seam.Driver = .{ .id = "google", .name = "Google", .catalogue = "google", .text = text, .image = @import("google/images.zig").make, .speech = @import("google/speech.zig").speak };

/// The body a text request goes to Google with for `model`; for tests that read it.
pub fn wireRequest(call: *Call, model: *const Model, given: *const vocabulary.ResponsesRequest) Error![]const u8 {
    const made = try request.interaction(call, model, given);
    return interactions.requestBody(call.arena, made, try json.ownOptions(call.arena, given, "google"));
}

fn text(call: *Call, model: *const Model, given: *const vocabulary.ResponsesRequest) Error!seam.TextSource {
    try check.parts(call, model, given, &.{.image_output});
    const body = try wireRequest(call, model, given);
    const source = try call.arena.create(Source);
    source.* = .{ .reader = try .open(call, body), .answer = .{ .call = call, .model = model } };
    return .{ .context = source, .vtable = &.{ .next = Source.next, .close = Source.close } };
}

const Source = struct {
    reader: interactions.Reader,
    answer: stream.Answer,
    pending: std.ArrayList(Event) = .empty,
    head: usize = 0,

    fn next(context: *anyopaque) Error!?Event {
        const source: *Source = @ptrCast(@alignCast(context));
        while (source.head == source.pending.items.len) {
            source.pending.clearRetainingCapacity();
            source.head = 0;
            const event = try source.reader.next() orelse return null;
            try source.answer.event(event, &source.pending);
        }
        defer source.head += 1;
        return source.pending.items[source.head];
    }

    fn close(context: *anyopaque) void {
        const source: *Source = @ptrCast(@alignCast(context));
        source.reader.close();
    }
};
