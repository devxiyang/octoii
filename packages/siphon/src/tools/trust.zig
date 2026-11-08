//! The person's trust in a project's code: what a project names for the machine to run of itself — the MCP servers the
//! `.mcp.json` of its folder names — runs once the person trusts it, as a shell's hook loads a folder's environment file
//! once the person allowed it. A decision is the person's, on one folder's configuration as it was as they decided, by
//! a digest of its bytes: kept in `siphon.trust/`, a file named by both, so a configuration changed since is one they
//! have not decided on. A thread whose project names what they have not decided on asks them: a fiber of its own,
//! beside the thread's main fiber, makes a `trust` request, which no handler acts on — the person answers it — records
//! what they decided, and ends; one that finds the decision made meanwhile, as another thread asked, ends too. The
//! thread works on meanwhile, without what is not trusted. The person may decide unasked as well, or decide again —
//! trusting what they declined, or no longer what they trusted — recorded the same way, which ends any fiber asking it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const typebox = @import("typebox");
const beak = @import("../beak.zig");
const runtime_ = @import("../runtime.zig");
const Runtime = runtime_.Runtime;
const Phase = runtime_.Phase;
const Request = runtime_.Request;
const Changes = runtime_.Changes;

/// The program of a fiber that asks.
pub const program = "siphon.trust";
/// The name of the request the person answers.
pub const request_name = "trust";

/// The directory of the decisions.
const decisions = "siphon.trust";

/// What the person is asked: whether what the folder `folder` names in its configuration, the file at `path` of the
/// digest `digest`, may run — the servers it names, as they would be run.
pub const Asked = struct {
    folder: []const u8,
    path: []const u8,
    digest: []const u8,
    servers: []const Shown = &.{},
};

/// A server as the person is shown it: its name, and the command it is run as.
pub const Shown = struct { name: []const u8, command: []const u8, args: []const []const u8 = &.{} };

/// The person's answer to a trust request: whether what it names may run.
pub const Answer = struct { trusted: bool };

/// A decision, as its file keeps it.
pub const Decision = struct { folder: []const u8, digest: []const u8, trusted: bool };

/// Registers the program of a fiber that asks, and has the person answer its request.
pub fn register(runtime: *Runtime) !void {
    try runtime.register(.{ .kind = program, .phase = asking });
    try runtime.askPerson(request_name, .{ .fixed = typebox.of(Answer) });
}

/// The digest of a configuration's bytes `text`, as a decision names it.
pub fn digestOf(text: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// What the person decided on the configuration of `folder` of the digest `digest`: whether it may run; null where
/// they decided nothing on it.
pub fn decided(volume: beak.Volume, arena: *const Allocator, folder: []const u8, digest: []const u8) !?bool {
    const name = nameOf(folder, digest);
    const text = volume.readAll(arena, try beak.join(arena.*, decisions, &name)) catch |err| switch (err) {
        error.NotFound => return null,
        else => return err,
    };
    return (try foundation.json.decode(Decision, arena.*, text)).trusted;
}

/// Records `decision` with `changes`, in place of any made on the same configuration before.
pub fn record(changes: *Changes, arena: Allocator, decision: Decision) !void {
    const name = nameOf(decision.folder, decision.digest);
    try changes.mkdir(decisions);
    try changes.write(try beak.join(arena, decisions, &name), try foundation.json.encode(arena, decision));
}

/// The name of the decision on the configuration of `folder` of the digest `digest`, and of the fiber that asks it.
fn nameOf(folder: []const u8, digest: []const u8) [64]u8 {
    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
    hasher.update(folder);
    hasher.update("\x00");
    hasher.update(digest);
    return std.fmt.bytesToHex(hasher.finalResult(), .lower);
}

/// Has the person asked, with the phase's commit, what `asked` asks, for the thread at `thread`: by a fiber beside its
/// main fiber, started where none asks it already.
pub fn ask(phase: *Phase, thread: []const u8, asked: Asked) !void {
    const name = nameOf(asked.folder, asked.digest);
    const key = try std.mem.concat(phase.arena, u8, &.{ "trust-", &name });
    if (try phase.runtime.volume.stat(&phase.arena, try beak.childPath(phase.arena, thread, key)) != null) return;
    try phase.startIn(thread, key, program, asked);
}

/// Where a fiber that asks stands: its request of `key` waiting on the person's answer.
const Asking = struct { key: []const u8 };

/// A fiber that asks: makes its request, and sleeps till it is answered or the decision is made meanwhile; records
/// what the person answered, and ends. Its request waits on as the volume opens again, as no handler acts on it.
fn asking(_: ?*anyopaque, run: *Phase) anyerror!void {
    const asked = try foundation.json.decode(Asked, run.arena, run.input);
    if (try decided(run.runtime.volume, &run.arena, asked.folder, asked.digest) != null) return run.done(null);
    if (run.checkpoint.len == 0) return request(run, asked);
    const waiting = try foundation.json.decode(Asking, run.arena, run.checkpoint);
    const mail = try run.mailOf(waiting.key) orelse return run.waitForAny(Phase.kept, &.{ try run.mailPath(waiting.key), decisions });
    try run.take(waiting.key);
    if (!std.mem.eql(u8, mail.name, Request.answered_name)) return run.fail(mail.payload);
    const answer = try foundation.json.decode(Answer, run.arena, mail.payload);
    const decision: Decision = .{ .folder = asked.folder, .digest = asked.digest, .trusted = answer.trusted };
    try record(&run.changes, run.arena, decision);
    return run.done(decision);
}

/// Makes the request that asks the person what `asked` asks, and sleeps till it is answered or the decision is made.
fn request(run: *Phase, asked: Asked) !void {
    const key = try run.mint();
    try run.request(request_name, key, asked);
    return run.waitForAny(Asking{ .key = key }, &.{ try run.mailPath(key), decisions });
}
