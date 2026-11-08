//! A provider's media events made safe, as `Models` gives them. The first read sends the request, as its kind begins
//! it; then each event comes as the provider sent it, but for those that end a part of the stream, such as an image
//! made, which its kind finishes, pricing it. The stream ends with its kind's last event, or with the `error` of
//! whatever failed: a request that could not be sent, a provider that failed, sent an `error`, or stopped before its
//! last event. Nothing follows the end; the stream never fails but for memory.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vocabulary = @import("vocabulary");
const driver = @import("../driver.zig");
const failure_ = @import("../failure.zig");
const Failure = failure_.Failure;
const Error = failure_.Error;
const text_stream = @import("../text/stream.zig");

/// The stream of one request of `Kind`, which gives: `Event`, the union of the kind's events with its `error`; `last`,
/// the tag of the event a whole stream ends with; `begin`, which sends the request; and `finish`, which makes an event
/// what the caller is given.
pub fn Stream(comptime Kind: type) type {
    return struct {
        const Self = @This();
        pub const Event = Kind.Event;

        kind: Kind,
        call: driver.Call,
        state: enum { unsent, streaming, finished } = .unsent,
        source: ?driver.Source(Event) = null,
        /// Whether the last event the provider sent was the kind's last.
        whole: bool = false,
        /// The failure the stream ended with, where it ended with one.
        failure: ?Failure = null,

        pub fn init(kind: Kind, arena: Allocator, host: *const driver.Host) Self {
            return .{ .kind = kind, .call = .{ .arena = arena, .provider = undefined, .host = host, .wait = .{ .head_ms = text_stream.start_timeout_ms, .idle_ms = text_stream.idle_timeout_ms } } };
        }

        /// The next event, or null once the last was given.
        pub fn next(stream: *Self) Allocator.Error!?Event {
            switch (stream.state) {
                .finished => return null,
                .unsent => {
                    stream.source = Kind.begin(&stream.kind, &stream.call) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Failed => return stream.failed(stream.call.failure.?),
                    };
                    stream.state = .streaming;
                },
                .streaming => {},
            }
            const given = stream.source.?.next() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Failed => return stream.failed(stream.call.failure.?),
            };
            const event = given orelse {
                if (stream.whole) {
                    stream.end();
                    return null;
                }
                return stream.failed(.init(.transport, "The stream ended before it was whole"));
            };
            if (event == .@"error") {
                const raised = event.@"error".@"error";
                stream.failure = Failure.ofError(raised.code, raised.message, raised.octoii);
                stream.end();
                return event;
            }
            stream.whole = event == Kind.last;
            return try Kind.finish(&stream.kind, stream.call.arena, event);
        }

        /// Lets the provider's stream go, read to its end or not.
        pub fn close(stream: *Self) void {
            stream.end();
        }

        /// Ends the stream with `failure`: its `error` event.
        fn failed(stream: *Self, failure: Failure) Event {
            stream.failure = failure;
            stream.end();
            return .{ .@"error" = .{ .@"error" = .{ .code = failure.code orelse @tagName(failure.kind), .message = failure.message, .octoii = failure.extension() } } };
        }

        fn end(stream: *Self) void {
            stream.state = .finished;
            if (stream.source) |source| source.close();
            stream.source = null;
        }
    };
}

/// What a request of a kind that answers once came to: what it made, or the failure it ended with.
pub fn Outcome(comptime Made: type) type {
    return union(enum) { made: Made, failed: Failure };
}

/// Ends `outcome`'s failure with `kind` and `message`, in `arena`.
pub fn failedWith(comptime Made: type, arena: Allocator, kind: vocabulary.FailureKind, comptime message: []const u8, arguments: anytype) Allocator.Error!Outcome(Made) {
    return .{ .failed = try Failure.format(arena, kind, message, arguments) };
}
