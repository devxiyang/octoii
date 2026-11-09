//! A provider's answer as a driver's source of the vocabulary's events: a stream of server-sent events, each event's
//! data translated by the protocol into none, one or more events, and `[DONE]`, which some providers end with, passed
//! over; or events made whole at once, from an answer that does not stream.
const std = @import("std");
const foundation = @import("foundation");
const driver = @import("../driver.zig");
const Error = @import("../failure.zig").Error;
const http = @import("http.zig");

/// Translates one event's data into the events of the vocabulary it stands for, appended to `out`.
pub fn Translate(comptime Event: type) type {
    return *const fn (call: *driver.Call, data: []const u8, out: *std.ArrayList(Event)) Error!void;
}

/// The source of `response`'s events as `translate` reads them.
pub fn of(comptime Event: type, call: *driver.Call, response: foundation.http.Response, translate: Translate(Event)) error{OutOfMemory}!driver.Source(Event) {
    const Source = Sse(Event);
    const source = try call.arena.create(Source);
    source.* = .{ .call = call, .events = .init(call, response), .translate = translate };
    return .{ .context = source, .vtable = &.{ .next = Source.next, .close = Source.close } };
}

fn Sse(comptime Event: type) type {
    return struct {
        call: *driver.Call,
        events: http.Events,
        translate: Translate(Event),
        pending: std.ArrayList(Event) = .empty,
        head: usize = 0,

        fn next(context: *anyopaque) Error!?Event {
            const source: *@This() = @ptrCast(@alignCast(context));
            while (source.head == source.pending.items.len) {
                source.pending.clearRetainingCapacity();
                source.head = 0;
                const event = try source.events.next() orelse return null;
                if (std.mem.eql(u8, event.data, "[DONE]")) continue;
                // The data lives until the next read; what is translated from it keeps its own copy.
                try source.translate(source.call, try source.call.arena.dupe(u8, event.data), &source.pending);
            }
            defer source.head += 1;
            return source.pending.items[source.head];
        }

        fn close(context: *anyopaque) void {
            const source: *@This() = @ptrCast(@alignCast(context));
            source.events.close();
        }
    };
}

/// The source of `events`, made whole at once.
pub fn listed(comptime Event: type, call: *driver.Call, events: []const Event) error{OutOfMemory}!driver.Source(Event) {
    const Source = struct {
        events: []const Event,
        head: usize = 0,

        fn next(context: *anyopaque) Error!?Event {
            const source: *@This() = @ptrCast(@alignCast(context));
            if (source.head == source.events.len) return null;
            defer source.head += 1;
            return source.events[source.head];
        }

        fn close(_: *anyopaque) void {}
    };
    const source = try call.arena.create(Source);
    source.* = .{ .events = events };
    return .{ .context = source, .vtable = &.{ .next = Source.next, .close = Source.close } };
}

/// The audio of a speech `response`, whose body is the audio's bytes, of `media_type`: a delta for each piece of them
/// as it arrives, then the end.
pub fn audio(call: *driver.Call, response: foundation.http.Response, media_type: []const u8) error{OutOfMemory}!driver.SpeechSource {
    const Event = @import("vocabulary").speech.SpeechStreamEvent;
    const Source = struct {
        call: *driver.Call,
        response: foundation.http.Response,
        media_type: []const u8,
        ended: bool = false,

        fn next(context: *anyopaque) Error!?Event {
            const source: *@This() = @ptrCast(@alignCast(context));
            if (source.ended) return null;
            // What one read brings is one piece of the audio, as it arrived.
            const body = source.response.body;
            const piece = body.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => {
                    source.ended = true;
                    return .{ .done = .{} };
                },
                error.ReadFailed => return http.readFailure(source.call, source.response),
            };
            const encoder = std.base64.standard.Encoder;
            const data = try source.call.arena.alloc(u8, encoder.calcSize(piece.len));
            const encoded = encoder.encode(data, piece);
            body.toss(piece.len);
            return .{ .delta = .{ .audio = encoded, .octoii = .{ .media_type = source.media_type } } };
        }

        fn close(context: *anyopaque) void {
            const source: *@This() = @ptrCast(@alignCast(context));
            source.response.close();
        }
    };
    const source = try call.arena.create(Source);
    source.* = .{ .call = call, .response = response, .media_type = media_type };
    return .{ .context = source, .vtable = &.{ .next = Source.next, .close = Source.close } };
}

/// What a speech response's audio is: as its `Content-Type` says, else `asked`; PCM at the rate its type names, else
/// `rate_hz`.
pub fn audioMediaType(arena: std.mem.Allocator, content_type: ?[]const u8, asked: []const u8, rate_hz: u32) error{OutOfMemory}![]const u8 {
    const given = content_type orelse "";
    const bare = std.mem.trim(u8, given[0 .. std.mem.indexOfScalar(u8, given, ';') orelse given.len], " ");
    const served = if (bare.len == 0 or std.ascii.eqlIgnoreCase(bare, "application/octet-stream")) asked else try std.ascii.allocLowerString(arena, bare);
    if (!std.mem.eql(u8, served, "audio/pcm")) return served;
    const lowered = try std.ascii.allocLowerString(arena, given);
    const after = if (std.mem.indexOf(u8, lowered, "rate=")) |found| given[found + "rate=".len ..] else "";
    const rate = after[0 .. std.mem.indexOfNone(u8, after, "0123456789") orelse after.len];
    if (rate.len > 0) return arena.print("audio/pcm;rate={s}", .{rate});
    return arena.print("audio/pcm;rate={d}", .{rate_hz});
}
