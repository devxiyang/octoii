//! A fake provider's driver for tests: it answers each text request with the next of its scripted streams — events in
//! the vocabulary, or a failure, after any events — and keeps every request it was sent, as prepared.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const Event = vocabulary.ResponseStreamEvent;
const driver = @import("../driver.zig");
const failure_ = @import("../failure.zig");
const Model = @import("../catalogue/model.zig").Model;

/// One scripted answer: the events the provider streams, then the failure it fails with, if any.
pub const Answer = struct {
    events: []const Event,
    failure: ?failure_.Failure = null,
};

pub const Fake = struct {
    allocator: Allocator,
    answers: []const Answer,
    next_answer: usize = 0,
    /// The requests sent, as prepared, in order, each a copy the fake holds.
    requests: std.ArrayList(vocabulary.ResponsesRequest) = .empty,
    driver: driver.Driver = .{ .id = "fake", .name = "Fake", .text = text },

    pub fn init(allocator: Allocator, answers: []const Answer) Fake {
        return .{ .allocator = allocator, .answers = answers };
    }

    /// The driver, its context this fake; it lives as long as the fake does, unmoved.
    pub fn bound(fake: *Fake) *const driver.Driver {
        fake.driver.context = fake;
        return &fake.driver;
    }

    fn text(call: *driver.Call, _: *const Model, request: *const vocabulary.ResponsesRequest) failure_.Error!driver.TextSource {
        const fake: *Fake = @ptrCast(@alignCast(call.provider.driver.context.?));
        try fake.requests.append(fake.allocator, try copied(fake.allocator, request.*));
        if (fake.next_answer == fake.answers.len) return call.failWith(.invalid_request, "The fake provider has no answer left", .{});
        const source = try call.arena.create(Source);
        source.* = .{ .call = call, .answer = fake.answers[fake.next_answer] };
        fake.next_answer += 1;
        return .{ .context = source, .vtable = &.{ .next = Source.next, .close = Source.close } };
    }

    pub fn deinit(fake: *Fake) void {
        fake.requests.deinit(fake.allocator);
    }

    /// `request`, held in `allocator` whatever the caller's memory does after: read back from its encoding.
    fn copied(allocator: Allocator, request: vocabulary.ResponsesRequest) Allocator.Error!vocabulary.ResponsesRequest {
        const encoded = try foundation.json.encode(allocator, request);
        return foundation.json.decode(vocabulary.ResponsesRequest, allocator, encoded) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            // What was just encoded reads back.
            else => unreachable,
        };
    }
};

const Source = struct {
    call: *driver.Call,
    answer: Answer,
    index: usize = 0,

    fn next(context: *anyopaque) failure_.Error!?Event {
        const source: *Source = @ptrCast(@alignCast(context));
        if (source.index == source.answer.events.len) {
            const failure = source.answer.failure orelse return null;
            return source.call.fail(failure);
        }
        defer source.index += 1;
        return source.answer.events[source.index];
    }

    fn close(_: *anyopaque) void {}
};
