//! A request in hand: what a fiber asked the outside, acted on by the handler of its name as a job of the runtime's —
//! in a task of its own, once the commit that made it returned — and answered back to the fiber as mail of the
//! request's key, once: the handler gives its answer in its task, and the loop commits it as the job finishes, as Redis
//! replies on its main thread to a client its module unblocked. A stop cuts its task off as a signal is sent, and its
//! handler answers at once with what has come. A handler cancelled with nothing to give, or one that failed, is answered
//! for, so every request has its answer; one the runtime closes on is dropped unanswered, and comes back to its fiber
//! interrupted as the volume opens again, as though the host had ended.
const Request = @This();

const std = @import("std");
const foundation = @import("foundation");
const Allocator = std.mem.Allocator;
const beak = @import("../beak.zig");
const h = beak.h;
const Runtime = @import("Runtime.zig");
const Changes = @import("Changes.zig");
const Waits = @import("Waits.zig");

const log = std.log.scoped(.siphon);

runtime: *Runtime,
/// What the request holds, freed with it once its job is done.
arena_allocator: std.heap.ArenaAllocator,
/// The fiber that asked: its process's path, and the commit that started that process, which the answer names.
process: []const u8,
started: u64,
key: []const u8,
name: []const u8,
payload: []const u8,
handler: Handler,
/// What the handler's task sleeps on for news of what it starts, which a stop wakes: the job's, as it runs.
waits: *Waits = undefined,
/// The answer the handler gave, the mail's name and payload, which the loop commits as the job finishes.
given: ?Given = null,
/// Whether the handler published to the request's stream, which its task's end then ends.
published: bool = false,

/// What acts on requests of one name: given each, in its task, it answers it.
pub const Handler = struct {
    context: ?*anyopaque = null,
    act: *const fn (context: ?*anyopaque, request: *Request) anyerror!void,
};

/// An answer given: the name of the mail that carries it, and its payload.
const Given = struct { name: []const u8, payload: []const u8 };

/// The name of the mail that carries what a handler gave.
pub const answered_name = "answered";
/// The name of the mail that says a handler failed: its payload the failure.
pub const failed_name = "failed";
/// The name of the mail that says a request was cut off with nothing to give — by a stop, or by the host's end, after
/// which its handler may have acted — for the fiber that asked to decide.
pub const interrupted_name = "interrupted";

/// The request the event `made` tells of, held in an arena of its own.
pub fn init(runtime: *Runtime, made: *const h.beak_event, handler: Handler) Allocator.Error!*Request {
    var arena_allocator: std.heap.ArenaAllocator = .init(runtime.allocator);
    errdefer arena_allocator.deinit();
    const request_arena = arena_allocator.allocator();
    const request = try request_arena.create(Request);
    request.* = .{
        .runtime = runtime,
        .arena_allocator = undefined,
        .process = try request_arena.dupe(u8, beak.slice(made.process)),
        .started = made.started,
        .key = try request_arena.dupe(u8, beak.slice(made.key)),
        .name = try request_arena.dupe(u8, beak.slice(made.name)),
        .payload = try request_arena.dupe(u8, beak.slice(made.bytes)),
        .handler = handler,
    };
    request.arena_allocator = arena_allocator;
    return request;
}

/// Frees the request, its job done.
pub fn deinit(request: *Request) void {
    var arena_allocator = request.arena_allocator;
    arena_allocator.deinit();
}

/// The request as a job of the runtime's: acted on in its task, its answer committed by the loop as it finishes, or
/// dropped unanswered as the runtime closes.
pub fn job(request: *Request) Runtime.Job {
    return .{ .context = request, .run = run, .finish = finish, .drop = drop };
}

/// The request `given` is the job of; null for a job of another kind.
pub fn ofJob(given: Runtime.Job) ?*Request {
    if (given.run != run) return null;
    return @ptrCast(@alignCast(given.context));
}

/// Whether `given` is the job of the request of `key` the fiber at `process` made.
pub fn isJobOf(given: Runtime.Job, process: []const u8, key: []const u8) bool {
    const request = ofJob(given) orelse return false;
    return std.mem.eql(u8, request.process, process) and std.mem.eql(u8, request.key, key);
}

/// Memory that lasts as long as the request.
pub fn arena(request: *Request) Allocator {
    return request.arena_allocator.allocator();
}

/// Answers the request with `value`, as JSON: the loop commits it as the request's job finishes. A request has one
/// answer.
pub fn answer(request: *Request, value: anytype) !void {
    try request.give(answered_name, try foundation.json.encode(request.arena(), value));
}

/// Publishes `data` on `topic` to the request's stream, from its task: what streams while it is answered.
pub fn publish(request: *Request, topic: []const u8, data: []const u8) Allocator.Error!void {
    try request.runtime.publish(topic, request.key, data);
    request.published = true;
}

/// Answers the request as failed, `failure` saying why, for the fiber that asked to read.
pub fn fail(request: *Request, failure: []const u8) !void {
    return request.give(failed_name, failure);
}

/// Acts on the request, in its job's task: its handler answers it, or the answer says why it could not; then its stream
/// ends, after what was published on it.
fn run(context: *anyopaque, waits: *Waits) void {
    const request: *Request = @ptrCast(@alignCast(context));
    request.waits = waits;
    defer if (request.published) request.runtime.endStream(request.key) catch |err| {
        log.warn("the stream of the request {s} is kept till the runtime closes: {s}", .{ request.key, @errorName(err) });
    };
    request.handler.act(request.handler.context, request) catch |err| {
        if (request.given == null) request.answerFor(err);
        return;
    };
    if (request.given == null) request.answerFor(error.NoAnswer);
}

/// Answers for a handler that gave no answer: cancelled, as cut off with nothing to give; else as failed with `err`.
fn answerFor(request: *Request, err: anyerror) void {
    const given = switch (err) {
        error.Canceled => request.give(interrupted_name, ""),
        else => request.give(failed_name, @errorName(err)),
    };
    given catch |failure| log.warn("the request {s} of {s} went unanswered: {s}", .{ request.key, request.process, @errorName(failure) });
}

/// Keeps the answer, the mail of the request's key named `name` with `payload`, for the loop to commit.
fn give(request: *Request, name: []const u8, payload: []const u8) !void {
    if (request.given != null) return error.AlreadyAnswered;
    request.given = .{ .name = try request.arena().dupe(u8, name), .payload = try request.arena().dupe(u8, payload) };
}

/// Commits the answer the handler gave, on the loop, as the job finishes — durable as the commit returns — and frees the
/// request.
fn finish(context: *anyopaque) void {
    const request: *Request = @ptrCast(@alignCast(context));
    defer request.deinit();
    const given = request.given orelse return;
    var changes: Changes = .{ .arena = request.arena() };
    changes.answer(request.process, request.started, request.key, given.name, given.payload) catch |err| {
        return log.warn("the request {s} of {s} went unanswered: {s}", .{ request.key, request.process, @errorName(err) });
    };
    _ = request.runtime.commit(&changes) catch |err| {
        log.warn("the request {s} of {s} went unanswered: {s}", .{ request.key, request.process, @errorName(err) });
    };
}

/// Frees the request unanswered, as the runtime closes on it.
fn drop(context: *anyopaque) void {
    const request: *Request = @ptrCast(@alignCast(context));
    request.deinit();
}
