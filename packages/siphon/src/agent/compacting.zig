//! Compacting a thread's window, by the one fiber of the thread that compacts, beside its main fiber: its model recaps
//! everything before the window's latest work, what the model is told is gathered anew, and a new window begins with
//! them — the compaction and all the model is told, in one commit. The person starts it whenever they ask, a turn
//! running on meanwhile in the background: what the turn adds while the recap is written is carried into the new window
//! as it stands, as everything after the cut is. A turn whose window is too full for its next request, or whose request
//! its provider refused as too long, starts it where it is not running, and waits for it either way: a thread compacts
//! once at a time. One that ended stays as it ended till the next is started.
const std = @import("std");
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const beak = @import("../beak.zig");
const h = beak.h;
const runtime_ = @import("../runtime.zig");
const Runtime = runtime_.Runtime;
const Phase = runtime_.Phase;
const Request = runtime_.Request;
const Changes = runtime_.Changes;
const threads = @import("../threads.zig");
const log = threads.log;
const Window = threads.Window;
const system = @import("system.zig");
const compaction = @import("compaction.zig");
const models_ = @import("models.zig");

/// The program of the fiber that compacts.
pub const program = "siphon.compact";

/// The key of the fiber that compacts, beside the thread's main fiber.
const key = "compact";

/// Registers the program of the fiber that compacts.
pub fn register(runtime: *Runtime) !void {
    try runtime.register(.{ .kind = program, .stop_handler = true, .phase = compactPhase });
}

/// The path of the fiber that compacts the thread at `thread`.
pub fn pathOf(arena: std.mem.Allocator, thread: []const u8) ![]const u8 {
    return beak.childPath(arena, thread, key);
}

/// How the fiber that compacts a thread stands: running, ended — with its outcome — or not there.
pub const Standing = union(enum) { none, running, ended: *const h.beak_outcome };

/// How the fiber that compacts the thread at `thread` stands.
pub fn standingOf(volume: beak.Volume, arena: *const std.mem.Allocator, thread: []const u8) !Standing {
    const entry = try volume.stat(arena, try pathOf(arena.*, thread)) orelse return .none;
    return if (beak.outcomeOf(entry)) |outcome| .{ .ended = outcome } else .running;
}

/// Starts, with `changes`, the fiber that compacts the thread at `thread`, where it is not running — one that ended
/// reaped as it is started anew; where it runs, nothing, as a thread compacts once at a time. Whether it was started.
pub fn start(changes: *Changes, runtime: *const Runtime, arena: *const std.mem.Allocator, thread: []const u8) !bool {
    switch (try standingOf(runtime.volume, arena, thread)) {
        .running => return false,
        .ended => try changes.reap(try pathOf(arena.*, thread)),
        .none => {},
    }
    const version = runtime.versionOf(program) orelse return error.NoSuchProgram;
    try changes.start(thread, key, program, version, "{}", "");
    return true;
}

/// Where the fiber that compacts stands: its window recapped up to its cut by the request of `key`; then what the model
/// is told gathered anew by the request of `key`, its recap written. Its checkpoint holds it as JSON; empty, it is about
/// to cut.
const Checkpoint = union(enum) {
    recapping: struct { key: []const u8, cut: compaction.Cut },
    regathering: struct { key: []const u8, recap: Recap, cut: compaction.Cut },
};

/// A recap, as the model request of `request` answered it: its response as it came.
const Recap = struct { request: []const u8, response: foundation.json.Raw };

/// What the fiber that compacts ends with: whether it began a new window — none, where nothing stood to be recapped.
pub const Compacted = struct { written: bool };

fn compactPhase(_: ?*anyopaque, phase: *Phase) anyerror!void {
    const thread = threads.threadOf(phase.path);
    if (phase.checkpoint.len == 0) {
        if (phase.stop_handler) return phase.stopped(null);
        const window = try Window.read(phase.runtime.volume, &phase.arena, thread);
        const cut = try compaction.cutOf(phase.arena, window) orelse return phase.done(Compacted{ .written = false });
        return recap(phase, thread, cut);
    }
    switch (try foundation.json.decode(Checkpoint, phase.arena, phase.checkpoint)) {
        .recapping => |recapping| return recapped(phase, thread, recapping.key, recapping.cut),
        .regathering => |regathering| return regathered(phase, thread, regathering.key, regathering.recap, regathering.cut),
    }
}

/// Has the thread's model recap its window up to `cut`, and sleeps until it has.
fn recap(phase: *Phase, thread: []const u8, cut: compaction.Cut) !void {
    const manifest = try threads.manifestOf(phase.runtime.volume, &phase.arena, thread);
    const asked = try phase.mint();
    try phase.request(models_.model_request, asked, models_.ModelRequest{ .thread = threads.idOf(thread), .until = cut.until, .model = manifest.model, .instruction = compaction.instruction });
    return phase.waitForMail(Checkpoint{ .recapping = .{ .key = asked, .cut = cut } }, asked);
}

/// The recap of the request of `asked` come: what the model is told gathered anew, for the window it begins; asked
/// again where it was cut off; a model that gave no recap fails the compaction, its window too long for it.
fn recapped(phase: *Phase, thread: []const u8, asked: []const u8, cut: compaction.Cut) !void {
    const answer = try phase.mailOf(asked) orelse return phase.waitForMail(Phase.kept, asked);
    try phase.take(asked);
    if (answer.interrupted()) {
        if (phase.stop_handler) return phase.stopped(null);
        return recap(phase, thread, cut);
    }
    if (std.mem.eql(u8, answer.name, Request.failed_name)) {
        if (phase.stop_handler) return phase.stopped(null);
        return phase.fail(answer.payload);
    }
    const response = foundation.json.decode(vocabulary.Response, phase.arena, answer.payload) catch return phase.fail("the model's recap is no response");
    try models_.charge(&phase.changes, phase.path, response);
    const text = if (response.status == .failed) null else try models_.textOf(phase.arena, response);
    if (phase.stop_handler or text == null) {
        // Kept as a failure, for the record, never sent to the model.
        var writer: log.Writer = try .init(phase, thread);
        _ = try writer.append(log.Failure{ .id = try phase.mint(), .request = asked, .response = try foundation.json.Raw.of(phase.arena, answer.payload) });
        if (phase.stop_handler) return phase.stopped(null);
        const why = if (response.@"error") |failure| failure.message else "it gave no recap";
        return phase.fail(try phase.arena.print("the conversation outgrew its model, which could not recap it: {s}", .{why}));
    }
    const gathering = try system.gather(phase, thread);
    const written: Recap = .{ .request = asked, .response = try foundation.json.Raw.of(phase.arena, answer.payload) };
    return phase.waitForMail(Checkpoint{ .regathering = .{ .key = gathering, .recap = written, .cut = cut } }, gathering);
}

/// What the model is told, gathered anew by the request of `gathering`: the new window begun, in one commit — the
/// compaction with the recap `written`, then all the model is told, as a window begins.
fn regathered(phase: *Phase, thread: []const u8, gathering: []const u8, written: Recap, cut: compaction.Cut) !void {
    const answer = try phase.mailOf(gathering) orelse return phase.waitForMail(Phase.kept, gathering);
    try phase.take(gathering);
    if (phase.stop_handler) return phase.stopped(null);
    if (answer.interrupted()) {
        const again = try system.gather(phase, thread);
        return phase.waitForMail(Checkpoint{ .regathering = .{ .key = again, .recap = written, .cut = cut } }, again);
    }
    if (std.mem.eql(u8, answer.name, Request.failed_name)) return phase.fail(try phase.arena.print("what the model is told could not be gathered: {s}", .{answer.payload}));
    const told = try system.changes(phase.arena, &.{}, try foundation.json.decode(system.Told, phase.arena, answer.payload));
    var writer: log.Writer = try .init(phase, thread);
    _ = try writer.append(log.Compaction{ .id = try phase.mint(), .request = written.request, .response = written.response, .kept = cut.kept, .from = cut.from });
    // The new window is read from the entry it keeps first, which comes before every other it keeps.
    const from = try log.cursorOf(phase.runtime.volume, &phase.arena, thread, cut.kept) orelse return error.KeptGone;
    try phase.changes.annotate(thread, &.{.{ .name = Window.from_annotation, .value = try foundation.json.encode(phase.arena, from) }});
    _ = try writer.append(log.System{ .id = try phase.mint(), .request = gathering, .sections = told.sections, .tools = told.tools });
    return phase.done(Compacted{ .written = true });
}
