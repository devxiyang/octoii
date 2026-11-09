//! A thread's main fiber: it starts a turn when inputs wait and none runs — what the model is told gathered first, then
//! the inputs taken into the log and the thread running from then, in the same commit — and settles each turn once it
//! ends, appending its `turn-end` and setting how and when it ended, as a parent reaps a child: so a turn killed, or
//! one that failed, is settled all the same, every call it left unanswered answered interrupted.
const std = @import("std");
const foundation = @import("foundation");
const beak = @import("../beak.zig");
const h = beak.h;
const runtime_ = @import("../runtime.zig");
const Runtime = runtime_.Runtime;
const Phase = runtime_.Phase;
const Request = runtime_.Request;
const threads = @import("../threads.zig");
const log = threads.log;
const tools = @import("../tools.zig");
const Tool = tools.Tool;
const trust = tools.trust;
const system = @import("system.zig");
const title = @import("title.zig");

/// Registers the program of a thread's main fiber.
pub fn register(runtime: *Runtime) !void {
    try runtime.register(.{ .kind = threads.thread_program, .phase = threadPhase });
}

/// Where a thread's main fiber stands: gathering what its model is told before a turn, by the context request of
/// `key`; or its turn running, a fiber named by the turn's id, begun with the entry at `began`. At rest, its
/// checkpoint is empty.
const Standing = union(enum) {
    gathering: struct { key: []const u8 },
    running: Running,
};

const Running = struct { turn: []const u8, began: log.Address };

/// The main fiber: where inputs wait and no turn runs, has what the model is told gathered, then begins a turn with
/// it; settles a turn that ended; and between sleeps on its turn, its request or its inbox.
fn threadPhase(_: ?*anyopaque, phase: *Phase) anyerror!void {
    const thread = threads.threadOf(phase.path);
    if (phase.checkpoint.len == 0) {
        if ((try threads.waiting(phase.runtime.volume, &phase.arena, thread)).len == 0) return phase.waitForChange(null, try beak.join(phase.arena, thread, "inbox"));
        return gatherBefore(phase, thread);
    }
    switch (try foundation.json.decode(Standing, phase.arena, phase.checkpoint)) {
        .running => |running| {
            const turn = try beak.childPath(phase.arena, phase.path, running.turn);
            const entry = try phase.runtime.volume.stat(&phase.arena, turn) orelse return error.TurnGone;
            const outcome = beak.outcomeOf(entry) orelse return phase.waitForExit(Phase.kept, turn);
            try settle(phase, thread, turn, outcome, running);
            return phase.next(null);
        },
        .gathering => |gathering| {
            const answer = try phase.mailOf(gathering.key) orelse return phase.waitForMail(Phase.kept, gathering.key);
            try phase.take(gathering.key);
            // What changes nothing is asked again where it was cut off.
            if (answer.interrupted()) return gatherBefore(phase, thread);
            if (std.mem.eql(u8, answer.name, Request.failed_name)) return failBefore(phase, thread, answer.payload);
            return begin(phase, thread, gathering.key, try foundation.json.decode(system.Told, phase.arena, answer.payload));
        },
    }
}

/// Has what the thread's model is told gathered before its turn, and sleeps until the answer comes.
fn gatherBefore(phase: *Phase, thread: []const u8) !void {
    const key = try system.gather(phase, thread);
    return phase.waitForMail(Standing{ .gathering = .{ .key = key } }, key);
}

/// Begins a turn, in one commit: what of `gathered`, by the context request of `gathering`, the model was not told
/// appended as a system entry — the tools with the entry that begins a window — and the person asked what it found to
/// ask them; then the inputs that wait, the thread's title asked for where it has none, and the turn started, a fiber
/// named by an id minted for it; where the inputs were withdrawn meanwhile, the fiber rests.
fn begin(phase: *Phase, thread: []const u8, gathering: []const u8, gathered: system.Told) !void {
    var writer: log.Writer = try .init(phase, thread);
    const news = try system.changes(phase.arena, try system.toldIn(phase.runtime.volume, &phase.arena, thread), gathered);
    if (news.sections.len + news.tools.len > 0) _ = try writer.append(log.System{ .id = try phase.mint(), .request = gathering, .sections = news.sections, .tools = news.tools });
    if (gathered.asked) |asked| try trust.ask(phase, thread, asked);
    const taken = try threads.takeInputs(&writer);
    if (taken.len == 0) return phase.next(null);
    try title.startFor(phase, thread);
    const turn = try phase.mint();
    try phase.start(turn, threads.turn_program, null);
    try threads.setRunning(&phase.changes, thread, phase.time);
    const running: Standing = .{ .running = .{ .turn = turn, .began = taken[0] } };
    return phase.waitForExit(running, try beak.childPath(phase.arena, phase.path, turn));
}

/// Ends the inputs that wait as a turn that failed before its model was asked: what the model is told could not be
/// gathered, for `why`.
fn failBefore(phase: *Phase, thread: []const u8, why: []const u8) !void {
    var writer: log.Writer = try .init(phase, thread);
    if ((try threads.takeInputs(&writer)).len == 0) return phase.next(null);
    _ = try writer.append(log.TurnEnd{ .id = try phase.mint(), .outcome = .failed, .reason = try phase.arena.print("what the model is told could not be gathered: {s}", .{why}) });
    // A turn that failed at once began and ended in the same commit.
    try threads.setRunning(&phase.changes, thread, phase.time);
    try threads.setEnded(&phase.changes, thread, .failed, phase.time);
    return phase.next(null);
}

/// Answers every call the turn at `turn`, as it ran, left without a result; appends its `turn-end`, as it ended with
/// `outcome`, the thread's status set to the same; and reaps it.
fn settle(phase: *Phase, thread: []const u8, turn: []const u8, outcome: *const h.beak_outcome, running: Running) !void {
    var writer: log.Writer = try .init(phase, thread);
    try answerUnanswered(&writer, running.began);
    const said = beak.slice(if (outcome.has_result) outcome.result else outcome.@"error");
    const id = try phase.mint();
    const end: log.TurnEnd = switch (outcome.status) {
        h.BEAK_OUTCOME_COMPLETED => .{ .id = id, .turn = running.turn, .outcome = .replied },
        h.BEAK_OUTCOME_FAILED => .{ .id = id, .turn = running.turn, .outcome = .failed, .reason = said },
        else => .{ .id = id, .turn = running.turn, .outcome = .stopped, .reason = beak.slice(outcome.reason) },
    };
    _ = try writer.append(end);
    try threads.setEnded(&phase.changes, thread, end.outcome, phase.time);
    try phase.changes.reap(turn);
}

/// Every call the turn begun with the entry at `began` made — its replies', and those made under them — that has no
/// result, answered interrupted by `writer`, so every call the log holds has its result.
fn answerUnanswered(writer: *log.Writer, began: log.Address) !void {
    const phase = writer.phase;
    var results: std.StringHashMapUnmanaged(void) = .empty;
    var made: std.ArrayList(struct { under: ?[]const u8, call_id: []const u8 }) = .empty;
    const from: log.Cursor = .{ .segment = began.segment, .offset = began.offset };
    for ((try log.readFrom(phase.runtime.volume, &phase.arena, writer.thread, from, std.math.maxInt(u64))).lines) |line| {
        const head = try log.headOf(phase.arena, line);
        if (std.mem.eql(u8, head.type, "reply")) {
            for (try log.callsOf(phase.arena, line)) |call| try made.append(phase.arena, .{ .under = null, .call_id = call.call_id });
        } else if (std.mem.eql(u8, head.type, "calls")) {
            const entry = try foundation.json.decode(log.Calls, phase.arena, line);
            for (entry.calls) |call| try made.append(phase.arena, .{ .under = entry.under, .call_id = call.call_id });
        } else if (std.mem.eql(u8, head.type, "result")) {
            const result = try foundation.json.decode(log.Result, phase.arena, line);
            try results.put(phase.arena, result.call_output.call_id, {});
        }
    }
    for (made.items) |call| {
        if (results.contains(call.call_id)) continue;
        try writer.appendResult(null, call.under, call.call_id, try Tool.noted(phase.arena, .interrupted, "cut off as its turn ended; it may or may not have acted"));
    }
}
