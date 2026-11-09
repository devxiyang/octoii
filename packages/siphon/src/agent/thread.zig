//! A thread's main fiber: it starts a turn when inputs wait and none runs — what the model is told gathered first, then
//! the inputs taken into the log and the thread running from then, in the same commit — and settles each turn once it
//! ends, appending its `turn-end` and setting how and when it ended, as a parent reaps a child: so a turn killed, or
//! one that failed, is settled all the same, every call it left unanswered answered interrupted.
const std = @import("std");
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
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
const models = @import("models.zig");

/// How many times a phase of a thread's main fiber that threw runs again, after Beak's delay, before the fiber fails —
/// and is started again by what is next delivered to its thread.
const retries = 3;

/// Registers the program of a thread's main fiber.
pub fn register(runtime: *Runtime) !void {
    try runtime.register(.{ .kind = threads.thread_program, .retries = retries, .phase = threadPhase });
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
        // A turn the main fiber before this one left running is settled with what this phase goes on to do.
        if (try threads.lostTurn(phase.runtime.volume, &phase.arena, thread)) |began| try settleLost(phase, thread, began);
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
    try threads.setRunning(&phase.changes, thread, phase.time, taken[0].address);
    const running: Standing = .{ .running = .{ .turn = turn, .began = taken[0].address } };
    return phase.waitForExit(running, try beak.childPath(phase.arena, phase.path, turn));
}

/// Ends the inputs that wait as a turn that failed before its model was asked: what the model is told could not be
/// gathered, for `why`.
fn failBefore(phase: *Phase, thread: []const u8, why: []const u8) !void {
    var writer: log.Writer = try .init(phase, thread);
    const taken = try threads.takeInputs(&writer);
    if (taken.len == 0) return phase.next(null);
    const reason = try phase.arena.print("what the model is told could not be gathered: {s}", .{why});
    _ = try writer.append(log.TurnEnd{ .id = try phase.mint(), .outcome = .failed, .reason = reason });
    // A turn that failed at once began and ended in the same commit.
    try threads.setRunning(&phase.changes, thread, phase.time, null);
    try threads.setEnded(&phase.changes, thread, .failed, phase.time);
    for (taken) |each| if (each.reply_to) |reply_to| try threads.tellEnded(&phase.changes, phase.runtime.volume, reply_to, .{ .failed = reason });
    return phase.next(null);
}

/// Settles, with the phase's commit, the turn a main fiber before this one left running as it ended, begun with the
/// entry at `began`: every call it left without a result answered interrupted, and its `turn-end` failed, as init
/// settles the children of a process that died.
fn settleLost(phase: *Phase, thread: []const u8, began: log.Address) !void {
    var writer: log.Writer = try .init(phase, thread);
    const left = try leftBy(phase, thread, began);
    try answerLeft(&writer, left);
    const reason = "its thread's fiber ended while it ran";
    _ = try writer.append(log.TurnEnd{ .id = try phase.mint(), .outcome = .failed, .reason = reason });
    try threads.setEnded(&phase.changes, thread, .failed, phase.time);
    try tellAsking(phase, left.asking, .{ .failed = reason });
}

/// Answers every call the turn at `turn`, as it ran, left without a result; appends its `turn-end`, as it ended with
/// `outcome`, the thread's status set to the same; and reaps it.
fn settle(phase: *Phase, thread: []const u8, turn: []const u8, outcome: *const h.beak_outcome, running: Running) !void {
    var writer: log.Writer = try .init(phase, thread);
    const left = try leftBy(phase, thread, running.began);
    try answerLeft(&writer, left);
    const said = beak.slice(if (outcome.has_result) outcome.result else outcome.@"error");
    const id = try phase.mint();
    const end: log.TurnEnd = switch (outcome.status) {
        h.BEAK_OUTCOME_COMPLETED => .{ .id = id, .turn = running.turn, .outcome = .replied },
        h.BEAK_OUTCOME_FAILED => .{ .id = id, .turn = running.turn, .outcome = .failed, .reason = said },
        else => .{ .id = id, .turn = running.turn, .outcome = .stopped, .reason = beak.slice(outcome.reason) },
    };
    _ = try writer.append(end);
    try threads.setEnded(&phase.changes, thread, end.outcome, phase.time);
    try tellAsking(phase, left.asking, switch (end.outcome) {
        .replied => .{ .replied = left.said },
        .failed => .{ .failed = end.reason orelse "it failed" },
        .stopped => .{ .stopped = .{} },
    });
    try phase.changes.reap(turn);
}

/// What a turn begun with the entry at `began` left as it ended: the calls its replies made — and those made under them —
/// that have no result, those its inputs ask to be told how it ended, and what it said last.
const Left = struct {
    unanswered: []const Unanswered,
    asking: []const log.ReplyTo,
    said: []const u8,

    const Unanswered = struct { under: ?[]const u8, call_id: []const u8 };
};

/// What the turn begun with the entry at `began` left, as the log of the thread at `thread` holds it from there.
fn leftBy(phase: *Phase, thread: []const u8, began: log.Address) !Left {
    const arena = phase.arena;
    var results: std.StringHashMapUnmanaged(void) = .empty;
    var made: std.ArrayList(Left.Unanswered) = .empty;
    var asking: std.ArrayList(log.ReplyTo) = .empty;
    var said: []const u8 = "";
    const from: log.Cursor = .{ .segment = began.segment, .offset = began.offset };
    for ((try log.readFrom(phase.runtime.volume, &phase.arena, thread, from, std.math.maxInt(u64))).lines) |line| {
        const kind = (try log.headOf(arena, line)).type;
        if (std.mem.eql(u8, kind, "reply")) {
            for (try log.callsOf(arena, line)) |call| try made.append(arena, .{ .under = null, .call_id = call.call_id });
            const reply = try foundation.json.decode(log.Reply, arena, line);
            if (try models.textOf(arena, try foundation.json.decode(vocabulary.Response, arena, reply.response.text))) |text| said = text;
        } else if (std.mem.eql(u8, kind, "calls")) {
            const entry = try foundation.json.decode(log.Calls, arena, line);
            for (entry.calls) |call| try made.append(arena, .{ .under = entry.under, .call_id = call.call_id });
        } else if (std.mem.eql(u8, kind, "result")) {
            try results.put(arena, (try foundation.json.decode(log.Result, arena, line)).call_output.call_id, {});
        } else if (std.mem.eql(u8, kind, "input")) {
            if ((try foundation.json.decode(log.Input, arena, line)).reply_to) |reply_to| try asking.append(arena, reply_to);
        }
    }
    var unanswered: std.ArrayList(Left.Unanswered) = .empty;
    for (made.items) |call| if (!results.contains(call.call_id)) try unanswered.append(arena, call);
    return .{ .unanswered = unanswered.items, .asking = asking.items, .said = said };
}

/// Every call a turn `left` without a result answered interrupted by `writer`, so every call the log holds has its result.
fn answerLeft(writer: *log.Writer, left: Left) !void {
    for (left.unanswered) |call| {
        try writer.appendResult(null, call.under, call.call_id, try Tool.noted(writer.phase.arena, .interrupted, "cut off as its turn ended; it may or may not have acted"));
    }
}

/// Mail to each of `asking` that the turn that took its input ended as `ended`, with the phase's commit.
fn tellAsking(phase: *Phase, asking: []const log.ReplyTo, ended: threads.Ended) !void {
    for (asking) |reply_to| try threads.tellEnded(&phase.changes, phase.runtime.volume, reply_to, ended);
}
