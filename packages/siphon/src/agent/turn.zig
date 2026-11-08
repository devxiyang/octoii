//! A thread's turn, as a fiber under its main fiber: it asks its model by a `model` request — a record of what to ask —
//! appends the reply once, whole, runs the calls the reply made at once, as a provider makes calls in one reply that do
//! not wait on each other, each a fiber of its own, their results appended in the order the model made them, and asks
//! again, until a reply calls nothing; what the person sent while the calls ran taken in after their results, so it
//! steers the turn at its next step. It asks again after a failure that may pass, and has its window compacted — by a
//! fiber under it, as the person's compaction is — before a request it is too full for, or one its provider refused as
//! too long.
const std = @import("std");
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const ai = @import("ai");
const beak = @import("../beak.zig");
const runtime_ = @import("../runtime.zig");
const Runtime = runtime_.Runtime;
const Phase = runtime_.Phase;
const Request = runtime_.Request;
const threads = @import("../threads.zig");
const log = threads.log;
const Window = threads.Window;
const tools = @import("../tools.zig");
const Tool = tools.Tool;
const calls = tools.calls;
const system = @import("system.zig");
const compaction = @import("compaction.zig");
const compacting = @import("compacting.zig");
const h = beak.h;
const models_ = @import("models.zig");

/// Registers the program of a thread's turns, which ask `models`.
pub fn register(runtime: *Runtime, models: *ai.Models) !void {
    try runtime.register(.{ .kind = threads.turn_program, .stop_handler = true, .context = models, .phase = turnPhase });
}

/// How many times a turn asks again after its model failed in a way that may pass, before the turn fails.
pub const retries_max = 10;
/// How long a turn waits before asking again, where the provider says nothing: doubling from the first, to the most.
const retry_first_ms = 2_000;
const retry_most_ms = 60_000;
/// The longest a turn waits where the provider says how long.
const retry_after_most_ms = 15 * std.time.ms_per_min;

/// Where a turn is: about to ask, its `attempt` counting the failures that may pass, `compacted` where its window was
/// compacted for this request; asked by the request of `key`; waiting for the thread's compaction to end; or running
/// the calls of a reply. Its checkpoint holds it as JSON; empty, the turn is about to ask for the first
/// time.
const Checkpoint = union(enum) {
    asking: struct { attempt: u32, compacted: bool = false },
    asked: struct { attempt: u32, key: []const u8, compacted: bool = false },
    compacting: struct {},
    calling: Calling,

    fn of(phase: *const Phase) !Checkpoint {
        if (phase.checkpoint.len == 0) return .{ .asking = .{ .attempt = 0 } };
        return foundation.json.decode(Checkpoint, phase.arena, phase.checkpoint);
    }
};

/// The calls of the reply at `reply` running: each a fiber keyed by its id in `calls`, in the order the model made
/// them, those before `collected` with their results appended.
const Calling = struct { reply: log.Address, calls: []const []const u8, collected: u32 };

/// A turn: asks its model, appends the reply, runs its calls, and asks again till a reply calls nothing; asks again
/// after a failure that may pass, and when its request was cut off; compacts its window before a request it is too
/// full for, or one its provider refused as too long; its stop handler keeps what had come of the reply, answers what
/// was not run as stopped, and has every call that runs end as its own stop handler ends it.
fn turnPhase(context: ?*anyopaque, phase: *Phase) anyerror!void {
    const models: *ai.Models = @ptrCast(@alignCast(context.?));
    const thread = threads.threadOf(phase.path);
    switch (try Checkpoint.of(phase)) {
        .asking => |asking| {
            if (phase.stop_handler) return phase.stopped(null);
            const window = try windowOf(phase, thread);
            if (!asking.compacted and try isFull(models, phase, thread, window)) return compact(phase, thread);
            return ask(phase, thread, window, asking.attempt, asking.compacted);
        },
        .asked => |asked| return answered(phase, thread, asked.key, asked.attempt, asked.compacted),
        .compacting => return compactionEnded(phase, thread),
        .calling => |calling| return called(phase, thread, calling),
    }
}

/// The model's answer to the request of `key`: its reply appended once, whole, and the calls it made started; asked
/// again where it was cut off, or failed in a way that may pass; the window compacted where its provider refused the
/// request as too long, once for one request.
fn answered(phase: *Phase, thread: []const u8, key: []const u8, attempt: u32, compacted: bool) !void {
    const answer = try phase.mailOf(key) orelse return phase.waitForMail(Phase.kept, key);
    try phase.take(key);
    if (answer.interrupted()) {
        if (phase.stop_handler) return phase.stopped(null);
        return ask(phase, thread, try windowOf(phase, thread), attempt, compacted);
    }
    if (std.mem.eql(u8, answer.name, Request.failed_name)) {
        if (phase.stop_handler) return phase.stopped(null);
        return phase.fail(answer.payload);
    }
    const response = foundation.json.decode(vocabulary.Response, phase.arena, answer.payload) catch return phase.fail("the model's answer is no response");
    // What the request used is the turn's, and the thread's above it, whatever came of it.
    try models_.charge(&phase.changes, phase.path, response);
    if (response.status == .failed) {
        try keepFailure(phase, thread, key, answer.payload);
        if (phase.stop_handler) return phase.stopped(null);
        const too_long = if (response.@"error") |failure| failure.octoii.kind == .context_overflow else false;
        if (too_long and !compacted and try compaction.cutOf(phase.arena, try windowOf(phase, thread)) != null) return compact(phase, thread);
        return failed(phase, response, attempt);
    }
    const reply: log.Reply = .{
        .id = try phase.mint(),
        .request = key,
        .response = try foundation.json.Raw.of(phase.arena, answer.payload),
        .cancelled = if (phase.stop_handler) true else null,
    };
    var writer: log.Writer = try .init(phase, thread);
    const at = try writer.append(reply);
    const made = try log.callsOf(phase.arena, try log.lineOf(phase.arena, reply));
    if (phase.stop_handler) {
        for (made) |call| try writer.appendResult(null, null, call.call_id, try Tool.stoppedBefore(phase.arena));
        return phase.stopped(null);
    }
    if (made.len == 0) return phase.done(null);
    return startCalls(phase, at, made);
}

/// The window the log of the thread at `thread` ends in.
fn windowOf(phase: *Phase, thread: []const u8) !Window {
    return Window.of(phase.arena, try log.lines(phase.runtime.volume, &phase.arena, thread));
}

/// Whether the thread's `window` is too full for its model's next request, with something in it to recap; never where
/// its model's context is not known.
fn isFull(models: *ai.Models, phase: *Phase, thread: []const u8, window: Window) !bool {
    const reference = (try threads.manifestOf(phase.runtime.volume, &phase.arena, thread)).model orelse return false;
    const served = try models.find(phase.arena, reference) orelse return false;
    if (!try compaction.isFull(phase.arena, window, served.model.context_length)) return false;
    return try compaction.cutOf(phase.arena, window) != null;
}

/// Has the thread's window compacted — the thread's compaction started where it is not running, the person's waited
/// for where it is — and sleeps on it: not the turn's own fiber, it is waited on by its changes, as an inbox is.
fn compact(phase: *Phase, thread: []const u8) !void {
    _ = try compacting.start(&phase.changes, phase.runtime, &phase.arena, thread);
    return phase.waitForChange(Checkpoint{ .compacting = .{} }, try compacting.pathOf(phase.arena, thread));
}

/// The thread's compaction ended: the model asked on the window it began; the turn fails as it failed, and ends
/// stopped under a stop, which it does not wait on.
fn compactionEnded(phase: *Phase, thread: []const u8) !void {
    if (phase.stop_handler) return phase.stopped(null);
    const outcome = switch (try compacting.standingOf(phase.runtime.volume, &phase.arena, thread)) {
        .none => return error.CompactionGone,
        .running => return phase.waitForChange(Phase.kept, try compacting.pathOf(phase.arena, thread)),
        .ended => |ended| ended,
    };
    return switch (outcome.status) {
        h.BEAK_OUTCOME_COMPLETED => phase.next(Checkpoint{ .asking = .{ .attempt = 0, .compacted = true } }),
        h.BEAK_OUTCOME_FAILED => phase.fail(beak.slice(if (outcome.has_result) outcome.result else outcome.@"error")),
        else => phase.stopped(null),
    };
}

/// Keeps the answer `payload` of the model request of `key`, which came to nothing, as a failure: for the record, never
/// sent to the model.
fn keepFailure(phase: *Phase, thread: []const u8, key: []const u8, payload: []const u8) !void {
    var writer: log.Writer = try .init(phase, thread);
    _ = try writer.append(log.Failure{ .id = try phase.mint(), .request = key, .response = try foundation.json.Raw.of(phase.arena, payload) });
}

/// Starts every call of the reply at `reply` at once, each a fiber of its own keyed by an id minted for it, and sleeps
/// until the first ends.
fn startCalls(phase: *Phase, reply: log.Address, made: []const vocabulary.items.FunctionCall) !void {
    const keys = try phase.arena.alloc([]const u8, made.len);
    for (made, keys) |call, *key| {
        key.* = try phase.mint();
        try calls.start(phase, key.*, call);
    }
    const at: Checkpoint = .{ .calling = .{ .reply = reply, .calls = keys, .collected = 0 } };
    return phase.waitForExit(at, try beak.childPath(phase.arena, phase.path, keys[0]));
}

/// The calls of a reply that ended, their results appended in the order the model made the calls, and they reaped,
/// from the first not yet collected on; one still running is slept on. Once every call has its result, the model is
/// asked again — or, under a stop, which reaches every call that runs, the turn ends stopped.
fn called(phase: *Phase, thread: []const u8, calling: Calling) !void {
    const made = try log.callsOf(phase.arena, try log.lineAt(phase.runtime.volume, &phase.arena, thread, calling.reply));
    var writer: log.Writer = try .init(phase, thread);
    var collected = calling.collected;
    while (collected < calling.calls.len) : (collected += 1) {
        const key = calling.calls[collected];
        _ = try calls.settle(&writer, key, null, made[collected].call_id) orelse {
            const at: Checkpoint = .{ .calling = .{ .reply = calling.reply, .calls = calling.calls, .collected = collected } };
            return phase.waitForExit(at, try beak.childPath(phase.arena, phase.path, key));
        };
    }
    if (phase.stop_handler) return phase.stopped(null);
    // What the person sent while the calls ran steers the turn: taken in after their results, as the next step begins.
    _ = try threads.takeInputs(&writer);
    // The model is asked on what this phase commits: the results and what the person sent, once they are in the log.
    return phase.next(Checkpoint{ .asking = .{ .attempt = 0 } });
}

/// After the model failed with `response`: asks again once the wait passes, where the failure may pass and retries are
/// left; else the turn fails, for what the provider said.
fn failed(phase: *Phase, response: vocabulary.Response, attempt: u32) !void {
    const failure = response.@"error" orelse return phase.fail("the model failed, saying nothing");
    if (!failure.octoii.retryable or attempt + 1 > retries_max) return phase.fail(failure.message);
    const wait = if (failure.octoii.retry_after_ms) |after| @min(after, retry_after_most_ms) else @min(@as(u64, retry_first_ms) << @intCast(@min(attempt, 16)), retry_most_ms);
    return phase.waitUntil(Checkpoint{ .asking = .{ .attempt = attempt + 1 } }, phase.time + @as(i64, @intCast(wait)));
}

/// Asks the model of the thread at `thread` for what follows its `window`, to the window's last entry — after it, the
/// effort the person changed, where they changed it — and sleeps until the answer comes.
fn ask(phase: *Phase, thread: []const u8, window: Window, attempt: u32, compacted: bool) !void {
    const manifest = try threads.manifestOf(phase.runtime.volume, &phase.arena, thread);
    if (window.conversation.len == 0) return error.EmptyWindow;
    var until = (try log.headOf(phase.arena, window.conversation[window.conversation.len - 1])).id;
    // An effort the person changed since the log last told it is told before the request, which it asks at.
    if (manifest.effort) |effort| if (window.effort_set != effort) {
        var writer: log.Writer = try .init(phase, thread);
        until = try phase.mint();
        _ = try writer.append(log.Configuration{ .id = until, .effort = effort });
    };
    const key = try phase.mint();
    try phase.request(models_.model_request, key, models_.ModelRequest{ .thread = threads.idOf(thread), .until = until, .model = manifest.model });
    return phase.waitForMail(Checkpoint{ .asked = .{ .attempt = attempt, .key = key, .compacted = compacted } }, key);
}
