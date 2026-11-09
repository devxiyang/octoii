//! A tool call, as a fiber under its turn — or under the script that made it — named by an id Siphon mints: it checks
//! the call — its tool among those the model may call, its arguments fitting the tool's parameters — weighs it, as its
//! thread's mode and the grants of its project say, a second model judging it where its weighing says, the person
//! asked first where they must; then asks its tool by a request, where its weighing let it go ahead, or starts the
//! fiber of a tool that is a program, and ends with the call's outcome. It writes nothing of its own end: what started
//! it settles it, and every maker of calls makes and settles them one way — the model's by its turn, those made under
//! a call by the program the call runs — so the thread's log holds every call it made, each with its result.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const runtime_ = @import("../runtime.zig");
const Runtime = runtime_.Runtime;
const Phase = runtime_.Phase;
const Request = runtime_.Request;
const vocabulary = @import("vocabulary");
const threads = @import("../threads.zig");
const log = threads.log;
const beak = @import("../beak.zig");
const Tool = @import("Tool.zig");
const Table = @import("Table.zig");
const permissions = @import("permissions.zig");
const review = @import("review.zig");
const settings = @import("../settings.zig");
const h = beak.h;

/// The program of a call's fiber.
pub const call_program = "siphon.call";

/// What a call's fiber is started with: the call as the model made it, its id the provider's.
pub const Input = struct { call_id: []const u8, name: []const u8, arguments: []const u8 };

/// Starts the call `call` as a fiber of its own under `run`'s, keyed `key`: Siphon's id of the call.
pub fn start(run: *Phase, key: []const u8, call: vocabulary.items.FunctionCall) !void {
    try run.start(key, call_program, Input{ .call_id = call.call_id, .name = call.name, .arguments = call.arguments });
}

/// Makes the calls `made` under the call `under`, as the program that call runs makes its own: logged by `writer`, as
/// no reply holds them, then each started, keyed by its id.
pub fn makeUnder(writer: *log.Writer, under: []const u8, made: []const vocabulary.items.FunctionCall) !void {
    _ = try writer.append(log.Calls{ .id = try writer.phase.mint(), .under = under, .calls = made });
    for (made) |call| try start(writer.phase, call.call_id, call);
}

/// Settles the call `call_id`, made under the call `under` where it was, whose fiber keyed `key` is a child of the
/// phase `writer` writes for: once it ended, its result appended and its fiber reaped, its outcome; none while it runs.
pub fn settle(writer: *log.Writer, key: []const u8, under: ?[]const u8, call_id: []const u8) !?log.CallOutcome {
    const run = writer.phase;
    const path = try beak.childPath(run.arena, run.path, key);
    const entry = try run.runtime.volume.stat(&run.arena, path) orelse return error.CallGone;
    const ended = beak.outcomeOf(entry) orelse return null;
    const outcome = try outcomeOf(run.arena, ended);
    try writer.appendResult(key, under, call_id, outcome);
    try run.changes.reap(path);
    return outcome;
}

/// The call the program of `run`'s fiber runs for, as its fiber — the program's parent — was started with it.
pub fn runningFor(run: *Phase) !Input {
    const slash = std.mem.lastIndexOfScalar(u8, run.path, '/') orelse return error.NoCall;
    const input = try run.runtime.volume.readAll(&run.arena, try beak.join(run.arena, run.path[0..slash], h.BEAK_INPUT_NAME));
    return foundation.json.decode(Input, run.arena, input);
}

/// Registers the program of a call's fiber, which finds its tool in `table`, and the person's answer to a call that asks.
pub fn register(runtime: *Runtime, table: *Table) !void {
    try runtime.register(.{ .kind = call_program, .stop_handler = true, .context = table, .phase = phase });
    try permissions.register(runtime);
}

fn phase(context: ?*anyopaque, run: *Phase) anyerror!void {
    const table: *Table = @ptrCast(@alignCast(context.?));
    const input = try foundation.json.decode(Input, run.arena, run.input);
    const tool = table.named(input.name);
    if (run.checkpoint.len == 0) {
        if (run.stop_handler) return endWith(run, try Tool.stoppedBefore(run.arena));
        if (tool) |found| {
            if (try found.argumentsProblem(run.arena, input.arguments)) |problem| return end(run, .@"invalid-arguments", problem);
        }
        return weigh(run, table, input, tool);
    }
    const at = try foundation.json.decode(At, run.arena, run.checkpoint);
    if (at.started) |key| return programEnded(run, key);
    if (at.permission) |asked| return permitted(run, input, tool, asked);
    if (at.review) |judging| return reviewed(run, table, input, tool, judging);
    const asked = at.asked orelse return error.BadCheckpoint;
    const answer = try run.mailOf(asked.key) orelse return run.waitForMail(Phase.kept, asked.key);
    try run.take(asked.key);
    if (answer.interrupted()) {
        if (run.stop_handler) return endNoted(run, .stopped, "stopped as it ran");
        // What acts on nothing runs again; what may have acted is never run twice.
        if (!table.mayAct(input.name)) return ask(run, input, asked.writes);
        return endNoted(run, .interrupted, "cut off as it ran; it may or may not have acted");
    }
    if (std.mem.eql(u8, answer.name, Request.failed_name)) return end(run, .@"tool-error", answer.payload);
    return endWith(run, try foundation.json.decode(log.CallOutcome, run.arena, answer.payload));
}

/// Where a call's fiber stands: waiting on the person's answer to its permission request; on a second model's verdict;
/// once it asked its tool, by the request's key and where its commands write; or once it started the fiber of a tool
/// that is a program, by the fiber's key. Before, its checkpoint is empty.
const At = struct { permission: ?Permitting = null, review: ?Judging = null, asked: ?Asking = null, started: ?[]const u8 = null };

/// A tool asked: by its request's key, and where the call's commands write.
const Asking = struct { key: []const u8, writes: Tool.Writes };

/// A permission request the call waits on: its key; what an always answer grants the project, and the project.
const Permitting = struct { key: []const u8, action: Tool.Action, save: []const []const u8, project: ?[]const u8 };

/// A review the call waits on: its key; and what the call does and its project, should the person be asked after all.
const Judging = struct { key: []const u8, access: Tool.Access, project: ?[]const u8 };

/// Weighs the call by what it does to the machine, as its thread's mode and its project's grants say: it goes ahead
/// where its weighing let it; asks the person first and sleeps until they answer; or has a second model judge it — the
/// person asked where the environment names no model to.
fn weigh(run: *Phase, table: *Table, input: Input, tool: ?Tool) !void {
    const thread = threads.threadOf(run.path);
    const manifest = try threads.manifestOf(run.runtime.volume, &run.arena, thread);
    const access = try table.accessOf(run.arena, input.name, manifest.workspace, input.arguments);
    const weighed = permissions.weigh(.{
        .access = access,
        .mode = manifest.mode,
        .workspace = manifest.workspace,
        .grants = try permissions.grantsOf(run.runtime, run.arena, manifest.project),
        .sandboxes = table.host.machine.sandboxes,
    });
    switch (weighed) {
        .go => |writes| return proceed(run, input, tool, writes),
        .ask => return askPerson(run, input, access.?, manifest.project, null),
        .review => {
            const environment = try settings.environmentOf(run.runtime.volume, &run.arena);
            const model = environment.review_model orelse return askPerson(run, input, access.?, manifest.project, "no model is named to judge calls in auto");
            const key = try run.mint();
            try run.request(review.request_name, key, review.Asked{ .thread = threads.idOf(thread), .model = model, .tool = input.name, .arguments = input.arguments });
            return run.waitForMail(At{ .review = .{ .key = key, .access = access.?, .project = manifest.project } }, key);
        },
    }
}

/// Asks the person whether the call may go ahead — why a second model would not let it, where one judged it — and
/// sleeps until they answer; an always grants `project`.
fn askPerson(run: *Phase, input: Input, access: Tool.Access, project: ?[]const u8, doubt: ?[]const u8) !void {
    const key = try run.mint();
    try run.request(permissions.request_name, key, permissions.Asked{ .tool = input.name, .arguments = .{ .text = input.arguments }, .access = access, .doubt = doubt });
    return run.waitForMail(At{ .permission = .{ .key = key, .action = access.action, .save = access.save, .project = project } }, key);
}

/// The call once a second model judged it: let go ahead, it goes; blocked, it ends rejected with why, the model told
/// how to go on — or, where the thread's calls were blocked too often, it asks the person; a review that came to
/// nothing asks the person too. What judging used is charged to the call; the thread's counts of blocked calls kept.
fn reviewed(run: *Phase, table: *Table, input: Input, tool: ?Tool, judging: Judging) !void {
    if (run.stop_handler) return endNoted(run, .stopped, "stopped before it was judged");
    const mail = try run.mailOf(judging.key) orelse return run.waitForMail(Phase.kept, judging.key);
    try run.take(judging.key);
    if (mail.interrupted()) return weigh(run, table, input, tool);
    if (!std.mem.eql(u8, mail.name, Request.answered_name)) {
        return askPerson(run, input, judging.access, judging.project, try run.arena.print("the call could not be judged: {s}", .{mail.payload}));
    }
    const verdict = try foundation.json.decode(review.Verdict, run.arena, mail.payload);
    if (verdict.usage) |used| {
        const counters = try used.counters(run.arena);
        if (counters.len > 0) try run.changes.charge(run.path, counters);
    }
    const thread = threads.threadOf(run.path);
    if (verdict.allow) {
        try run.changes.annotate(thread, &.{.{ .name = review.blocked_in_a_row, .value = "0" }});
        return proceed(run, input, tool, .anywhere);
    }
    const entry = try run.runtime.volume.stat(&run.arena, thread) orelse return error.ThreadGone;
    const in_a_row = countOf(entry, review.blocked_in_a_row) + 1;
    const in_all = countOf(entry, review.blocked_in_all) + 1;
    try run.changes.annotate(thread, &.{
        .{ .name = review.blocked_in_a_row, .value = try run.arena.print("{d}", .{in_a_row}) },
        .{ .name = review.blocked_in_all, .value = try run.arena.print("{d}", .{in_all}) },
    });
    if (in_a_row >= review.in_a_row_max or in_all >= review.in_all_max) return askPerson(run, input, judging.access, judging.project, verdict.reason);
    return endNoted(run, .rejected, try review.blockedNote(run.arena, verdict.reason));
}

/// The count an annotation of the thread's directory holds; none, nought.
fn countOf(entry: *const h.beak_entry, name: []const u8) u32 {
    const text = beak.annotationOf(entry, name) orelse return 0;
    return std.fmt.parseInt(u32, text, 10) catch 0;
}

/// The call once the person answered its permission request: it goes on, writing anywhere, where they let it — its
/// project granted its patterns where they answered always, the thread's count of calls blocked in a row begun again
/// — or ends rejected, with their words; stopped before they answered, it ends stopped.
fn permitted(run: *Phase, input: Input, tool: ?Tool, asked: Permitting) !void {
    if (run.stop_handler) return endNoted(run, .stopped, "stopped before the person answered");
    const mail = try run.mailOf(asked.key) orelse return run.waitForMail(Phase.kept, asked.key);
    try run.take(asked.key);
    if (!std.mem.eql(u8, mail.name, Request.answered_name)) return end(run, .@"tool-error", mail.payload);
    const answer = try foundation.json.decode(permissions.Answer, run.arena, mail.payload);
    switch (answer.reply) {
        .reject => {
            const told = if (answer.message) |message| try run.arena.print("the person rejected this call: {s}", .{message}) else "the person rejected this call";
            return endNoted(run, .rejected, told);
        },
        // A thread of no project has nothing to grant always: the call goes ahead once.
        .always => if (asked.project) |project| {
            try permissions.grant(&run.changes, run.arena, try permissions.grantsOf(run.runtime, run.arena, project), asked.action, asked.save);
        },
        .once => {},
    }
    try run.changes.annotate(threads.threadOf(run.path), &.{.{ .name = review.blocked_in_a_row, .value = "0" }});
    return proceed(run, input, tool, .anywhere);
}

/// Goes on with the call, its commands writing where `writes` says: asks its tool — a server's, where Siphon has none
/// of its name — or starts the fiber of a tool that is a program.
fn proceed(run: *Phase, input: Input, tool: ?Tool, writes: Tool.Writes) !void {
    const found = tool orelse return ask(run, input, writes);
    return switch (found.work) {
        .task => ask(run, input, writes),
        .program => |kind| startProgram(run, kind, input),
    };
}

/// Asks the call's tool, its commands writing where `writes` says, and sleeps until the answer comes.
fn ask(run: *Phase, input: Input, writes: Tool.Writes) !void {
    const key = try run.mint();
    const asked: Tool.Call = .{ .name = input.name, .arguments = input.arguments, .thread = threads.idOf(threads.threadOf(run.path)), .writes = writes };
    try run.request(Tool.request_name, key, asked);
    return run.waitForMail(At{ .asked = .{ .key = key, .writes = writes } }, key);
}

/// Starts the fiber of the program `kind`, the call's arguments its input, and sleeps until it ends.
fn startProgram(run: *Phase, kind: []const u8, input: Input) !void {
    const key = try run.mint();
    // The arguments are JSON already: they fit the tool's parameters.
    try run.start(key, kind, foundation.json.Raw{ .text = input.arguments });
    return run.waitForExit(At{ .started = key }, try beak.childPath(run.arena, run.path, key));
}

/// The call of a program, once its fiber `key` ended: its outcome the call's, the fiber reaped. Under a stop, which
/// reaches the program too, it is waited for as well, and its outcome says how far it went.
fn programEnded(run: *Phase, key: []const u8) !void {
    const path = try beak.childPath(run.arena, run.path, key);
    const entry = try run.runtime.volume.stat(&run.arena, path) orelse return error.CallGone;
    const ended = beak.outcomeOf(entry) orelse return run.waitForExit(Phase.kept, path);
    try run.changes.reap(path);
    return endWith(run, try outcomeOf(run.arena, ended));
}

/// The outcome of a call whose fiber ended as `ended` says: what it ended with, or, where it threw, its error as the
/// tool's.
pub fn outcomeOf(arena: Allocator, ended: *const h.beak_outcome) !log.CallOutcome {
    if (ended.has_result) return foundation.json.decode(log.CallOutcome, arena, beak.slice(ended.result));
    return .{ .status = .@"tool-error", .output = beak.slice(ended.@"error") };
}

/// Ends the call with `status` and a note of Siphon's own.
fn endNoted(run: *Phase, status: log.CallStatus, note: []const u8) !void {
    return endWith(run, try Tool.noted(run.arena, status, note));
}

fn end(run: *Phase, status: log.CallStatus, output: []const u8) !void {
    return endWith(run, .{ .status = status, .output = output });
}

/// Ends the call with `outcome`: done, or stopped where its stop handler ends it.
pub fn endWith(run: *Phase, outcome: log.CallOutcome) !void {
    return if (run.stop_handler) run.stopped(outcome) else run.done(outcome);
}
