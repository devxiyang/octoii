//! Threads, as Siphon keeps them: each a directory `siphon.thread:<tid>` at the volume's root — its manifest
//! `thread.json`, its `inbox/` of inputs delivered and not yet taken, its `log/`, and its main fiber
//! `system.process:main`, under which its turn runs — annotated with its status, which its fiber changes in the commits
//! that start and settle its turns. A thread is named by its id wherever it is asked for; its directory's path is this
//! module's to make. The operations here change threads, each checked as it is made and committed when it returns,
//! durable as it is; one that makes or adds to a thread is done once for its operation's id.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const beak = @import("beak.zig");
const h = beak.h;
const runtime_ = @import("runtime.zig");
const Runtime = runtime_.Runtime;
const Phase = runtime_.Phase;
const Changes = runtime_.Changes;
const operations = @import("operations.zig");
const accounts = @import("accounts.zig");
pub const log = @import("threads/log.zig");
pub const Window = @import("threads/Window.zig");
pub const stored = @import("threads/stored.zig");

/// The kind of a thread's directory, as Beak names a State: `siphon.thread:<tid>`. Every thread carries both its labels,
/// `siphon.project` and `siphon.parent`, each the empty value where it has none — as every directory of a kind carries
/// its kind's labels — so the label index answers every question of the threads alike: all of them, by either label of
/// any value; those of no project, or of no parent, by the empty one.
pub const kind = "siphon.thread";
/// The programs of a thread's main fiber and of its turns.
pub const thread_program = "siphon.thread";
pub const turn_program = "siphon.turn";
/// The program of the fiber that compacts a thread's window, and its key, beside the thread's main fiber.
pub const compact_program = "siphon.compact";
pub const compact_key = "compact";
/// The program of the fiber that goes on at a time the person asked, and its key, beside the thread's main fiber.
pub const resume_program = "siphon.resume";
pub const resume_key = "resume";

/// What a thread runs with and how it is shown, as its `thread.json` holds it.
pub const Manifest = struct {
    /// The project it belongs to, also its label `siphon.project`, the empty value where it has none.
    project: ?[]const u8 = null,
    /// The model its turns ask.
    model: ?[]const u8 = null,
    /// The folder on the host's machine its work is done in, by its absolute path.
    workspace: ?[]const u8 = null,
    title: ?[]const u8 = null,
    /// How its calls go ahead.
    mode: Mode = default_mode,
    /// How hard its model reasons; none, as the model does where it is not told.
    effort: ?Effort = null,
    /// The most its model requests may cost in all, in billionths of a US dollar; none, no bound. Each turn may spend
    /// what is left of it, as a cgroup's `*.max` bounds its group: Beak stops a turn its requests' cost takes past it.
    budget_nanodollars: ?u64 = null,
    /// Whether the person pinned it, which keeps it atop their threads.
    pinned: bool = false,
    /// Whether the person archived it, which keeps it out of their threads.
    archived: bool = false,
    /// Till when the person snoozed it, in ms since the epoch, kept out of their threads till then; none, not snoozed.
    /// Kept as the time of the thread's `siphon.snooze`, never in `thread.json`: Beak removes the name as its time
    /// comes, and the journal tells of it then, so whoever lists the threads hears the snooze end as it ends.
    snoozed_until: ?i64 = null,
    /// Till when the person has seen what it brought them — a turn's end, what it asks — in ms since the epoch, by
    /// the thread's own times; what came after is new to them. None, nothing seen. Of how they keep a thread, what its
    /// log cannot tell: looking at a thread leaves nothing in it.
    seen_until: ?i64 = null,
    /// When the person settled it — put it with what is done — in ms since the epoch: settled till something comes of
    /// it after; none, never. Its log cannot tell this either, nor `unsettled_at`.
    settled_at: ?i64 = null,
    /// When the person brought it back from what is done, in ms since the epoch: open from then; none, never.
    unsettled_at: ?i64 = null,
    /// The thread, and its call, that delegated it, where it is a sub-thread; the thread also its label
    /// `siphon.parent`, which the label index finds its sub-threads by, the empty value where it has none.
    parent: ?Parent = null,
};

/// Where a sub-thread came from: the thread that delegated it, by its id, and the call that did, by Siphon's id of it.
pub const Parent = struct { thread: []const u8, call: []const u8 };

/// The label a thread's directory carries of its parent thread, by its id; the empty value for a thread of its own.
pub const parent_label = "siphon.parent";

/// The label a thread's directory carries of its project, by its folder; the empty value for one of none.
pub const project_label = "siphon.project";

/// The labels a thread's directory carries of how the person keeps it — pinned, archived — `true`, or the empty value
/// for not, so the label index finds the threads kept either way; and the annotations that hold the times of how they
/// keep it, each by the manifest's field it is, as `siphon.<field>`. None of it is in `thread.json`, which holds what the
/// thread runs with.
pub const pinned_label = "siphon.pinned";
pub const archived_label = "siphon.archived";
const kept_times = [_][]const u8{ "seen_until", "settled_at", "unsettled_at" };

/// The ids of the sub-threads of the thread `tid`, as the label index finds them, as a process's children are found
/// by their parent's id.
pub fn subThreadsOf(volume: beak.Volume, arena: *const Allocator, tid: []const u8) ![]const []const u8 {
    const found = try volume.find(arena, kind, .{ .name = parent_label, .value = tid }, "");
    const ids = try arena.alloc([]const u8, found.len);
    for (found, ids) |entry, *id| id.* = idOf(beak.slice(entry.path));
    return ids;
}

/// How a thread's calls go ahead: in `default`, edits within the workspace and commands within the system's sandbox,
/// which write the workspace and the temporary folders alone, and what goes beyond asks the person; in `auto`, with no
/// sandbox, what would ask judged by a second model, the person asked where it doubts; in `full-access`, everything.
/// In each, nothing reaches what the host keeps for itself.
pub const Mode = enum { default, auto, @"full-access" };

/// How hard a thread's model reasons, as `ai` names it.
pub const Effort = vocabulary.items.ReasoningEffort;

/// The mode a thread follows where nothing set another.
pub const default_mode: Mode = .default;

/// An input as it is delivered.
pub const Input = struct {
    message: vocabulary.items.InputMessage,
    /// Whose it is: the person's, or a thread's, as `actorOf` names it — a sub-thread's task, given by its thread, and
    /// what came of one in the background, told by the sub-thread.
    actor: []const u8 = "person",
    /// Who is told, by mail, how the turn that takes it ends — or that it was taken back first.
    reply_to: ?log.ReplyTo = null,
};

/// How the turn that took an input ended, as those it replies to are told by mail named `ended_mail`: what the thread
/// said last, where it replied; why it failed; stopped; or, before any turn took it, the input taken back or the thread
/// deleted.
pub const Ended = union(enum) {
    replied: []const u8,
    failed: []const u8,
    stopped: struct {},
    deleted: struct {},
    withdrawn: struct {},
};

/// The name of the mail that tells how the turn that took an input ended.
pub const ended_mail = "ended";

/// Adds to `changes` mail to `reply_to` that the turn that took its input ended as `ended`; nothing where its fiber is
/// gone, or ended.
pub fn tellEnded(changes: *Changes, volume: beak.Volume, reply_to: log.ReplyTo, ended: Ended) !void {
    const arena = changes.arena;
    const entry = try volume.stat(&arena, reply_to.process) orelse return;
    const record = (entry.directory orelse return).*.process orelse return;
    if (record.*.state == h.BEAK_PROCESS_ZOMBIE) return;
    try changes.send(reply_to.process, reply_to.started, reply_to.key, ended_mail, try foundation.json.encode(arena, ended));
}

/// The actor of an input the thread `tid` delivers.
pub fn actorOf(arena: Allocator, tid: []const u8) Allocator.Error![]const u8 {
    return std.mem.concat(arena, u8, &.{ "thread.", tid });
}

/// An input in the inbox, as its file `inbox/<id>.json` holds it: what was delivered, and the operation that did.
pub const Delivered = struct {
    delivery_id: []const u8,
    actor: []const u8,
    message: vocabulary.items.InputMessage,
    reply_to: ?log.ReplyTo = null,
};

/// An input waiting in an inbox: its file, its id and what was delivered.
pub const Waiting = struct { path: []const u8, id: []const u8, delivered: Delivered };

/// What a thread's turns are doing: none run yet, one running, or how the last ended — as its log's `turn-end` says.
pub const Status = enum { created, running, replied, failed, stopped };

/// The annotations on a thread's directory that hold how it stands, as a unit's state holds when it was entered: its
/// status, when its latest turn began, and when that turn ended, in ms since the epoch — set in the commit that begins
/// or ends a turn.
pub const status_annotation = "siphon.status";
const began_annotation = "siphon.began_at";
const ended_annotation = "siphon.ended_at";
/// The annotation on a thread's directory that holds, while a turn runs, where in its log the turn began — the address
/// of the entry it began with, as JSON — so a main fiber that comes after the one running it settles it, as a journal
/// holds where its open transaction began.
const began_with_annotation = "siphon.began_with";

/// What a thread is doing: its status, when its latest turn began and when it ended — none before its first, and no
/// end while it runs; what its model requests used so far, none before its first; the inputs that wait in its inbox
/// for its next turn, as a mail queue lists what waits in it; and its fibers, as `ps` shows processes — each with what
/// it waits on — so whoever follows the thread sees what it is doing, by the ids that tie each part to what comes of
/// it.
pub const State = struct {
    status: Status,
    began_at: ?i64 = null,
    ended_at: ?i64 = null,
    usage: ?Usage = null,
    inbox: []const Inbound = &.{},
    processes: []const Process = &.{},
};

/// What a thread's model requests used: the tokens read — of them those read from the prompt cache — the tokens
/// written — of them those spent reasoning — and what they cost, in billionths of a US dollar, where the providers
/// said. Each request's is charged to the fiber that asked and every fiber above it, as cgroup v2 charges a cgroup and
/// its ancestors, so the thread's main fiber holds the whole thread's — its turns' and what was asked beside them.
pub const Usage = struct {
    input_tokens: u64 = 0,
    cached_tokens: u64 = 0,
    output_tokens: u64 = 0,
    reasoning_tokens: u64 = 0,
    cost_nanodollars: u64 = 0,

    const fields = @typeInfo(Usage).@"struct".field_names;

    /// The counter Beak keeps the field `name` as: its name in lowercase words joined by dashes.
    fn counterName(comptime name: []const u8) []const u8 {
        comptime var out: [name.len]u8 = undefined;
        inline for (name, 0..) |char, at| out[at] = if (char == '_') '-' else char;
        const done = out;
        return &done;
    }

    /// The usage as the counters a charge adds: those of none left out.
    pub fn counters(usage: Usage, arena: Allocator) Allocator.Error![]const h.beak_counter {
        var out: std.ArrayList(h.beak_counter) = .empty;
        inline for (fields) |name| {
            const value = @field(usage, name);
            if (value > 0) try out.append(arena, .{ .name = beak.bytes(comptime counterName(name)), .value = value });
        }
        return out.items;
    }

    /// The usage `counters` hold — a process's, as Beak keeps them; none where they hold none of it.
    pub fn of(counters_: []const h.beak_counter) ?Usage {
        var usage: Usage = .{};
        var found = false;
        for (counters_) |counter| {
            inline for (fields) |name| if (std.mem.eql(u8, beak.slice(counter.name), comptime counterName(name))) {
                @field(usage, name) = counter.value;
                found = true;
            };
        }
        return if (found) usage else null;
    }
};

/// The annotation that bounds a turn's cost, as Beak bounds a group by its counter.
pub const cost_limit = h.BEAK_MAX_ANNOTATION_PREFIX ++ Usage.counterName("cost_nanodollars");

/// What the budget of the thread at `thread`, whose manifest is `manifest`, leaves its next turn: the budget less what
/// its model requests cost so far, as its main fiber's usage holds the whole thread's; none where it has no budget.
pub fn budgetLeft(volume: beak.Volume, arena: Allocator, thread: []const u8, manifest: Manifest) !?u64 {
    const budget = manifest.budget_nanodollars orelse return null;
    const spent = if (try usageOf(volume, arena, thread)) |usage| usage.cost_nanodollars else 0;
    return budget -| spent;
}

/// What the model requests of the thread at `thread` used, as its main fiber's usage holds it; none before its first.
fn usageOf(volume: beak.Volume, arena: Allocator, thread: []const u8) !?Usage {
    const entry = try volume.stat(&arena, try mainOf(arena, thread)) orelse return null;
    const record = (entry.directory orelse return null).*.process orelse return null;
    return Usage.of(beak.items(h.beak_counter, record.*.usage, record.*.usage_count));
}

/// An input as a thread's state shows it waiting in its inbox: its id, by which it is withdrawn, whose it is, and its
/// message.
pub const Inbound = struct { id: []const u8, actor: []const u8, message: vocabulary.items.InputMessage };

/// A fiber of a thread, as Beak keeps its process: its key and its parent's — none for the main fiber — its program,
/// how it stands, the JSON it was started with, the requests it made that wait for their answers, the time it sleeps
/// until, and why it is asked to stop.
pub const Process = struct {
    key: []const u8,
    parent: ?[]const u8 = null,
    program: []const u8,
    state: ProcessState,
    input: ?foundation.json.Raw = null,
    requests: []const Open = &.{},
    until: ?i64 = null,
    stopping: ?[]const u8 = null,
};

/// How a process stands, as Beak keeps it.
pub const ProcessState = enum { runnable, running, sleeping, exiting, zombie };

/// A request a fiber made that waits for its answer, as it was made: its key, its name, and the JSON it was made with —
/// none for a request that says no more than its name; and, for one a person answers, the JSON Schema their answer fits,
/// as a request for a person's input says what form it takes.
pub const Open = struct { key: []const u8, name: []const u8, payload: ?foundation.json.Raw = null, answer: ?foundation.json.Raw = null };

/// The directory of the thread `tid`.
pub fn pathOf(arena: Allocator, tid: []const u8) Allocator.Error![]const u8 {
    return std.mem.concat(arena, u8, &.{ kind, ":", tid });
}

/// The main fiber of the thread at `thread`.
pub fn mainOf(arena: Allocator, thread: []const u8) Allocator.Error![]const u8 {
    return beak.childPath(arena, thread, "main");
}

/// The turn of the thread at `thread`, while one runs or waits to be settled: the fiber under its main fiber, named by
/// the turn's id; null where none is.
pub fn turnOf(volume: beak.Volume, arena: *const Allocator, thread: []const u8) !?[]const u8 {
    const main = try mainOf(arena.*, thread);
    const found = try volume.page(arena, main, .{ .prefix = h.BEAK_PROCESS_KIND ++ ":", .limit = 1 });
    if (found.len == 0) return null;
    return try beak.join(arena.*, main, beak.slice(found[0].name));
}

/// The thread whose main fiber, or a fiber under it, runs at the process `path`, by its directory's path.
pub fn threadOf(path: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, path, "/" ++ h.BEAK_PROCESS_KIND ++ ":") orelse path.len;
    return path[0..end];
}

/// The id of the thread at `thread`, its directory's path.
pub fn idOf(thread: []const u8) []const u8 {
    return thread[kind.len + 1 ..];
}

/// Makes a thread of `manifest`, its main fiber started; its id. Made again under the same `operation` within a day,
/// it is the thread already made.
pub fn create(runtime: *Runtime, arena: Allocator, manifest: Manifest, operation: []const u8) ![]const u8 {
    if (try operations.before(runtime, arena, operation, "threads.create", null)) |done| return done.thread;
    const time = runtime.now();
    const tid = try arena.dupe(u8, &try runtime.volume.mint(time));
    var changes: Changes = .{ .arena = arena };
    try made(&changes, runtime, tid, manifest);
    try operations.record(&changes, operation, .{ .method = "threads.create", .thread = tid, .result = tid }, time);
    _ = try runtime.commit(&changes);
    return tid;
}

/// Adds to `changes` what makes a thread of `manifest` under the id `tid`: its directory with its manifest, its inbox
/// and its log, its status created, and its main fiber started — committed with whatever else `changes` holds, as a
/// fiber that delegates makes its sub-thread with its own step.
pub fn made(changes: *Changes, runtime: *const Runtime, tid: []const u8, manifest: Manifest) !void {
    const arena = changes.arena;
    const thread = try pathOf(arena, tid);
    try changes.mkdir(thread);
    try changes.write(try beak.join(arena, thread, "thread.json"), try foundation.json.encode(arena, settingsOf(manifest)));
    try changes.mkdir(try beak.join(arena, thread, "inbox"));
    try changes.mkdir(try log.pathOf(arena, thread));
    try changes.label(thread, project_label, manifest.project orelse "");
    try changes.label(thread, parent_label, if (manifest.parent) |parent| parent.thread else "");
    try changes.label(thread, pinned_label, labelled(manifest.pinned));
    try changes.label(thread, archived_label, labelled(manifest.archived));
    try changes.annotate(thread, &.{.{ .name = status_annotation, .value = @tagName(Status.created) }});
    try changes.start(thread, "main", thread_program, runtime.versionOf(thread_program).?, "", "");
}

/// Adds to `changes` what puts `input` in the inbox of the thread at `thread` under the id `id`, for the operation
/// `operation`.
pub fn inboxed(changes: *Changes, thread: []const u8, id: []const u8, input: Input, operation: []const u8) !void {
    const delivered: Delivered = .{ .delivery_id = operation, .actor = input.actor, .message = input.message, .reply_to = input.reply_to };
    try changes.write(try inboxFile(changes.arena, thread, id), try foundation.json.encode(changes.arena, delivered));
}

/// What of a thread's manifest the person changes as it goes: the model its turns ask, from its next request on; its
/// title; the mode its calls follow, from its next call on; and how they keep it — pinned, archived, snoozed till
/// when, seen till when — each one given in place of the one it had, each left out kept.
pub const Configured = struct {
    model: ?[]const u8 = null,
    title: ?[]const u8 = null,
    mode: ?Mode = null,
    effort: ?Effort = null,
    /// A budget, or 0 for none.
    budget_nanodollars: ?u64 = null,
    pinned: ?bool = null,
    archived: ?bool = null,
    snoozed_until: ?i64 = null,
    seen_until: ?i64 = null,
    settled_at: ?i64 = null,
    unsettled_at: ?i64 = null,
};

/// Changes the manifest of the thread `tid` as `configured` says, in one commit: a snooze till a time to come as the
/// thread's `siphon.snooze`, which goes at that time, and one till a time past as none.
pub fn configure(runtime: *Runtime, arena: Allocator, tid: []const u8, configured: Configured) !void {
    const thread = try pathOf(arena, tid);
    if (try runtime.volume.stat(&arena, thread) == null) return error.NoSuchThread;
    var manifest = try manifestOf(runtime.volume, &arena, thread);
    // Each change given takes the place of the manifest's field of its name.
    inline for (@typeInfo(Configured).@"struct".field_names) |name| {
        if (@field(configured, name)) |value| @field(manifest, name) = value;
    }
    var changes: Changes = .{ .arena = arena };
    // Given another model, the thread goes on as the person goes on with it, not at the time they asked before.
    if (configured.model != null) try resumeEnded(&changes, runtime, arena, thread);
    if (configured.pinned) |pinned| try changes.label(thread, pinned_label, labelled(pinned));
    if (configured.archived) |archived| try changes.label(thread, archived_label, labelled(archived));
    inline for (kept_times) |name| {
        if (@field(configured, name)) |time| try changes.annotate(thread, &.{.{ .name = "siphon." ++ name, .value = try arena.print("{d}", .{time}) }});
    }
    if (configured.snoozed_until) |until| {
        const snooze = try beak.join(arena, thread, snooze_name);
        if (until > runtime.now()) {
            try changes.write(snooze, "");
            try changes.expire(snooze, until);
        } else if (manifest.snoozed_until != null) try changes.delete(snooze);
    }
    if (manifest.budget_nanodollars == 0) manifest.budget_nanodollars = null;
    try changes.write(try beak.join(arena, thread, "thread.json"), try foundation.json.encode(arena, settingsOf(manifest)));
    _ = try runtime.commit(&changes);
}

/// The name in a thread's directory that holds, by its time, till when the person snoozed it: there while it sleeps.
const snooze_name = "siphon.snooze";

/// Delivers `input` to the thread `tid`, kept in its inbox till its fiber takes it; the input's id. Delivered again
/// under the same `operation` within a day, it is the input already delivered.
pub fn deliver(runtime: *Runtime, arena: Allocator, tid: []const u8, input: Input, operation: []const u8) ![]const u8 {
    const thread = try pathOf(arena, tid);
    if (try runtime.volume.stat(&arena, thread) == null) return error.NoSuchThread;
    if (try operations.before(runtime, arena, operation, "threads.deliver", tid)) |done| return done.result;
    const time = runtime.now();
    const id = try arena.dupe(u8, &try runtime.volume.mint(time));
    var changes: Changes = .{ .arena = arena };
    try inboxed(&changes, thread, id, input, operation);
    try revived(&changes, runtime, arena, thread);
    if (std.mem.eql(u8, input.actor, "person")) try resumeEnded(&changes, runtime, arena, thread);
    try operations.record(&changes, operation, .{ .method = "threads.deliver", .thread = tid, .result = id }, time);
    _ = try runtime.commit(&changes);
    return id;
}

/// Adds to `changes` the main fiber of the thread at `thread` started again where it ended — failed past its retries,
/// killed, or gone with its retention — as socket activation starts a service a message comes for, so what is
/// delivered is taken; a main fiber that lives, or that is still exiting, is left as it is.
fn revived(changes: *Changes, runtime: *Runtime, arena: Allocator, thread: []const u8) !void {
    const main = try mainOf(arena, thread);
    if (try runtime.volume.stat(&arena, main)) |entry| {
        const record = (entry.directory orelse return error.DamagedThread).*.process orelse return error.DamagedThread;
        if (record.*.state != h.BEAK_PROCESS_ZOMBIE) return;
        try changes.reap(main);
    }
    try changes.start(thread, "main", thread_program, runtime.versionOf(thread_program) orelse return error.NoSuchProgram, "", "");
}

/// Where the turn the thread at `thread` stands running in began, where no main fiber runs it any more: one that ended
/// mid-turn, its checkpoint gone with it, left it so; null where no turn runs.
pub fn lostTurn(volume: beak.Volume, arena: *const Allocator, thread: []const u8) !?log.Address {
    const entry = try volume.stat(arena, thread) orelse return error.NoSuchThread;
    const status = beak.annotationOf(entry, status_annotation) orelse return error.DamagedThread;
    if (!std.mem.eql(u8, status, @tagName(Status.running))) return null;
    const began_with = beak.annotationOf(entry, began_with_annotation) orelse return null;
    return try foundation.json.decode(log.Address, arena.*, began_with);
}

/// Takes back the input `id` while it waits in the inbox of the thread `tid` — who it replies to told so — whether it
/// was still there.
pub fn withdraw(runtime: *Runtime, arena: Allocator, tid: []const u8, id: []const u8) !bool {
    const file = try inboxFile(arena, try pathOf(arena, tid), id);
    if (try runtime.volume.stat(&arena, file) == null) return false;
    var changes: Changes = .{ .arena = arena };
    const delivered = try foundation.json.decode(Delivered, arena, try runtime.volume.readAll(&arena, file));
    if (delivered.reply_to) |reply_to| try tellEnded(&changes, runtime.volume, reply_to, .{ .withdrawn = .{} });
    try changes.delete(file);
    _ = try runtime.commit(&changes);
    return true;
}

/// Stops the thread `tid` for `actor`: its waiting inputs withdrawn and its turn asked to stop, in one commit.
pub fn stop(runtime: *Runtime, arena: Allocator, tid: []const u8, actor: []const u8) !void {
    const thread = try pathOf(arena, tid);
    if (try runtime.volume.stat(&arena, thread) == null) return error.NoSuchThread;
    var changes: Changes = .{ .arena = arena };
    for (try waiting(runtime.volume, &arena, thread)) |each| {
        if (std.mem.eql(u8, each.delivered.actor, actor)) try changes.delete(each.path);
    }
    if (try turnOf(runtime.volume, &arena, thread)) |turn| {
        const entry = try runtime.volume.stat(&arena, turn) orelse return error.TurnGone;
        if (beak.outcomeOf(entry) == null) try changes.terminate(turn, "stopped");
    }
    if (changes.items().len > 0) _ = try runtime.commit(&changes);
}

/// Deletes the thread `tid` and its sub-threads, in one commit, as rm -rf takes a tree: each directory gone with its
/// manifest, its inbox, its log and its fibers, each killed as it goes, what they asked cut off; the ids of the threads
/// gone, `tid` first.
pub fn delete(runtime: *Runtime, arena: Allocator, tid: []const u8) ![]const []const u8 {
    const thread = try pathOf(arena, tid);
    if (try runtime.volume.stat(&arena, thread) == null) return error.NoSuchThread;
    var gone: std.ArrayList([]const u8) = .empty;
    try gone.append(arena, tid);
    try gone.appendSlice(arena, try subThreadsOf(runtime.volume, &arena, tid));
    var changes: Changes = .{ .arena = arena };
    for (gone.items) |each| try changes.deleteKilling(try pathOf(arena, each), "deleted");
    _ = try runtime.commit(&changes);
    return gone.items;
}

/// Gives the person's answer `given` to the request of `key` a fiber of the thread `tid` waits on — one of those a
/// person answers — where it fits what the request asks.
pub fn answer(runtime: *Runtime, arena: Allocator, tid: []const u8, key: []const u8, given: foundation.json.Raw) !Runtime.Answered {
    const thread = try pathOf(arena, tid);
    if (try runtime.volume.stat(&arena, thread) == null) return error.NoSuchThread;
    const named = try std.mem.concat(arena, u8, &.{ h.BEAK_REQUEST_KIND, ":", key });
    for (try runtime.volume.find(&arena, h.BEAK_REQUEST_KIND, .{ .name = h.BEAK_REQUEST_KIND }, thread)) |entry| {
        const path = beak.slice(entry.path);
        if (std.mem.eql(u8, beak.slice(entry.name), named)) return runtime.answer(arena, path[0 .. path.len - named.len - 1], key, given);
    }
    return error.NoSuchRequest;
}

/// What the thread `tid` is doing.
pub fn state(runtime: *Runtime, arena: Allocator, tid: []const u8) !State {
    const thread = try pathOf(arena, tid);
    const entry = try runtime.volume.stat(&arena, thread) orelse return error.NoSuchThread;
    return stateOf(runtime, arena, thread, entry);
}

/// What the thread at `thread`, whose directory `entry` shows, is doing: its status as annotated, its inbox's names
/// counted, and its fibers as Beak keeps their processes.
pub fn stateOf(runtime: *const Runtime, arena: Allocator, thread: []const u8, entry: *const h.beak_entry) !State {
    const status = beak.annotationOf(entry, status_annotation) orelse return error.DamagedThread;
    return .{
        .status = std.meta.stringToEnum(Status, status) orelse return error.DamagedThread,
        .began_at = try timeOf(entry, began_annotation),
        .ended_at = try timeOf(entry, ended_annotation),
        .usage = try usageOf(runtime.volume, arena, thread),
        .inbox = try inboxOf(runtime.volume, arena, thread),
        .processes = try processesOf(runtime, arena, thread),
    };
}

/// The time the annotation `name` of a thread's directory holds; none where it has none.
fn timeOf(entry: *const h.beak_entry, name: []const u8) !?i64 {
    const text = beak.annotationOf(entry, name) orelse return null;
    return std.fmt.parseInt(i64, text, 10) catch error.DamagedThread;
}

/// The inputs waiting in the inbox of the thread at `thread`, in the order they came, as its state shows them.
fn inboxOf(volume: beak.Volume, arena: Allocator, thread: []const u8) ![]const Inbound {
    const found = try waiting(volume, &arena, thread);
    const inbox = try arena.alloc(Inbound, found.len);
    for (found, inbox) |each, *shown| shown.* = .{ .id = each.id, .actor = each.delivered.actor, .message = each.delivered.message };
    return inbox;
}

/// The fibers of the thread at `thread`, a parent before its children, each with the requests it waits on, as `ps`
/// reads `/proc`: one reaped, or a request answered, as they were read, is read as it was found, or left out.
fn processesOf(runtime: *const Runtime, arena: Allocator, thread: []const u8) ![]const Process {
    const volume = runtime.volume;
    const found = try volume.find(&arena, h.BEAK_PROCESS_KIND, .{ .name = h.BEAK_PROGRAM_LABEL }, thread);
    const paths = try arena.alloc([]const u8, found.len);
    const out = try arena.alloc(Process, found.len);
    for (found, paths, out) |entry, *path, *process| {
        path.* = beak.slice(entry.path);
        const record = (entry.directory orelse return error.DamagedThread).*.process orelse return error.DamagedThread;
        const input = try optionalFile(volume, arena, try beak.join(arena, path.*, h.BEAK_INPUT_NAME));
        const parent = path.*[0 .. std.mem.lastIndexOfScalar(u8, path.*, '/') orelse 0];
        process.* = .{
            .key = beak.keyOf(path.*),
            .parent = if (std.mem.indexOf(u8, parent, "/" ++ h.BEAK_PROCESS_KIND ++ ":") != null) beak.keyOf(parent) else null,
            .program = beak.slice(record.*.program_kind),
            .state = try processStateOf(record.*.state),
            .input = jsonOf(input orelse ""),
            .until = beak.get(record.*.waits_until),
            .stopping = if (beak.get(record.*.terminating_at) != null) beak.slice(record.*.terminating_reason) else null,
        };
    }
    var requests: std.ArrayList(std.ArrayList(Open)) = .empty;
    try requests.appendNTimes(arena, .empty, found.len);
    for (try volume.find(&arena, h.BEAK_REQUEST_KIND, .{ .name = h.BEAK_REQUEST_KIND }, thread)) |entry| {
        const of = indexOf(paths, processOfRequest(&entry)) orelse continue;
        const open = try openOf(runtime, arena, &entry) orelse continue;
        try requests.items[of].append(arena, open);
    }
    for (out, requests.items) |*process, waiting_on| process.requests = waiting_on.items;
    return out;
}

/// The path of the process whose request the entry of a request's directory shows.
fn processOfRequest(entry: *const h.beak_entry) []const u8 {
    const path = beak.slice(entry.path);
    return path[0 .. path.len - beak.slice(entry.name).len - 1];
}

/// The request the entry of a request's directory shows, as it was made, with the JSON Schema a person's answer to it
/// fits where a person answers it; null for one answered as it was read.
fn openOf(runtime: *const Runtime, arena: Allocator, entry: *const h.beak_entry) !?Open {
    const path = beak.slice(entry.path);
    const name = beak.slice(entry.name);
    const payload = try optionalFile(runtime.volume, arena, try beak.join(arena, path, h.BEAK_PAYLOAD_NAME)) orelse return null;
    const directory = entry.directory orelse return error.DamagedThread;
    const asked = beak.labelOf(directory.*.labels, directory.*.label_count, h.BEAK_REQUEST_KIND) orelse return error.DamagedThread;
    return .{
        .key = name[h.BEAK_REQUEST_KIND.len + 1 ..],
        .name = asked,
        .payload = jsonOf(payload),
        .answer = if (try runtime.answerSchemaOf(arena, asked, payload)) |schema| try foundation.json.Raw.of(arena, schema) else null,
    };
}

/// What the thread at `thread` asks the person: each request of its fibers a person answers, by the fiber that waits on
/// it, in the order of their paths.
fn asksOf(runtime: *const Runtime, arena: Allocator, thread: []const u8) ![]const Ask {
    var asks: std.ArrayList(Ask) = .empty;
    for (try runtime.volume.find(&arena, h.BEAK_REQUEST_KIND, .{ .name = h.BEAK_REQUEST_KIND }, thread)) |entry| {
        const open = try openOf(runtime, arena, &entry) orelse continue;
        if (open.answer == null) continue;
        try asks.append(arena, .{ .fiber = beak.keyOf(processOfRequest(&entry)), .request = open });
    }
    return asks.items;
}

/// How the thread at `thread`, whose directory `entry` shows, stands, as a list of them shows it.
pub fn standingOf(runtime: *const Runtime, arena: Allocator, thread: []const u8, entry: *const h.beak_entry) !Standing {
    const status = std.meta.stringToEnum(Status, beak.annotationOf(entry, status_annotation) orelse return error.DamagedThread) orelse return error.DamagedThread;
    const compactor = try runtime.volume.stat(&arena, try beak.childPath(arena, thread, compact_key));
    return .{
        .status = status,
        .began_at = try timeOf(entry, began_annotation),
        .ended_at = try timeOf(entry, ended_annotation),
        .usage = try usageOf(runtime.volume, arena, thread),
        .inbox = try inboxOf(runtime.volume, arena, thread),
        .asks = try asksOf(runtime, arena, thread),
        .compacting = if (compactor) |found| beak.outcomeOf(found) == null else false,
        .limited = if (status == .failed) try limitedOf(runtime, arena, thread) else null,
        .resuming_at = try resumingAt(runtime.volume, arena, thread),
    };
}

/// When the thread at `thread` goes on, where the person asked it to at a time: its resume, while it sleeps.
fn resumingAt(volume: beak.Volume, arena: Allocator, thread: []const u8) !?i64 {
    const entry = try volume.stat(&arena, try beak.childPath(arena, thread, resume_key)) orelse return null;
    const record = (entry.directory orelse return null).*.process orelse return null;
    if (record.*.state != h.BEAK_PROCESS_SLEEPING) return null;
    return beak.get(record.*.waits_until);
}

/// Has the thread `tid` go on at `at`, sending the person's word to go on then, unless they send their own first or
/// give it another model; none where `at` is null, the resume armed before ended.
pub fn resumeAt(runtime: *Runtime, arena: Allocator, tid: []const u8, at: ?i64) !void {
    const thread = try pathOf(arena, tid);
    if (try runtime.volume.stat(&arena, thread) == null) return error.NoSuchThread;
    var ending: Changes = .{ .arena = arena };
    try resumeEnded(&ending, runtime, arena, thread);
    if (ending.items().len > 0) _ = try runtime.commit(&ending);
    const time = at orelse return;
    var changes: Changes = .{ .arena = arena };
    try changes.start(thread, resume_key, resume_program, runtime.versionOf(resume_program).?, try foundation.json.encode(arena, .{ .at = time }), "");
    _ = try runtime.commit(&changes);
}

/// Adds to `changes` the end of the resume armed for the thread at `thread`, where one is, as the person went on.
fn resumeEnded(changes: *Changes, runtime: *const Runtime, arena: Allocator, thread: []const u8) !void {
    const fiber = try beak.childPath(arena, thread, resume_key);
    if (try runtime.volume.stat(&arena, fiber) == null) return;
    try changes.deleteKilling(fiber, "the person went on");
}

/// The quota of the model of the thread at `thread`, where it is used up still.
fn limitedOf(runtime: *const Runtime, arena: Allocator, thread: []const u8) !?accounts.Limited {
    const model = (try manifestOf(runtime.volume, &arena, thread)).model orelse return null;
    const provider = accounts.providerOf(model);
    const used_up = try accounts.usedUp(runtime.volume, arena, provider, runtime.now()) orelse return null;
    return .{ .provider = provider, .reset_at_ms = used_up.reset_at_ms, .window_minutes = used_up.window_minutes };
}

/// How a process stands, as Beak's record of it says.
fn processStateOf(kept: h.beak_process_state) !ProcessState {
    return switch (kept) {
        h.BEAK_PROCESS_RUNNABLE => .runnable,
        h.BEAK_PROCESS_RUNNING => .running,
        h.BEAK_PROCESS_SLEEPING => .sleeping,
        h.BEAK_PROCESS_EXITING => .exiting,
        h.BEAK_PROCESS_ZOMBIE => .zombie,
        else => error.DamagedThread,
    };
}

/// Where `path` stands among `paths`; null where it is not among them.
fn indexOf(paths: []const []const u8, path: []const u8) ?usize {
    for (paths, 0..) |each, index| if (std.mem.eql(u8, each, path)) return index;
    return null;
}

/// The whole of the file at `path`; null where there is none.
fn optionalFile(volume: beak.Volume, arena: Allocator, path: []const u8) !?[]const u8 {
    return volume.readAll(&arena, path) catch |err| switch (err) {
        error.NotFound => null,
        else => err,
    };
}

/// What a fiber was started or asked with, as the JSON Siphon gives every one: none where it was given nothing.
fn jsonOf(given: []const u8) ?foundation.json.Raw {
    return if (given.len > 0) .{ .text = given } else null;
}

/// The thread at `thread` at work from `time` on, with the commit of `changes`: running, its latest turn begun then with
/// the entry at `began_with` — none for a turn that ends in the commit it begins in — and not ended.
pub fn setRunning(changes: *Changes, thread: []const u8, time: i64, began_with: ?log.Address) Allocator.Error!void {
    try changes.annotate(thread, &.{
        .{ .name = status_annotation, .value = @tagName(Status.running) },
        .{ .name = began_annotation, .value = try changes.arena.print("{d}", .{time}) },
        .{ .name = ended_annotation, .value = null },
        .{ .name = began_with_annotation, .value = if (began_with) |address| try foundation.json.encode(changes.arena, address) else null },
    });
}

/// The latest turn of the thread at `thread` ended at `time`, as `outcome` says, with the commit of `changes`.
pub fn setEnded(changes: *Changes, thread: []const u8, outcome: log.Outcome, time: i64) Allocator.Error!void {
    try changes.annotate(thread, &.{
        .{ .name = status_annotation, .value = @tagName(outcome) },
        .{ .name = ended_annotation, .value = try changes.arena.print("{d}", .{time}) },
        .{ .name = began_with_annotation, .value = null },
    });
}

/// The id of the thread a commit's change at `path` is in: its directory, or anything under it — its manifest, its log,
/// its inbox, its fibers and what they wait on; null for any other path.
pub fn threadOfChange(path: []const u8) ?[]const u8 {
    const prefix = kind ++ ":";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
    return path[prefix.len..end];
}

/// A thread as a list of them shows it: its id, its manifest and how it stands — never its fibers, which its state
/// shows whoever follows it, as `ps` lists the processes `/proc/<pid>` details.
pub const Listed = struct { id: []const u8, manifest: Manifest, standing: Standing };

/// How a thread stands, as a list of them shows it: its status and the times of its latest turn, what its model
/// requests used, the inputs waiting in its inbox, what it asks the person — each request a person answers, by the
/// fiber that waits on it — whether it compacts, and, where its latest turn failed and its model's quota is used up
/// still, that quota.
pub const Standing = struct {
    status: Status,
    began_at: ?i64 = null,
    ended_at: ?i64 = null,
    usage: ?Usage = null,
    inbox: []const Inbound = &.{},
    asks: []const Ask = &.{},
    compacting: bool = false,
    limited: ?accounts.Limited = null,
    /// When it goes on, where the person asked it to at a time.
    resuming_at: ?i64 = null,
};

/// A request a fiber of a thread waits on a person's answer to: the fiber, by its key, and the request as it was made.
pub const Ask = struct { fiber: []const u8, request: Open };

/// The threads, each as a list shows it.
pub fn list(runtime: *const Runtime, arena: Allocator) ![]const Listed {
    const volume = runtime.volume;
    const found = try volume.list(&arena, "", kind ++ ":");
    const out = try arena.alloc(Listed, found.len);
    for (found, out) |entry, *listed| {
        const name = beak.slice(entry.name);
        listed.* = .{ .id = name[kind.len + 1 ..], .manifest = try manifestOf(volume, &arena, name), .standing = try standingOf(runtime, arena, name, &entry) };
    }
    return out;
}

/// The thread `tid` as a list shows it; null where there is no such thread.
pub fn listedOf(runtime: *const Runtime, arena: Allocator, tid: []const u8) !?Listed {
    const thread = try pathOf(arena, tid);
    const entry = try runtime.volume.stat(&arena, thread) orelse return null;
    return .{ .id = tid, .manifest = try manifestOf(runtime.volume, &arena, thread), .standing = try standingOf(runtime, arena, thread, entry) };
}

/// The inputs waiting in the inbox of the thread at `thread`, in the order they came.
pub fn waiting(volume: beak.Volume, arena: *const Allocator, thread: []const u8) ![]const Waiting {
    const inbox = try beak.join(arena.*, thread, "inbox");
    const found = try volume.list(arena, inbox, "");
    const out = try arena.alloc(Waiting, found.len);
    for (found, out) |entry, *each| {
        const name = beak.slice(entry.name);
        const path = try beak.join(arena.*, inbox, name);
        each.* = .{
            .path = path,
            .id = try arena.dupe(u8, name[0 .. name.len - ".json".len]),
            .delivered = try foundation.json.decode(Delivered, arena.*, try volume.readAll(arena, path)),
        };
    }
    return out;
}

/// An input taken into a thread's log: where its entry is, and who it replies to, where someone asked.
pub const Taken = struct { address: log.Address, reply_to: ?log.ReplyTo };

/// Takes every input waiting in the inbox of the thread at `thread` into its log, with the phase's commit, in the
/// order they came; where the entries appended are, and who each replies to.
pub fn takeInputs(writer: *log.Writer) ![]const Taken {
    const phase = writer.phase;
    const thread = writer.thread;
    const found = try waiting(phase.runtime.volume, &phase.arena, thread);
    if (found.len == 0) return &.{};
    const taken = try phase.arena.alloc(Taken, found.len);
    for (found, taken) |each, *at| {
        const delivered = each.delivered;
        const address = try writer.append(log.Input{ .id = try phase.mint(), .delivery_id = delivered.delivery_id, .actor = delivered.actor, .message = delivered.message, .reply_to = delivered.reply_to });
        at.* = .{ .address = address, .reply_to = delivered.reply_to };
        try phase.changes.delete(each.path);
    }
    return taken;
}

/// The manifest of the thread at `thread`: what it runs with, as its `thread.json` holds it; how the person keeps it, as
/// its directory's labels and annotations hold it; and the time of its snooze, where it sleeps.
pub fn manifestOf(volume: beak.Volume, arena: *const Allocator, thread: []const u8) !Manifest {
    var manifest = try foundation.json.decode(Manifest, arena.*, try volume.readAll(arena, try beak.join(arena.*, thread, "thread.json")));
    const entry = try volume.stat(arena, thread) orelse return error.NoSuchThread;
    const directory = entry.directory orelse return error.DamagedThread;
    manifest.pinned = isLabelled(beak.labelOf(directory.*.labels, directory.*.label_count, pinned_label));
    manifest.archived = isLabelled(beak.labelOf(directory.*.labels, directory.*.label_count, archived_label));
    inline for (kept_times) |name| @field(manifest, name) = try timeOf(entry, "siphon." ++ name);
    const snooze = try volume.stat(arena, try beak.join(arena.*, thread, snooze_name));
    manifest.snoozed_until = if (snooze) |found| beak.get(found.expires) else null;
    return manifest;
}

/// What of `manifest` its `thread.json` holds: what the thread runs with, none of how the person keeps it, which its
/// directory holds.
fn settingsOf(manifest: Manifest) Manifest {
    var settings = manifest;
    settings.pinned = false;
    settings.archived = false;
    inline for (kept_times) |name| @field(settings, name) = null;
    settings.snoozed_until = null;
    return settings;
}

/// A flag as a label holds it: `true`, or the empty value for not.
fn labelled(flag: bool) []const u8 {
    return if (flag) "true" else "";
}

fn isLabelled(value: ?[]const u8) bool {
    return std.mem.eql(u8, value orelse "", "true");
}

/// The file that holds the input `id` while it waits in the inbox of the thread at `thread`.
pub fn inboxFile(arena: Allocator, thread: []const u8, id: []const u8) Allocator.Error![]const u8 {
    return std.mem.concat(arena, u8, &.{ thread, "/inbox/", id, ".json" });
}

test {
    _ = log;
    _ = Window;
    _ = stored;
}
