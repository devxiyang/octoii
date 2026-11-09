//! Siphon's runtime, its kernel: one volume of Beak's, the programs its fibers run, dispatched by Beak from the loop,
//! and the requests they make, acted on as Beak tells of them — each by the handler of its name in a task of its own,
//! or answered by a person. It keeps the platform the host gave and runs on its io: `start` runs the loop in a task of
//! its own, waiting on the runtime's event set between pumps; a host that drives its own loop calls `pump` and is told
//! when to call again.
//!
//! The runtime is single-threaded: its loop alone touches what it keeps and what the parts on it keep — it runs the
//! phases, the work other tasks post and its listener's turn at each pump's end, one after another, so none lands
//! inside another. Any other task reaches it by posting work, which wakes the loop, or by publishing what streams,
//! which the loop tells its listener. The tasks acting on requests answer through Beak, which serializes its calls.
//!
//! The runtime is told what changes, never looks for it: as each pump ends it reads on in its volume's journal from the
//! last commit it told of, as a replica reads on from its offset — Beak's records among the changes, processes, their
//! mail and requests, which no file system's watch shows — and tells its listener the paths each commit changed.
const Runtime = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const foundation = @import("foundation");
const typebox = @import("typebox");
const beak = @import("../beak.zig");
const h = beak.h;
const Phase = @import("Phase.zig");
const Request = @import("Request.zig");
const Task = @import("Task.zig");
const Waits = @import("Waits.zig");
const Changes = @import("Changes.zig");
const Streams = @import("Streams.zig");
const Collection = @import("Collection.zig");

const log = std.log.scoped(.siphon);

allocator: Allocator,
host: Host,
volume: beak.Volume,
/// The runtime's own event set: its volume, which a commit wakes, so the loop waits on nothing else.
set: h.beak_handle,
/// The latest commit whose changes the listener was told of: the journal is read on from it.
told: u64,
/// What streams of each request while its task acts on it, for one who follows its topic later.
streams: Streams,
/// How the volume is collected as it grows.
collection: Collection,
budget: usize,
/// The work other tasks post the loop, taken as it pumps.
inbox: Io.Queue(Work),
inbox_buffer: []Work,
/// The time of the dispatch running, which its phases are given.
time: i64 = 0,
/// Each program registered, where Beak's calls of its phase find it.
programs: std.ArrayList(*Registered) = .empty,
handlers: std.StringHashMapUnmanaged(Request.Handler) = .empty,
/// The requests a person answers, as no handler acts on them — by their names, each with what its answer fits.
asked_of_person: std.StringHashMapUnmanaged(Answering) = .empty,
/// The requests being acted on. The loop alone changes it.
acting: std.ArrayList(*Request) = .empty,
/// The jobs whose tasks run, or ended and wait to be reaped. The loop alone changes it.
jobs: std.ArrayList(*Running) = .empty,
/// What hears from the loop; none until one listens.
listener: ?Listener = null,
/// The handles the loop watches besides its volume — commands, watches — each with what it tells of their events.
watched: std.AutoHashMapUnmanaged(h.beak_handle, Watcher) = .empty,
loop: ?Io.Future(void) = null,
stopping: std.atomic.Value(bool) = .init(false),
/// Set as the runtime closes: what a cancelled task answers then is not committed, so its request waits on, and comes
/// back to its fiber interrupted when the volume opens again, as though the host had ended.
closing: std.atomic.Value(bool) = .init(false),

/// Work a task posts the loop, as a workqueue takes it: run as the loop pumps, in the order posted, or dropped where the
/// loop never runs it, as the runtime closes; either frees what the work holds.
pub const Work = struct {
    context: *anyopaque,
    run: *const fn (context: *anyopaque) void,
    drop: *const fn (context: *anyopaque) void,
};

/// Work done off the loop in a task, as a request's is — the network, a provider's server, a program run to its end:
/// started by the loop, and reaped by it once its task ended, `finish` then run on the loop with what the work gave,
/// as Redis replies to a client its module unblocked; as the runtime closes, stopped and waited for, then dropped,
/// never finished.
pub const Job = struct {
    context: *anyopaque,
    /// Does the work, in the job's task, sleeping on `waits` for news of what it starts, which a stop wakes.
    run: *const fn (context: *anyopaque, waits: *Waits) void,
    /// Takes what the work gave, on the loop, and lets go of the context.
    finish: *const fn (context: *anyopaque) void,
    /// Lets go of the context unfinished.
    drop: *const fn (context: *anyopaque) void,
};

/// A job, and the task that does it.
const Running = struct { job: Job, task: Task };

/// What hears from the loop: the paths each commit changed — the empty path where every one may have — what was
/// published, by its offset in its stream, as a channel's subscriber hears it, and the end of each pump, when it does
/// what waits for that; whether more is ready at once.
pub const Listener = struct {
    context: *anyopaque,
    changed: *const fn (context: *anyopaque, paths: []const []const u8) void,
    published: *const fn (context: *anyopaque, topic: []const u8, key: []const u8, offset: u64, data: []const u8) void,
    pumped: *const fn (context: *anyopaque) bool,
};

/// What hears of the events of a handle the loop watches — a command's output, its terminal's title and its end — as
/// each pump polls them, on the loop: as epoll hands back the data a descriptor was added with.
pub const Watcher = struct {
    context: *anyopaque,
    event: *const fn (context: *anyopaque, event: *const h.beak_event) void,
};

/// How many works wait in the inbox at most; a task that posts to a full one waits. A pump takes as many at most, so it
/// takes what was posted before it began, and no more than its bound.
const inbox_max = 4096;

/// What the runtime is given by the host: its io and clock, and where its volume is kept — never state it keeps.
pub const Host = struct {
    io: Io,
    /// None: the io's real clock.
    clock: ?foundation.time.Clock = null,
    /// Where the volume is kept.
    device: Device = .memory,
};

pub const Device = union(enum) {
    /// Beak's log, in the directory at the path, made where it is missing.
    directory: []const u8,
    /// Memory, gone with Siphon.
    memory,
};

pub const Options = struct {
    /// How many phases a pump runs at most, so the requests they make are acted on between.
    budget: usize = 64,
    collection: Collection.Options = .{},
};

/// What runs the fibers of one kind: its phase, given each run, gives back the changes and the ending Beak commits
/// together.
pub const Program = struct {
    kind: []const u8,
    version: u32 = 1,
    /// Whether its fibers run a stop handler — a phase with `Phase.stop_handler` — once asked to stop, before they end.
    stop_handler: bool = false,
    /// How many times a phase that threw runs again before its fiber fails.
    retries: u32 = 0,
    context: ?*anyopaque = null,
    phase: *const fn (context: ?*anyopaque, phase: *Phase) anyerror!void,
};

const Registered = struct { runtime: *Runtime, program: Program };

/// What a pump did: whether more is ready at once, and when the runtime is next due; null for nothing until news comes.
pub const Pumped = struct { more: bool, next: ?i64 };

/// How long the loop waits after a pump failed, before it tries again.
const failed_pump_wait_ms = 1000;

/// Opens the runtime on the platform `host` gives: its volume on the host's device, and its event set; what commits
/// change is told from the volume's latest commit on.
pub fn open(allocator: Allocator, host: Host, options: Options) !*Runtime {
    const runtime = try allocator.create(Runtime);
    errdefer allocator.destroy(runtime);
    const device: h.beak_device = switch (host.device) {
        .directory => |path| .{ .type = h.BEAK_DEVICE_DIRECTORY, .path = beak.bytes(path) },
        .memory => .{ .type = h.BEAK_DEVICE_MEMORY, .path = beak.bytes("") },
    };
    const volume = try beak.Volume.open(device, foundation.time.nowMs(host.io, host.clock));
    errdefer volume.close();
    var set: h.beak_handle = 0;
    try beak.check(h.beak_events_open(&set));
    errdefer _ = h.beak_close(set);
    try beak.check(h.beak_events_add(set, volume.handle));
    var arena_allocator: std.heap.ArenaAllocator = .init(allocator);
    defer arena_allocator.deinit();
    const latest = (try volume.journal(&arena_allocator.allocator(), 0, 0)).latest;
    const inbox_buffer = try allocator.alloc(Work, inbox_max);
    errdefer allocator.free(inbox_buffer);
    runtime.* = .{
        .allocator = allocator,
        .host = host,
        .volume = volume,
        .set = set,
        .told = latest,
        .streams = .{ .allocator = allocator },
        .collection = .{ .options = options.collection, .base = try volume.usage() },
        .budget = options.budget,
        .inbox = .init(inbox_buffer),
        .inbox_buffer = inbox_buffer,
    };
    return runtime;
}

/// Stops the loop, cancels the tasks acting on requests — whose requests wait on, answered when the volume opens again —
/// drops the work posted and not taken, and closes the volume.
pub fn close(runtime: *Runtime) void {
    const allocator = runtime.allocator;
    runtime.stop();
    runtime.closing.store(true, .release);
    for (runtime.acting.items) |request| {
        request.task.stop();
        request.deinit();
    }
    runtime.acting.deinit(allocator);
    for (runtime.jobs.items) |running| {
        running.task.stop();
        running.job.drop(running.job.context);
        running.task.deinit();
        allocator.destroy(running);
    }
    runtime.jobs.deinit(allocator);
    // What was posted and not taken is let go of, never run: no work runs as the runtime closes.
    runtime.inbox.close(runtime.host.io);
    var left: [64]Work = undefined;
    while (true) {
        const count = runtime.inbox.get(runtime.host.io, &left, 0) catch break;
        if (count == 0) break;
        for (left[0..count]) |work| work.drop(work.context);
    }
    allocator.free(runtime.inbox_buffer);
    runtime.watched.deinit(allocator);
    _ = h.beak_close(runtime.set);
    runtime.streams.deinit();
    runtime.volume.close();
    runtime.forgetPrograms();
    runtime.forgetHandlers();
    allocator.destroy(runtime);
}

/// Posts `work` to the loop, from any task, and wakes it; a full inbox is waited on. Work the loop will never run, as
/// the runtime closes, is dropped.
pub fn post(runtime: *Runtime, work: Work) void {
    runtime.inbox.putOneUncancelable(runtime.host.io, work) catch return work.drop(work.context);
    runtime.wake();
}

/// Publishes `data` on `topic` to the stream of `key`, from any task, each copied: the loop keeps it in the stream, by
/// its offset, and tells its listener, as Redis's PUBLISH tells a channel's subscribers.
pub fn publish(runtime: *Runtime, topic: []const u8, key: []const u8, data: []const u8) Allocator.Error!void {
    const published = try Published.make(runtime, topic, key, data);
    runtime.post(.{ .context = published, .run = Published.run, .drop = Published.drop });
}

/// Ends the stream of `key`, from any task: the loop lets go of it once what was published before is told, as work is
/// taken in the order it is posted.
pub fn endStream(runtime: *Runtime, key: []const u8) Allocator.Error!void {
    const ended = try Published.make(runtime, "", key, "");
    runtime.post(.{ .context = ended, .run = Published.end, .drop = Published.drop });
}

/// What was published, as the loop tells it: the topic, the key and the data, copied into one allocation.
const Published = struct {
    runtime: *Runtime,
    bytes: []u8,
    topic: []const u8,
    key: []const u8,
    data: []const u8,

    fn make(runtime: *Runtime, topic: []const u8, key: []const u8, data: []const u8) Allocator.Error!*Published {
        const allocator = runtime.allocator;
        const bytes = try std.mem.concat(allocator, u8, &.{ topic, key, data });
        errdefer allocator.free(bytes);
        const published = try allocator.create(Published);
        errdefer allocator.destroy(published);
        published.* = .{ .runtime = runtime, .bytes = bytes, .topic = bytes[0..topic.len], .key = bytes[topic.len..][0..key.len], .data = bytes[topic.len + key.len ..] };
        return published;
    }

    fn run(context: *anyopaque) void {
        const published: *Published = @ptrCast(@alignCast(context));
        defer drop(context);
        // An event that cannot be kept is told all the same, by no offset a reader takes.
        const offset = published.runtime.streams.append(published.topic, published.key, published.data) catch std.math.maxInt(u64);
        const listener = published.runtime.listener orelse return;
        listener.published(listener.context, published.topic, published.key, offset, published.data);
    }

    fn end(context: *anyopaque) void {
        const ended: *Published = @ptrCast(@alignCast(context));
        defer drop(context);
        ended.runtime.streams.end(ended.key);
    }

    fn drop(context: *anyopaque) void {
        const published: *Published = @ptrCast(@alignCast(context));
        const allocator = published.runtime.allocator;
        allocator.free(published.bytes);
        allocator.destroy(published);
    }
};

/// Has `listener` hear from the loop, in place of one before.
pub fn listen(runtime: *Runtime, listener: Listener) void {
    runtime.listener = listener;
}

/// Runs the work other tasks posted before the pump, as much as the inbox holds at most; whether there was any.
fn takeInbox(runtime: *Runtime) bool {
    var works: [64]Work = undefined;
    var took: usize = 0;
    while (took < inbox_max) {
        const count = runtime.inbox.get(runtime.host.io, works[0..@min(works.len, inbox_max - took)], 0) catch break;
        if (count == 0) break;
        took += count;
        for (works[0..count]) |work| work.run(work.context);
    }
    return took > 0;
}

fn forgetHandlers(runtime: *Runtime) void {
    var names = runtime.handlers.keyIterator();
    while (names.next()) |name| runtime.allocator.free(name.*);
    runtime.handlers.deinit(runtime.allocator);
    var asked = runtime.asked_of_person.keyIterator();
    while (asked.next()) |name| runtime.allocator.free(name.*);
    runtime.asked_of_person.deinit(runtime.allocator);
}

fn forgetPrograms(runtime: *Runtime) void {
    for (runtime.programs.items) |registered| {
        runtime.allocator.free(registered.program.kind);
        runtime.allocator.destroy(registered);
    }
    runtime.programs.deinit(runtime.allocator);
}

/// The time, on the host's clock.
pub fn now(runtime: *const Runtime) i64 {
    return foundation.time.nowMs(runtime.host.io, runtime.host.clock);
}

/// Registers `program`, whose fibers Beak then dispatches to its phase; its context lives as long as the runtime.
pub fn register(runtime: *Runtime, program: Program) !void {
    const allocator = runtime.allocator;
    const registered = try allocator.create(Registered);
    errdefer allocator.destroy(registered);
    registered.* = .{ .runtime = runtime, .program = program };
    registered.program.kind = try allocator.dupe(u8, program.kind);
    errdefer allocator.free(registered.program.kind);
    try runtime.programs.append(allocator, registered);
    errdefer _ = runtime.programs.pop();
    try beak.check(h.beak_volume_register(runtime.volume.handle, beak.bytes(program.kind), program.version, program.stop_handler, program.retries, runPhase, registered));
}

/// The version of the program of `kind`; null for one not registered.
pub fn versionOf(runtime: *const Runtime, kind: []const u8) ?u32 {
    for (runtime.programs.items) |registered| if (std.mem.eql(u8, registered.program.kind, kind)) return registered.program.version;
    return null;
}

/// Acts on every request of `name` with `handler`, whose context lives as long as the runtime. A request of a name no
/// handler acts on waits for its answer to be given.
pub fn handle(runtime: *Runtime, name: []const u8, handler: Request.Handler) !void {
    const slot = try runtime.handlers.getOrPut(runtime.allocator, name);
    if (!slot.found_existing) {
        slot.key_ptr.* = runtime.allocator.dupe(u8, name) catch |err| {
            runtime.handlers.removeByPtr(slot.key_ptr);
            return err;
        };
    }
    slot.value_ptr.* = handler;
}

/// What a person's answer to a request fits: a JSON Schema the same for every request of its name, or one made from
/// what the request asks — its payload — as the answer to a question is one of the choices it offers.
pub const Answering = union(enum) {
    fixed: []const u8,
    made: *const fn (arena: Allocator, payload: []const u8) anyerror![]const u8,

    /// The JSON Schema the answer to a request of `payload` fits.
    pub fn schemaOf(answering: Answering, arena: Allocator, payload: []const u8) ![]const u8 {
        return switch (answering) {
            .fixed => |schema| schema,
            .made => |make| make(arena, payload),
        };
    }
};

/// Has every request of `name` answered by a person, as no handler acts on it: with JSON that fits what `answering`
/// says, whose schema outlives the runtime.
pub fn askPerson(runtime: *Runtime, name: []const u8, answering: Answering) !void {
    const slot = try runtime.asked_of_person.getOrPut(runtime.allocator, name);
    if (!slot.found_existing) slot.key_ptr.* = runtime.allocator.dupe(u8, name) catch |err| {
        runtime.asked_of_person.removeByPtr(slot.key_ptr);
        return err;
    };
    slot.value_ptr.* = answering;
}

/// The JSON Schema a person's answer to a request of `name` that asks `payload` fits; null where no person answers it,
/// a handler acting on it.
pub fn answerSchemaOf(runtime: *const Runtime, arena: Allocator, name: []const u8, payload: []const u8) !?[]const u8 {
    const answering = runtime.asked_of_person.get(name) orelse return null;
    return try answering.schemaOf(arena, payload);
}

/// What came of a person's answer: given to its request, or why it does not fit what the request asks.
pub const Answered = union(enum) { given, unfit: []const u8 };

/// Gives a person's answer `given` to the request of `key` the fiber at `process` made — one of those a person answers —
/// where it fits what the request asks: the fiber's mail, committed as it returns.
pub fn answer(runtime: *Runtime, arena: Allocator, process: []const u8, key: []const u8, given: foundation.json.Raw) !Answered {
    const request_path = try std.mem.concat(arena, u8, &.{ process, "/", h.BEAK_REQUEST_KIND, ":", key });
    const made = try runtime.volume.stat(&arena, request_path) orelse return error.NoSuchRequest;
    const directory = made.directory orelse return error.DamagedRequest;
    const name = beak.labelOf(directory.*.labels, directory.*.label_count, h.BEAK_REQUEST_KIND) orelse return error.DamagedRequest;
    const answering = runtime.asked_of_person.get(name) orelse return error.NotAskedOfPerson;
    const payload = runtime.volume.readAll(&arena, try beak.join(arena, request_path, h.BEAK_PAYLOAD_NAME)) catch |err| switch (err) {
        error.NotFound => "",
        else => return err,
    };
    const schema = try answering.schemaOf(arena, payload);
    const problems = try typebox.problems(arena, try std.json.parseFromSliceLeaky(std.json.Value, arena, schema, .{}), try std.json.parseFromSliceLeaky(std.json.Value, arena, given.text, .{}));
    if (problems.len > 0) return .{ .unfit = try typebox.shown(arena, problems) };
    const fiber = try runtime.volume.stat(&arena, process) orelse return error.NoSuchRequest;
    const record = (fiber.directory orelse return error.DamagedRequest).*.process orelse return error.DamagedRequest;
    var changes: Changes = .{ .arena = arena };
    try changes.answer(process, record.*.started, key, Request.answered_name, given.text);
    _ = try runtime.commit(&changes);
    return .given;
}

/// Commits `changes` now, durable as it returns: the process ending does not undo it, and the runtime syncs against no
/// power loss.
pub fn commit(runtime: *Runtime, changes: *const Changes) !u64 {
    return runtime.volume.commit(runtime.now(), changes.items());
}

/// Runs the phases due, up to the budget, and the work other tasks posted; acts on what Beak told of since — a request
/// made, in a task of its own; one a stop cut off; the paths commits changed, which its listener is told — then gives
/// its listener its turn at the pump's end.
pub fn pump(runtime: *Runtime) !Pumped {
    runtime.reap();
    runtime.time = runtime.now();
    var dispatched: h.beak_dispatched = undefined;
    try beak.check(h.beak_volume_dispatch(runtime.volume.handle, runtime.time, runtime.budget, &dispatched));
    const took = runtime.takeInbox();
    var arena_allocator: std.heap.ArenaAllocator = .init(runtime.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const allocator = beak.outputs(&arena);
    var events: [*c]h.beak_event = null;
    var count: usize = 0;
    var next: h.beak_optional = undefined;
    try beak.check(h.beak_events_poll(runtime.set, runtime.time, &allocator, &events, &count, &next));
    if (count > 0) for (events[0..count]) |*event| runtime.actOn(event);
    const told = runtime.told;
    try runtime.tellChanges(arena);
    // What the volume keeps grows with commits alone.
    if (runtime.told != told) Collection.weigh(runtime);
    const more = if (runtime.listener) |listener| listener.pumped(listener.context) else false;
    return .{ .more = dispatched.more or took or more, .next = beak.get(next) };
}

/// Runs the loop in a task of its own on the io: it pumps while more is ready, and between, waits on the runtime's event
/// set until it is next due or news comes.
pub fn start(runtime: *Runtime) !void {
    if (runtime.loop != null) return;
    runtime.stopping.store(false, .release);
    runtime.loop = try runtime.host.io.concurrent(runLoop, .{runtime});
}

/// Ends the loop `start` began, once its pump is done.
pub fn stop(runtime: *Runtime) void {
    var loop = runtime.loop orelse return;
    runtime.stopping.store(true, .release);
    runtime.wake();
    loop.await(runtime.host.io);
    runtime.loop = null;
}

/// Ends a wait of the loop's, from any task, so it pumps again.
pub fn wake(runtime: *Runtime) void {
    _ = h.beak_events_wake(runtime.set);
}

/// Waits until news may have come — a commit, a time due, a wake — or `timeout_ms` passes.
pub fn waitForNews(runtime: *Runtime, timeout_ms: u32) void {
    var ready = false;
    _ = h.beak_events_wait(runtime.set, timeout_ms, &ready);
}

fn runLoop(runtime: *Runtime) void {
    while (!runtime.stopping.load(.acquire)) {
        const pumped = runtime.pump() catch |err| {
            log.err("a pump failed: {s}", .{@errorName(err)});
            runtime.waitForNews(failed_pump_wait_ms);
            continue;
        };
        if (pumped.more) continue;
        runtime.waitForNews(runtime.untilNext(pumped.next));
    }
}

/// How long until `next`, in milliseconds a wait takes: none for now, the longest for never.
fn untilNext(runtime: *const Runtime, next: ?i64) u32 {
    const at = next orelse return std.math.maxInt(u32);
    return @intCast(std.math.clamp(at - runtime.now(), 0, std.math.maxInt(u32)));
}

fn actOn(runtime: *Runtime, event: *const h.beak_event) void {
    switch (event.type) {
        h.BEAK_EVENT_REQUEST => runtime.begin(event),
        h.BEAK_EVENT_INTERRUPTED => runtime.interrupt(beak.slice(event.process), beak.slice(event.key)),
        else => if (runtime.watched.get(event.handle)) |watcher| watcher.event(watcher.context, event),
    }
}

/// Watches `watched` — a command, or a watch — in the loop's event set: each of its events told to `watcher` as the loop
/// pumps, till it is let go of. From the loop alone.
pub fn watch(runtime: *Runtime, watched: h.beak_handle, watcher: Watcher) !void {
    try runtime.watched.put(runtime.allocator, watched, watcher);
    errdefer _ = runtime.watched.remove(watched);
    try beak.check(h.beak_events_add(runtime.set, watched));
}

/// Tells of `watched`'s events no more, as its owner lets go of it: a handle closed leaves the set. From the loop alone.
pub fn unwatch(runtime: *Runtime, watched: h.beak_handle) void {
    _ = runtime.watched.remove(watched);
}

/// How many change sets a read of the journal takes at most.
const journal_page = 256;

/// Tells the listener the paths the commits since the last it told of changed, read on in the volume's journal; where
/// the journal no longer holds what came next, the root, for every path, as a watch that overflowed says so.
fn tellChanges(runtime: *Runtime, arena: Allocator) !void {
    const listener = runtime.listener orelse {
        runtime.told = (try runtime.volume.journal(&arena, runtime.told, 0)).latest;
        return;
    };
    while (true) {
        const journal = try runtime.volume.journal(&arena, runtime.told, journal_page);
        if (journal.latest <= runtime.told) return;
        if (journal.oldest == null or journal.oldest.? > runtime.told + 1) {
            runtime.told = journal.latest;
            return listener.changed(listener.context, &.{""});
        }
        var paths: std.ArrayList([]const u8) = .empty;
        for (journal.sets) |set| for (set.changes[0..set.count]) |each| try paths.append(arena, beak.slice(each.path));
        runtime.told = journal.sets[journal.sets.len - 1].seq;
        listener.changed(listener.context, paths.items);
    }
}

/// Starts acting on the request `made` tells of, where a handler acts on its name; one that cannot start is answered
/// failed. One retold, made before the volume opened, is answered interrupted, for the fiber that asked to decide: the
/// host that ended may have acted on it, and nothing is acted on twice. One no handler acts on waits for its answer to
/// be given, retold or not, as a person's does.
fn begin(runtime: *Runtime, made: *const h.beak_event) void {
    const handler = runtime.handlers.get(beak.slice(made.name)) orelse return;
    if (made.retold) return runtime.answerWith(made, Request.interrupted_name, "");
    const request = Request.init(runtime, made, handler) catch |err| return runtime.answerWith(made, Request.failed_name, @errorName(err));
    runtime.acting.append(runtime.allocator, request) catch |err| {
        request.deinit();
        return runtime.answerWith(made, Request.failed_name, @errorName(err));
    };
    request.task.start(Request.run, .{request}) catch |err| {
        _ = runtime.acting.pop();
        request.deinit();
        return runtime.answerWith(made, Request.failed_name, @errorName(err));
    };
}

/// Cuts off the request of `key` that `process` made, as a signal is sent, never waiting: its task, cancelled from one
/// of its own, answers at once with what has come, and the request is reaped once that is done. Where no task can be
/// started to cut it off, it is cut off here, waiting.
fn interrupt(runtime: *Runtime, process: []const u8, key: []const u8) void {
    for (runtime.acting.items, 0..) |request, index| {
        if (!std.mem.eql(u8, request.process, process) or !std.mem.eql(u8, request.key, key)) continue;
        if (request.task.canceller != null) return;
        request.task.cut() catch |err| {
            log.warn("the request {s} of {s} is cut off waiting: {s}", .{ request.key, request.process, @errorName(err) });
            _ = runtime.acting.swapRemove(index);
            request.task.stop();
            request.deinit();
        };
        return;
    }
}

/// Frees the requests done with, as a parent reaps its children.
fn reap(runtime: *Runtime) void {
    var index = runtime.acting.items.len;
    while (index > 0) {
        index -= 1;
        const request = runtime.acting.items[index];
        if (!request.task.ended()) continue;
        _ = runtime.acting.swapRemove(index);
        request.task.join();
        request.deinit();
    }
    index = 0;
    while (index < runtime.jobs.items.len) {
        const running = runtime.jobs.items[index];
        if (!running.task.ended()) {
            index += 1;
            continue;
        }
        // In the order they were started, so jobs finish as they were asked where they end at once.
        _ = runtime.jobs.orderedRemove(index);
        running.task.join();
        running.job.finish(running.job.context);
        running.task.deinit();
        runtime.allocator.destroy(running);
    }
}

/// Starts `job` in a task of its own, from the loop; one that cannot start is dropped, and why told.
pub fn spawn(runtime: *Runtime, job: Job) error{ OutOfMemory, ConcurrencyUnavailable }!void {
    errdefer job.drop(job.context);
    const running = try runtime.allocator.create(Running);
    errdefer runtime.allocator.destroy(running);
    running.* = .{ .job = job, .task = .{ .runtime = runtime } };
    try runtime.jobs.append(runtime.allocator, running);
    errdefer _ = runtime.jobs.pop();
    try running.task.start(runJob, .{running});
}

fn runJob(running: *Running) void {
    running.job.run(running.job.context, &running.task.waits);
}

/// Answers the request `made` tells of, as no task acts on it, with mail named `name` carrying `payload`.
fn answerWith(runtime: *Runtime, made: *const h.beak_event, name: []const u8, payload: []const u8) void {
    var arena_allocator: std.heap.ArenaAllocator = .init(runtime.allocator);
    defer arena_allocator.deinit();
    var changes: Changes = .{ .arena = arena_allocator.allocator() };
    changes.answer(beak.slice(made.process), made.started, beak.slice(made.key), name, payload) catch return;
    _ = runtime.commit(&changes) catch |failure| {
        log.warn("the request {s} of {s} went unanswered: {s}", .{ beak.slice(made.key), beak.slice(made.process), @errorName(failure) });
    };
}

/// Beak's call of a registered program's phase: the phase is given the run and an arena, and gives back its changes
/// and its ending; a phase that throws commits nothing, its error its message, and runs again while retries last.
fn runPhase(context: ?*anyopaque, run: [*c]const h.beak_run, arena: [*c]const h.beak_allocator, out: [*c]h.beak_phase_out) callconv(.c) h.beak_status {
    const registered: *Registered = @ptrCast(@alignCast(context.?));
    const given = run.*;
    const phase_arena = beak.allocatorOf(arena);
    var phase: Phase = .{
        .arena = phase_arena,
        .runtime = registered.runtime,
        .path = phase_arena.dupe(u8, beak.slice(given.path)) catch return h.BEAK_OUT_OF_MEMORY,
        .input = beak.slice(given.input),
        .checkpoint = beak.slice(given.checkpoint),
        .stop_handler = given.stop_handler,
        .time = registered.runtime.time,
        .changes = .{ .arena = phase_arena },
    };
    registered.program.phase(registered.program.context, &phase) catch |err| {
        out.* = .{ .changes = null, .count = 0, .ending = Phase.endingOf(h.BEAK_ENDING_THREW, @errorName(err)) };
        return h.BEAK_OK;
    };
    const made = phase.changes.items();
    out.* = .{ .changes = made.ptr, .count = made.len, .ending = phase.ending };
    return h.BEAK_OK;
}
