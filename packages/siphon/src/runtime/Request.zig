//! A request in hand: what a fiber asked the outside, acted on by the handler of its name in a task of the runtime's,
//! once the commit that made it returned, and answered back to the fiber as mail of the request's key, once, committed
//! as it is sent. A stop cuts its task off as a signal is sent, and its handler answers at once with what has come. A
//! handler cancelled with nothing to give, or one that failed, is answered for, so every request has its answer.
const Request = @This();

const std = @import("std");
const foundation = @import("foundation");
const Allocator = std.mem.Allocator;
const beak = @import("../beak.zig");
const h = beak.h;
const Runtime = @import("Runtime.zig");
const Changes = @import("Changes.zig");
const Task = @import("Task.zig");

const log = std.log.scoped(.siphon);

runtime: *Runtime,
/// What the request holds, freed with it once its task is done.
arena_allocator: std.heap.ArenaAllocator,
/// The fiber that asked: its process's path, and the commit that started that process, which the answer names.
process: []const u8,
started: u64,
key: []const u8,
name: []const u8,
payload: []const u8,
handler: Handler,
/// Whether the fiber has its answer.
answered: bool = false,
/// Whether the handler published to the request's stream, which its task's end then ends.
published: bool = false,
/// The task acting on the request, whose waits the handler sleeps on.
task: Task,

/// What acts on requests of one name: given each, in its task, it answers it.
pub const Handler = struct {
    context: ?*anyopaque = null,
    act: *const fn (context: ?*anyopaque, request: *Request) anyerror!void,
};

/// The name of the mail that carries what a handler gave.
pub const answered_name = "answered";
/// The name of the mail that says a handler failed: its payload the failure.
pub const failed_name = "failed";
/// The name of the mail that says a request was cut off with nothing to give — by a stop, or by the host's end, after
/// which its handler may have acted — for the fiber that asked to decide.
pub const interrupted_name = "interrupted";

/// The request the event `made` tells of, arena in an arena of its own.
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
        .task = .{ .runtime = runtime },
    };
    request.arena_allocator = arena_allocator;
    return request;
}

/// Frees the request, its task done.
pub fn deinit(request: *Request) void {
    request.task.deinit();
    var arena_allocator = request.arena_allocator;
    arena_allocator.deinit();
}

/// Memory that lasts as long as the request.
pub fn arena(request: *Request) Allocator {
    return request.arena_allocator.allocator();
}

/// Answers the request with `value`, as JSON: its fiber has it once this returns. A request has one answer.
pub fn answer(request: *Request, value: anytype) !void {
    try request.settle(answered_name, try foundation.json.encode(request.arena(), value));
}

/// Publishes `data` on `topic` to the request's stream, from its task: what streams while it is answered.
pub fn publish(request: *Request, topic: []const u8, data: []const u8) Allocator.Error!void {
    try request.runtime.publish(topic, request.key, data);
    request.published = true;
}

/// Answers the request as failed, `failure` saying why, for the fiber that asked to read.
pub fn fail(request: *Request, failure: []const u8) !void {
    return request.settle(failed_name, failure);
}

/// Acts on the request, in its task: its handler answers it, or the answer says why it could not; then its stream ends.
pub fn run(request: *Request) void {
    defer if (request.published) request.runtime.endStream(request.key) catch |err| {
        log.warn("the stream of the request {s} is kept till the runtime closes: {s}", .{ request.key, @errorName(err) });
    };
    request.handler.act(request.handler.context, request) catch |err| {
        if (!request.answered) request.answerFor(err);
        return;
    };
    if (!request.answered) request.answerFor(error.NoAnswer);
}

/// Answers for a handler that gave no answer: cancelled, as cut off with nothing to give; else as failed with `err`.
fn answerFor(request: *Request, err: anyerror) void {
    const settled = switch (err) {
        error.Canceled => request.settle(interrupted_name, ""),
        else => request.settle(failed_name, @errorName(err)),
    };
    settled catch |failure| switch (failure) {
        error.Closing => {},
        else => log.warn("the request {s} of {s} went unanswered: {s}", .{ request.key, request.process, @errorName(failure) }),
    };
}

/// Sends the fiber the mail of the request's key, `name` with `payload`, committed as it returns.
fn settle(request: *Request, name: []const u8, payload: []const u8) !void {
    if (request.answered) return error.AlreadyAnswered;
    if (request.runtime.closing.load(.acquire)) return error.Closing;
    var changes: Changes = .{ .arena = request.arena() };
    try changes.answer(request.process, request.started, request.key, name, payload);
    _ = try request.runtime.volume.commit(request.runtime.now(), changes.items());
    request.answered = true;
}
