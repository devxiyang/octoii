//! Scripts: the `execute` tool, by which the model writes TypeScript that calls its tools — in loops, at once, working
//! on their answers in code — run on the script engine, the tools under the global `tools`. A script is a fiber under its call, and its directory is all of it:
//! its input, the script; and its log `steps.jsonl`, what it was given — the tools and the time it began with, as its
//! first step found them, then before each later step the calls settled and the time — appended to as it goes, as an append-only file is replayed
//! to make again what it logged. A step is a `script` request, run in its task, never the loop: the script replayed from
//! its start, on an engine that lives for that step alone — the same code, seed, settlements and times, so it runs as it
//! first did — to what the step came to. Each call it makes is a call fiber of its own under it, as the model's calls
//! are, made and settled as every call is: logged under the script's call as it is made, as no reply holds it; and,
//! once it ended — a zombie, its outcome in its record — settled at the step after, its result logged under that call,
//! so its thread keeps what its scripts did as it keeps what its model did.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const typebox = @import("typebox");
const vocabulary = @import("vocabulary");
const runtime_ = @import("../runtime.zig");
const Runtime = runtime_.Runtime;
const Phase = runtime_.Phase;
const Request = runtime_.Request;
const beak = @import("../beak.zig");
const h = beak.h;
const threads = @import("../threads.zig");
const log = threads.log;
const Tool = @import("Tool.zig");
const Table = @import("Table.zig");
const calls = @import("calls.zig");
const script = @import("../script.zig");

/// The program of a script's fiber.
pub const script_program = "siphon.script";
/// The name of a script's step's request, which says no more than its name: what the step runs is its fiber's.
pub const step_request = "script";

/// The name of a script's log in its directory.
const steps_name = "steps.jsonl";

/// What a script's engine may hold, and the steps it may spend over all it runs — the engine's interrupt ticks, each
/// some ten thousand of its instructions.
const limits: script.Limits = .{ .memory_max = 64 * 1024 * 1024, .steps_max = 100_000 };

/// The global a script's tools are under, as `execute` tells the model: `tools.read(...)`.
const namespace = "tools";

pub const execute: Tool = .{
    .name = "execute",
    .description =
    \\Runs a script: TypeScript, the body of an async function, which may await and return. It calls your other tools as functions under `tools`, by their names — `await tools.read({ path: "a.md" })` — each with the arguments the tool takes; a call's answer is the tool's text, and a call the tool could not do is thrown as an Error whose message says why. What the script logs with console.log, then what it returns as JSON, is what you read; what it throws ends it, its stack at the script's lines and columns. Use it to call tools many times — in a loop, or at once with Promise.all — and to work on their answers in code before you read them.
    ,
    .parameters = typebox.of(Arguments),
    .work = .{ .program = script_program },
    // Its calls may act, each weighed as it is made: it runs alone, as no call of its can be told apart before.
    .alone = true,
};

/// Runs scripts on `runtime`, each given the tools of `table`, and adds the `execute` tool to it.
pub fn register(runtime: *Runtime, table: *Table) !void {
    try runtime.register(.{ .kind = script_program, .stop_handler = true, .phase = phase });
    try runtime.handle(step_request, .{ .context = table, .act = act });
    try table.add(execute);
}

/// What `execute` is called with, a script's input.
const Arguments = struct {
    code: []const u8,

    pub const schema = .{ .code = .{ .description = "The script's TypeScript" } };
};

/// The first line of a script's log: the tools it was given, by their names, and the time it started at.
const Start = struct { time: i64, tools: []const []const u8 };

/// Each later line: a step — the calls settled before it, and the time its clocks tell.
const Step = struct { time: i64, settled: []const Settled };

/// A call the script made, settled: by its id, fulfilled with its tool's text where the tool did what it was asked,
/// else rejected with why not.
const Settled = struct { id: u32, fulfilled: bool, text: []const u8 };

/// What a step came to: the calls it made, where the script waits on calls; the call's outcome, where it ended.
const Stepped = union(enum) { waiting: []const Made, ended: log.CallOutcome };

/// A call as the script made it: its id, its tool and the arguments it gave, as JSON.
const Made = struct { id: u32, tool: []const u8, arguments: []const u8 };

/// Where a script's fiber stands: the step it asked, by its request's key, while that runs; and the calls it started
/// and has yet to settle, in the order it made them.
const Checkpoint = struct { stepping: ?[]const u8 = null, started: []const Started = &.{} };

/// A call started: the script's id for it, and its fiber's key.
const Started = struct { id: u32, key: []const u8 };

fn phase(_: ?*anyopaque, run: *Phase) anyerror!void {
    if (run.checkpoint.len == 0) {
        if (run.stop_handler) return calls.endWith(run, try Tool.stoppedBefore(run.arena));
        return ask(run, .{});
    }
    var at = try foundation.json.decode(Checkpoint, run.arena, run.checkpoint);
    if (run.stop_handler) return stop(run, at);
    var made: []const Made = &.{};
    if (at.stepping) |key| {
        const answer = try run.mailOf(key) orelse return run.waitForMail(Phase.kept, key);
        try run.take(key);
        at.stepping = null;
        // A step changes nothing but its engine, gone with it: one cut off is asked again.
        if (answer.interrupted()) return ask(run, at);
        if (std.mem.eql(u8, answer.name, Request.failed_name)) return run.fail(answer.payload);
        const answered = try foundation.json.decode(Answer, run.arena, answer.payload);
        // A script's first step says what it began with, the first line of its log.
        if (answered.began) |began| try record(run, began);
        switch (answered.stepped) {
            .ended => |outcome| return calls.endWith(run, outcome),
            .waiting => |waiting| made = waiting,
        }
    }
    // The calls that ended while the script stepped, or since, are settled at its next step; the calls it made now are
    // made, none of them ended yet — all under the script's call.
    var writer: log.Writer = try .init(run, threads.threadOf(run.path));
    const under = (try calls.runningFor(run)).call_id;
    const settled = try settle(&writer, under, &at);
    at.started = try startCalls(&writer, under, at.started, made);
    if (settled.len == 0) return waitForCalls(run, at);
    try record(run, Step{ .time = run.time, .settled = settled });
    return ask(run, at);
}

/// The tools a script of the thread `tid` is given as it begins, by their names: every tool of Siphon's that is no
/// program, as a script's call starts none; then each tool of the MCP servers the thread may use, `<server>.<tool>`.
fn toolsOf(table: *Table, arena: Allocator, tid: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (table.own.items) |tool| if (tool.work == .task) try names.append(arena, tool.name);
    try names.appendSlice(arena, try table.servers.toolNames(arena, tid));
    return names.items;
}

/// Appends `line`, as JSON, to the script's log.
fn record(run: *Phase, line: anytype) !void {
    const text = try foundation.json.encode(run.arena, line);
    try run.changes.append(try beak.join(run.arena, run.path, steps_name), try std.mem.concat(run.arena, u8, &.{ text, "\n" }));
}

/// Asks the script's next step, the last its log holds, and sleeps until it is answered.
fn ask(run: *Phase, at: Checkpoint) !void {
    const key = try run.mint();
    try run.request(step_request, key, null);
    var asking = at;
    asking.stepping = key;
    return run.waitForMail(asking, key);
}

/// Under a stop, the script ends once the step it asked has its answer, as every request has one before its fiber
/// goes, and once the calls it started — stopped with it, as a stop reaches every call that runs — ended, each settled
/// as it ends, as a turn waits for its calls.
fn stop(run: *Phase, at: Checkpoint) !void {
    var left = at;
    if (left.stepping) |key| {
        if (try run.mailOf(key) == null) return run.waitForMail(Phase.kept, key);
        try run.take(key);
        left.stepping = null;
    }
    if (left.started.len > 0) {
        var writer: log.Writer = try .init(run, threads.threadOf(run.path));
        _ = try settle(&writer, (try calls.runningFor(run)).call_id, &left);
        if (left.started.len > 0) return waitForCalls(run, left);
    }
    return calls.endWith(run, try Tool.noted(run.arena, .stopped, "stopped as it ran"));
}

/// The calls the script made under the call `under` that ended, each settled by `writer` as it came out, in the order
/// the script made them; the others left in `at`.
fn settle(writer: *log.Writer, under: []const u8, at: *Checkpoint) ![]const Settled {
    const arena = writer.phase.arena;
    var running: std.ArrayList(Started) = .empty;
    var settled: std.ArrayList(Settled) = .empty;
    for (at.started) |call| {
        const outcome = try calls.settle(writer, call.key, under, call.key) orelse {
            try running.append(arena, call);
            continue;
        };
        try settled.append(arena, .{ .id = call.id, .fulfilled = outcome.status == .ok, .text = outcome.output });
    }
    at.started = running.items;
    return settled.items;
}

/// `started`, and then each call of `made` made under the call `under` by `writer`, Siphon's id of each its id: a call
/// fiber of its own under the script, as the model's calls are.
fn startCalls(writer: *log.Writer, under: []const u8, started: []const Started, made: []const Made) ![]const Started {
    if (made.len == 0) return started;
    const run = writer.phase;
    const all = try run.arena.alloc(Started, started.len + made.len);
    @memcpy(all[0..started.len], started);
    const asked = try run.arena.alloc(vocabulary.items.FunctionCall, made.len);
    for (made, asked, all[started.len..]) |call, *function_call, *started_call| {
        const key = try run.mint();
        function_call.* = .{ .call_id = key, .name = call.tool, .arguments = call.arguments };
        started_call.* = .{ .id = call.id, .key = key };
    }
    try calls.makeUnder(writer, under, asked);
    return all;
}

/// Sleeps until a call of the script ends: the first of their directories to change, as a process that ends changes
/// its own.
fn waitForCalls(run: *Phase, at: Checkpoint) !void {
    // The engine says a script waits only on calls of its own that are yet to settle.
    if (at.started.len == 0) return error.ScriptWaitsOnNothing;
    const paths = try run.arena.alloc([]const u8, at.started.len);
    for (at.started, paths) |call, *path| path.* = try beak.childPath(run.arena, run.path, call.key);
    return run.waitForAny(at, paths);
}

fn act(context: ?*anyopaque, request: *Request) anyerror!void {
    const table: *Table = @ptrCast(@alignCast(context.?));
    try request.answer(try replayed(table, request));
}

/// The step `request` asks, its script replayed from its directory: from its start, each step its log holds settled and
/// run — every one but the last coming to a wait on calls, as it first did — then what the last came to. A script with
/// no log yet begins: at the time it is now, with the tools there are, both told for the log's first line.
fn replayed(table: *Table, request: *Request) !Answer {
    const arena = request.arena();
    const volume = request.runtime.volume;
    const input = try volume.readAll(&arena, try beak.join(arena, request.process, h.BEAK_INPUT_NAME));
    const code = (try foundation.json.decode(Arguments, arena, input)).code;
    const logged = volume.readAll(&arena, try beak.join(arena, request.process, steps_name)) catch |err| switch (err) {
        error.NotFound => {
            const began: Start = .{ .time = request.runtime.now(), .tools = try toolsOf(table, arena, threads.idOf(threads.threadOf(request.process))) };
            const engine, const state = try begun(arena, code, began, request.process);
            defer engine.end();
            return .{ .began = began, .stepped = try cameTo(table, request, engine, state) };
        },
        else => return err,
    };
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, logged, "\n"), '\n');
    const engine, var state = try begun(arena, code, try foundation.json.decode(Start, arena, lines.first()), request.process);
    defer engine.end();
    while (lines.next()) |line| {
        if (state != .waiting) return .{ .stepped = not_replayed };
        // What the step before made was started then.
        _ = try engine.calls(arena);
        const step = try foundation.json.decode(Step, arena, line);
        if (!try settleOn(arena, engine, step.settled)) return .{ .stepped = not_replayed };
        state = engine.step(step.time);
    }
    return .{ .stepped = try cameTo(table, request, engine, state) };
}

/// The script's engine, begun as `began` says and run to its first wait at the time it began; one that did not compile
/// ended there.
fn begun(arena: Allocator, code: []const u8, began: Start, process: []const u8) !struct { script.Script, script.Status } {
    const engine = try script.Script.start(arena, code, .{ .namespace = namespace, .functions = began.tools, .limits = limits, .time = began.time, .seed = seedOf(process) });
    return .{ engine, if (engine.started == .done) engine.step(began.time) else engine.started };
}

/// Settles each call of `settled` on `engine`: false where one is of no call the script waits on.
fn settleOn(arena: Allocator, engine: script.Script, settled: []const Settled) !bool {
    for (settled) |call| {
        // A call fulfilled is given its tool's text, as JSON; one rejected, an Error of why.
        const given = if (call.fulfilled) try foundation.json.encode(arena, call.text) else call.text;
        engine.settle(call.id, call.fulfilled, given) catch return false;
    }
    return true;
}

/// What a step came to, standing at `state`: the calls it made, where it waits on them; else how it ended.
fn cameTo(table: *Table, request: *Request, engine: script.Script, state: script.Status) !Stepped {
    const arena = request.arena();
    if (state == .waiting) {
        const taken = try engine.calls(arena);
        const made = try arena.alloc(Made, taken.len);
        for (taken, made) |call, *each| each.* = .{ .id = call.id, .tool = call.function, .arguments = call.arguments };
        return .{ .waiting = made };
    }
    const came = try engine.result(arena) orelse return error.ScriptUnfinished;
    return .{ .ended = try outcomeOf(table, request, try engine.output(arena), came) };
}

/// What a step's request is answered with: what the step came to, and, for a script's first, what it began with.
const Answer = struct { began: ?Start = null, stepped: Stepped };

/// What a replay that goes otherwise than the script first ran comes to: it cannot go on.
const not_replayed: Stepped = .{ .ended = .{ .status = .@"tool-error", .output = "ReplayError: the script ran otherwise than it first did, so it cannot go on" } };

/// The seed of a script's random numbers: of its fiber's key, the same at every step.
fn seedOf(path: []const u8) u64 {
    return std.hash.Wyhash.hash(0, beak.keyOf(path));
}

/// The call's outcome once its script ended: the lines it wrote, then what it returned, as JSON — done — or what it
/// threw, its name and message, then its stack — the tool's error.
fn outcomeOf(table: *Table, request: *Request, lines: []const []const u8, came: script.Result) !log.CallOutcome {
    const arena = request.arena();
    var out: std.Io.Writer.Allocating = .init(arena);
    for (lines) |line| try out.writer.print("{s}\n", .{line});
    switch (came) {
        .returned => |value| try out.writer.writeAll(value),
        .threw => |thrown| {
            try out.writer.print("{s}: {s}", .{ thrown.name, thrown.message });
            const stack = std.mem.trimEnd(u8, thrown.stack, "\n");
            if (stack.len > 0) try out.writer.print("\n{s}", .{stack});
        },
    }
    return .{ .status = if (came == .returned) .ok else .@"tool-error", .output = try Tool.bounded(&table.host, arena, request.key, out.written()) };
}
