//! Sub-threads: the `delegate` tool, by which a thread's model hands a task to a thread of its own, as a parent forks a
//! child — only where the person asks it to delegate, or to work on things at once. A new sub-thread is made in the
//! thread's folder, with its model, its mode and its effort, the task its first message; a task for one made before
//! goes to its inbox, steering it where it runs. The call sleeps till the turn that took the task ends, then is
//! answered with what the sub-thread said last; several calls in one reply run at once, as calls do. One in the
//! background is answered at once, and a fiber beside the thread's main fiber — of no turn, so a stop of the turn
//! reaches it not, as an interrupt reaches the foreground alone — sleeps on the sub-thread instead, then delivers what
//! came of it to the thread's inbox, as `at` mails a job's output to whoever queued it: the thread's turn takes it at
//! its next step, or one begins with it. A sub-thread is a thread like any other, which the person follows and steers;
//! it delegates no further, its work on a task stops as the call that waits on it does, and it goes with its thread.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const typebox = @import("typebox");
const vocabulary = @import("vocabulary");
const beak = @import("../beak.zig");
const runtime_ = @import("../runtime.zig");
const Runtime = runtime_.Runtime;
const Phase = runtime_.Phase;
const threads = @import("../threads.zig");
const log = threads.log;
const tools = @import("../tools.zig");
const Tool = tools.Tool;
const Table = tools.Table;
const models = @import("models.zig");

/// The program of a delegating call's fiber, and of the fiber that sleeps on a task delegated in the background.
pub const program = "siphon.delegate";
pub const background_program = "siphon.delegated";

pub const delegate: Tool = .{
    .name = "delegate",
    .description =
    \\Hands a task to a sub-thread of your own, which works on it with the same tools in this folder. Call it only when the person asks you to delegate work, to use sub-agents, or to work on several things at once — never on your own initiative. A new sub-thread sees nothing of this conversation: give `task` all it needs. You wait for it to finish and are given what it said last, several calls in one reply running at once; or, with `background`, you are answered at once and told when it finishes — for work that does not hold up yours. Every answer names the sub-thread, which `thread` gives more to do. The person sees each sub-thread, and can follow and steer it.
    ,
    .parameters = typebox.of(Arguments),
    .work = .{ .program = program },
    .offered = isNoSubThread,
};

const Arguments = struct {
    task: []const u8,
    title: ?[]const u8 = null,
    thread: ?[]const u8 = null,
    background: bool = false,

    pub const schema = .{
        .task = .{ .description = "What the sub-thread is to do: the whole of it, as a new one sees nothing else" },
        .title = .{ .description = "A few words the person knows a new sub-thread by" },
        .thread = .{ .description = "The id of a sub-thread of yours, running or finished, to give this task to: it keeps what it did. Omit to start a new one" },
        .background = .{ .description = "Run it in the background and be answered at once: you are told when the sub-thread finishes, by a message. Do not wait for it, poll it or ask after its progress" },
    };
};

/// Runs delegating calls and what sleeps on a task delegated in the background, and adds the `delegate` tool to
/// `table`.
pub fn register(runtime: *Runtime, table: *Table) !void {
    try runtime.register(.{ .kind = program, .stop_handler = true, .phase = delegating });
    try runtime.register(.{ .kind = background_program, .phase = inBackground });
    try table.add(delegate);
}

/// Whether a thread of `manifest` may delegate: one that is no sub-thread itself.
fn isNoSubThread(manifest: *const threads.Manifest) bool {
    return manifest.parent == null;
}

/// A task given to a sub-thread, slept on: the sub-thread, by its id, and the task, by its id in the sub-thread's
/// inbox — and in its log, once taken, by the delivery of that id.
const Waiting = struct { child: []const u8, task: []const u8 };

/// The fiber of a call: gives the task to its sub-thread, then sleeps on it till the turn that took the task ends, and
/// ends with what it said last — or how its work ended short; under a stop, stops its work on the task.
fn delegating(_: ?*anyopaque, run: *Phase) anyerror!void {
    if (run.checkpoint.len == 0) {
        if (run.stop_handler) return run.stopped(try Tool.stoppedBefore(run.arena));
        return give(run, try foundation.json.decode(Arguments, run.arena, run.input));
    }
    const waiting = try foundation.json.decode(Waiting, run.arena, run.checkpoint);
    if (run.stop_handler) return stop(run, waiting);
    const ended = try endedOf(run, waiting) orelse return sleepOn(run, Phase.kept, waiting);
    return run.done(try answerOf(run.arena, waiting.child, ended));
}

/// The fiber of a task delegated in the background, beside its thread's main fiber: sleeps on the sub-thread till the
/// turn that took the task ends, then ends, what came of it delivered to the thread's inbox from the sub-thread, in the
/// same commit.
fn inBackground(_: ?*anyopaque, run: *Phase) anyerror!void {
    const waiting = try foundation.json.decode(Waiting, run.arena, run.input);
    const ended = try endedOf(run, waiting) orelse return sleepOn(run, null, waiting);
    const id = try run.mint();
    const input: threads.Input = .{ .message = try noticeOf(run.arena, waiting.child, ended), .actor = try threads.actorOf(run.arena, waiting.child) };
    try threads.inboxed(&run.changes, threads.threadOf(run.path), id, input, try deliveryOf(run.arena, id));
    return run.done(null);
}

/// Gives the task to the sub-thread of the thread's that `given` names, or to a new one, in the fiber's commit; then
/// sleeps on it, or, in the background, starts what sleeps on it and ends with where the task went. A sub-thread is
/// refused, as it delegates no further.
fn give(run: *Phase, given: Arguments) !void {
    const thread = threads.threadOf(run.path);
    const own = try threads.manifestOf(run.runtime.volume, &run.arena, thread);
    if (own.parent != null) return refuse(run, "a sub-thread delegates no further: do the task yourself");
    if (given.thread) |named| if (try refusalOf(run, thread, named)) |why| return refuse(run, why);
    const child = given.thread orelse try make(run, thread, own, given.title);
    const task = try run.mint();
    const message: vocabulary.items.InputMessage = .{ .role = .user, .content = .{ .text = given.task } };
    const input: threads.Input = .{ .message = message, .actor = try threads.actorOf(run.arena, threads.idOf(thread)) };
    try threads.inboxed(&run.changes, try threads.pathOf(run.arena, child), task, input, try deliveryOf(run.arena, task));
    const waiting: Waiting = .{ .child = child, .task = task };
    if (!given.background) return sleepOn(run, waiting, waiting);
    try run.startIn(thread, try deliveryOf(run.arena, task), background_program, waiting);
    return run.done(try backgroundAnswerOf(run.arena, child));
}

fn refuse(run: *Phase, why: []const u8) !void {
    return run.done(try Tool.noted(run.arena, .@"tool-error", why));
}

/// Makes a sub-thread of the thread at `thread`, whose manifest is `own`, with the phase's commit: its model, its
/// folder, its mode and its effort the thread's, titled `title`, its parent the call; its id.
fn make(run: *Phase, thread: []const u8, own: threads.Manifest, title: ?[]const u8) ![]const u8 {
    const tid = try run.mint();
    try threads.made(&run.changes, run.runtime, tid, .{
        .project = own.project,
        .model = own.model,
        .workspace = own.workspace,
        .title = title,
        .mode = own.mode,
        .effort = own.effort,
        .parent = .{ .thread = threads.idOf(thread), .call = beak.keyOf(std.fs.path.dirname(run.path) orelse run.path) },
    });
    return tid;
}

/// Why the thread `child` is given no task by the thread at `thread`: there is no such thread, or it is no sub-thread
/// of this one's; null where it is one.
fn refusalOf(run: *Phase, thread: []const u8, child: []const u8) !?[]const u8 {
    const path = try threads.pathOf(run.arena, child);
    const found = std.mem.indexOfScalar(u8, child, '/') == null and try run.runtime.volume.stat(&run.arena, path) != null;
    if (!found) return try run.arena.print("there is no thread {s}", .{child});
    const parent = (try threads.manifestOf(run.runtime.volume, &run.arena, path)).parent orelse return try noSubThread(run.arena, child);
    if (!std.mem.eql(u8, parent.thread, threads.idOf(thread))) return try noSubThread(run.arena, child);
    return null;
}

fn noSubThread(arena: Allocator, child: []const u8) ![]const u8 {
    return arena.print("the thread {s} is no sub-thread of yours", .{child});
}

/// Sleeps on the sub-thread of `waiting` till it stands otherwise — its status, as a turn begins or ends, or its inbox,
/// as a task is taken back — then runs from `checkpoint`.
fn sleepOn(run: *Phase, checkpoint: anytype, waiting: Waiting) !void {
    const child = try threads.pathOf(run.arena, waiting.child);
    return run.waitForAny(checkpoint, &.{ child, try beak.join(run.arena, child, "inbox") });
}

/// How a sub-thread's work on a task ended: what it said last, as its turn replied; why it failed; or stopped — or the
/// sub-thread deleted, or the task taken back from its inbox, before it was done.
const Ended = union(enum) {
    replied: []const u8,
    failed: []const u8,
    stopped,
    deleted,
    withdrawn,
};

/// How the sub-thread of `waiting` ended its work on the task: as the first `turn-end` after the task in its log says,
/// with the last words it replied between; null while the task waits in its inbox, or the turn that took it runs.
fn endedOf(run: *Phase, waiting: Waiting) !?Ended {
    const volume = run.runtime.volume;
    const child = try threads.pathOf(run.arena, waiting.child);
    if (try volume.stat(&run.arena, child) == null) return .deleted;
    if (try volume.stat(&run.arena, try threads.inboxFile(run.arena, child, waiting.task)) != null) return null;
    const delivery = try deliveryOf(run.arena, waiting.task);
    const lines = try log.lines(volume, &run.arena, child);
    const after = for (lines, 0..) |line, at| {
        if (!std.mem.eql(u8, (try log.headOf(run.arena, line)).type, "input")) continue;
        if (std.mem.eql(u8, (try foundation.json.decode(log.Input, run.arena, line)).delivery_id, delivery)) break at + 1;
    } else return .withdrawn;
    var said: []const u8 = "";
    for (lines[after..]) |line| {
        const kind = (try log.headOf(run.arena, line)).type;
        if (std.mem.eql(u8, kind, "reply")) {
            const reply = try foundation.json.decode(log.Reply, run.arena, line);
            const response = try foundation.json.decode(vocabulary.Response, run.arena, reply.response.text);
            if (try models.textOf(run.arena, response)) |text| said = text;
        } else if (std.mem.eql(u8, kind, "turn-end")) {
            const end = try foundation.json.decode(log.TurnEnd, run.arena, line);
            return switch (end.outcome) {
                .replied => .{ .replied = said },
                .failed => .{ .failed = end.reason orelse "it failed" },
                .stopped => .stopped,
            };
        }
    }
    return null;
}

/// The answer of a call that slept on the sub-thread `child` till its work ended as `ended`.
fn answerOf(arena: Allocator, child: []const u8, ended: Ended) !log.CallOutcome {
    const told = try arena.print("the sub-thread {s} {s}", .{ child, try howOf(arena, ended) });
    return switch (ended) {
        .replied => |said| .{ .status = .ok, .output = try Tool.told(arena, .{ .text = said, .notes = &.{told} }) },
        .stopped => Tool.noted(arena, .stopped, told),
        else => Tool.noted(arena, .@"tool-error", told),
    };
}

/// The answer of a call that gave the sub-thread `child` a task in the background, as it goes on: how its end comes,
/// how to go on meanwhile, and how to give it more.
fn backgroundAnswerOf(arena: Allocator, child: []const u8) !log.CallOutcome {
    return .{ .status = .ok, .output = try Tool.told(arena, .{ .text = "", .notes = &.{
        try arena.print("the sub-thread {s} works on it in the background: you will be told when it finishes, by a message with what it said last", .{child}),
        "do not wait, poll or ask after its progress, and do not do its work or work on what it works on; work on what does not hang on it, or tell the person what you started and end your reply",
        try arena.print("to give it more to do or change what it does, call delegate with the thread {s}", .{child}),
    } }) };
}

/// The message that tells a thread how the work it gave its sub-thread `child` in the background ended, as `ended`
/// says: Siphon's note as its first part, so it reads as no words of the person's, then what the sub-thread said last,
/// where it finished — which a page shows of it, as it shows a thread's words.
fn noticeOf(arena: Allocator, child: []const u8, ended: Ended) !vocabulary.items.InputMessage {
    const note = try arena.print("[the sub-thread {s}, which you gave a task in the background, {s}]", .{ child, try howOf(arena, ended) });
    const parts: []const vocabulary.content.InputContent = switch (ended) {
        .replied => |said| try arena.dupe(vocabulary.content.InputContent, &.{ .{ .input_text = .{ .text = note } }, .{ .input_text = .{ .text = said } } }),
        else => try arena.dupe(vocabulary.content.InputContent, &.{.{ .input_text = .{ .text = note } }}),
    };
    return .{ .role = .user, .content = .{ .parts = parts } };
}

/// How a sub-thread's work ended, as `ended` says, said of it.
fn howOf(arena: Allocator, ended: Ended) ![]const u8 {
    return switch (ended) {
        .replied => "finished: what it said last is here, and its whole work is in it",
        .failed => |why| arena.print("failed: {s}", .{why}),
        .stopped => "was stopped by the person before it finished",
        .deleted => "was deleted before it finished",
        .withdrawn => "had the task taken back before it began it",
    };
}

/// Stops the sub-thread's work on the task: the task taken back where it waits in the inbox, the turn that runs asked
/// to stop otherwise; and ends stopped.
fn stop(run: *Phase, waiting: Waiting) !void {
    const child = try threads.pathOf(run.arena, waiting.child);
    const task = try threads.inboxFile(run.arena, child, waiting.task);
    if (try run.runtime.volume.stat(&run.arena, task) != null) {
        try run.changes.delete(task);
    } else if (try threads.turnOf(run.runtime.volume, &run.arena, child)) |turn| {
        const entry = try run.runtime.volume.stat(&run.arena, turn);
        if (entry != null and beak.outcomeOf(entry.?) == null) try run.changes.terminate(turn, "stopped");
    }
    return run.stopped(try Tool.noted(run.arena, .stopped, "stopped, and the sub-thread's work on it with it"));
}

/// The delivery of the input `id` a delegation delivers — a task, or what came of one — by which a log that took it
/// holds it; and the key of the fiber that sleeps on the task `id` in the background.
fn deliveryOf(arena: Allocator, id: []const u8) ![]const u8 {
    return std.mem.concat(arena, u8, &.{ "delegated-", id });
}
