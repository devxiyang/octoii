//! A fake host for Siphon's tests: a clock the test sets, a fake provider's model and what it streams, tools that act
//! as a test needs, and the hands that drive Siphon's loop and read its fibers and threads.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const ai = @import("ai");
const beak = @import("beak.zig");
const h = beak.h;
const Siphon = @import("Siphon.zig");
const Changes = @import("runtime.zig").Changes;
const threads = @import("threads.zig");
const tools = @import("tools.zig");
const log = @import("threads.zig").log;
const scripts = @import("tools.zig").scripts;
const paths = @import("machine.zig").paths;

/// A clock that stands where the test puts it.
pub const Clock = struct {
    now_ms: i64,

    pub fn clock(set: *Clock) foundation.time.Clock {
        return .{ .context = set, .vtable = &.{ .now_ms = nowMs } };
    }

    fn nowMs(context: *anyopaque) i64 {
        const set: *Clock = @ptrCast(@alignCast(context));
        return set.now_ms;
    }
};

/// Siphon on a fake host: the test's clock, and memory or a directory for the volume.
pub fn open(clock: *Clock, device: Siphon.Device) !*Siphon {
    return Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = clock.clock(), .device = device }, .{});
}

/// Siphon on a fake host whose models are those of `providers`.
pub fn openOver(clock: *Clock, device: Siphon.Device, providers: []const ai.driver.Provider) !*Siphon {
    return Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = clock.clock(), .device = device }, .{ .providers = providers });
}

/// The fake provider's text model.
pub const model: ai.Model = .{
    .id = "m",
    .name = "M",
    .architecture = .{ .input_modalities = &.{.text}, .output_modalities = &.{.text} },
    .octoii = .{ .provider = "fake", .kinds = &.{.text} },
};

/// A response streamed whole, of `output`.
pub fn streamed(arena: Allocator, output: []const vocabulary.OutputItem) !ai.testing.fake.Answer {
    var events: std.ArrayList(vocabulary.ResponseStreamEvent) = .empty;
    try events.append(arena, .{ .created = .{ .response = .{ .id = "r", .status = .in_progress, .output = &.{} }, .sequence_number = 0 } });
    for (output, 0..) |item, index| {
        try events.append(arena, .{ .output_item_added = .{ .item = item, .output_index = @intCast(index), .sequence_number = 0 } });
        try events.append(arena, .{ .output_item_done = .{ .item = item, .output_index = @intCast(index), .sequence_number = 0 } });
    }
    try events.append(arena, .{ .completed = .{ .response = .{ .id = "r", .status = .completed, .output = try arena.dupe(vocabulary.OutputItem, output) }, .sequence_number = 0 } });
    return .{ .events = events.items };
}

/// A reply of the message `text`, streamed whole.
pub fn message(arena: Allocator, text: []const u8) !ai.testing.fake.Answer {
    const parts = try arena.dupe(vocabulary.OutputContent, &.{.{ .output_text = .{ .text = text } }});
    return streamed(arena, &.{.{ .output_message = .{ .id = "m1", .content = .{ .parts = parts } } }});
}

/// The providers' credentials held in memory, as a host keeps them: each a copy of its own, in `arena`.
pub const Credentials = struct {
    arena: Allocator,
    kept: std.StringArrayHashMapUnmanaged(ai.driver.Credential) = .empty,

    pub fn credentials(store: *Credentials) ai.driver.Credentials {
        return .{ .context = store, .vtable = &.{ .read = read, .modify = modify, .remove = remove } };
    }

    fn of(context: *anyopaque) *Credentials {
        return @ptrCast(@alignCast(context));
    }

    fn read(context: *anyopaque, _: Allocator, provider: []const u8) error{ Unavailable, OutOfMemory }!?ai.driver.Credential {
        return of(context).kept.get(provider);
    }

    fn modify(context: *anyopaque, arena: Allocator, provider: []const u8, change: ai.driver.Credentials.Change) ai.driver.Credentials.ModifyError!?ai.driver.Credential {
        const store = of(context);
        const current = store.kept.get(provider);
        const applied = change.apply(change.context, arena, current) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Failed,
        };
        const changed = applied orelse return current;
        // Kept as a copy, as the host's store writes what it is given.
        const copy = foundation.json.decode(ai.driver.Credential, store.arena, try foundation.json.encode(store.arena, changed)) catch return error.Failed;
        try store.kept.put(store.arena, try store.arena.dupe(u8, provider), copy);
        return copy;
    }

    fn remove(context: *anyopaque, provider: []const u8) error{Unavailable}!void {
        _ = of(context).kept.orderedRemove(provider);
    }
};

/// A call of `execute` that runs `code`, by the provider's id `id`.
pub fn executing(arena: Allocator, id: []const u8, code: []const u8) !vocabulary.OutputItem {
    return call(id, scripts.execute.name, try foundation.json.encode(arena, .{ .code = code }));
}

/// The outputs of the calls the model was told of last, in its request `index`, as it read them.
pub fn toldOutputs(fake: *const ai.testing.Fake, arena: Allocator, index: usize) ![]const []const u8 {
    var outputs: std.ArrayList([]const u8) = .empty;
    for (fake.requests.items[index].input.?.parts) |item| if (item == .function_call_output) try outputs.append(arena, item.function_call_output.output.text);
    return outputs.items;
}

/// A call of the tool `name` with `arguments`, by the provider's id `id`.
pub fn call(id: []const u8, name: []const u8, arguments: []const u8) vocabulary.OutputItem {
    return .{ .function_call = .{ .id = id, .call_id = id, .name = name, .arguments = arguments } };
}

/// Whether `declared`, the tools a request declares, hold the tool `name`.
pub fn declares(declared: []const vocabulary.Tool, name: []const u8) bool {
    for (declared) |tool| if (std.mem.eql(u8, tool.function.name, name)) return true;
    return false;
}

/// What a person says.
pub fn said(text: []const u8) threads.Input {
    return .{ .message = .{ .role = .user, .content = .{ .text = text } } };
}

/// A tool that may act and takes long: it runs until a stop cancels it; how often it began.
pub const Slow = struct {
    began: std.atomic.Value(u32) = .init(0),

    pub fn tool(slow: *Slow) @import("tools.zig").Tool {
        return .{ .name = "deploy", .description = "Deploys.", .parameters = "{\"type\":\"object\"}", .access = deploys, .context = slow, .work = .{ .task = run } };
    }

    /// What a call of it does: anything, as a tool of its name.
    fn deploys(arena: Allocator, _: ?paths.Base, _: []const u8) anyerror!tools.Tool.Access {
        const resources = try arena.dupe([]const u8, &.{"deploy"});
        return .{ .action = .tool, .resources = resources, .save = resources };
    }

    fn run(context: ?*anyopaque, given: *const tools.Tool.Run) anyerror!tools.Tool.Output {
        const slow: *Slow = @ptrCast(@alignCast(context.?));
        _ = slow.began.fetchAdd(1, .monotonic);
        try given.runtime.host.io.sleep(.fromSeconds(3600), .awake);
        return .{ .text = "deployed" };
    }

    pub fn hasBegun(slow: *Slow) bool {
        return slow.began.load(.acquire) > 0;
    }

    pub fn bothBegun(slow: *Slow) bool {
        return slow.began.load(.acquire) >= 2;
    }
};

/// The entries of the thread's log: each one's type; for a result its status, and the call it was made under where it
/// was; for calls made under one, the call and their tools.
pub fn entriesOf(siphon: *Siphon, arena: Allocator, tid: []const u8) ![]const []const u8 {
    const lines = try log.lines(siphon.runtime.volume, &arena, try threads.pathOf(arena, tid));
    const out = try arena.alloc([]const u8, lines.len);
    for (lines, out) |line, *shown| {
        const head = try log.headOf(arena, line);
        var words: std.ArrayList(u8) = .empty;
        try words.appendSlice(arena, head.type);
        if (std.mem.eql(u8, head.type, "result")) try words.print(arena, " {t}", .{(try foundation.json.decode(log.Result, arena, line)).status});
        if (std.mem.eql(u8, head.type, "calls")) for ((try foundation.json.decode(log.Calls, arena, line)).calls) |made| try words.print(arena, " {s}", .{made.name});
        if (head.under) |under| try words.print(arena, " under {s}", .{under});
        shown.* = words.items;
    }
    return out;
}

/// Expects the entries of the thread's log to be `expected`, as `entriesOf` gives them.
pub fn expectEntries(siphon: *Siphon, arena: Allocator, tid: []const u8, expected: []const []const u8) !void {
    const found = try entriesOf(siphon, arena, tid);
    errdefer for (found) |got| std.debug.print("found {s}\n", .{got});
    try std.testing.expectEqual(expected.len, found.len);
    for (expected, found) |want, got| try std.testing.expectEqualStrings(want, got);
}

/// The Chromium on this machine a test opens pages in, where there is one.
pub fn chromium() ?[]const u8 {
    const candidates = [_][]const u8{ "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/Applications/Chromium.app/Contents/MacOS/Chromium", "/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser" };
    for (candidates) |path| {
        std.Io.Dir.cwd().access(std.testing.io, path, .{}) catch continue;
        return path;
    }
    return null;
}

/// A PNG of `width` by `height` grey pixels, opaque, made at compile time: its header, its pixels in one stored
/// deflate block within zlib, and its end, each chunk with its CRC — a picture to fit.
pub fn pngOf(comptime width: u32, comptime height: u32) [pngLength(width, height)]u8 {
    @setEvalBranchQuota(1_000_000);
    const row = 1 + width * 4;
    var pixels: [row * height]u8 = undefined;
    for (0..height) |y| {
        pixels[y * row] = 0;
        for (0..width * 4) |i| pixels[y * row + 1 + i] = if (i % 4 == 3) 0xff else 0x80;
    }
    var zlib: [2 + 5 + pixels.len + 4]u8 = undefined;
    zlib[0] = 0x78;
    zlib[1] = 0x01;
    zlib[2] = 0x01;
    std.mem.writeInt(u16, zlib[3..5], pixels.len, .little);
    std.mem.writeInt(u16, zlib[5..7], ~@as(u16, pixels.len), .little);
    @memcpy(zlib[7 .. 7 + pixels.len], &pixels);
    std.mem.writeInt(u32, zlib[7 + pixels.len ..][0..4], std.hash.Adler32.hash(&pixels), .big);
    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    header[8..13].* = .{ 8, 6, 0, 0, 0 };
    return "\x89PNG\x0d\x0a\x1a\x0a".* ++ chunkOf("IHDR", &header) ++ chunkOf("IDAT", &zlib) ++ chunkOf("IEND", "");
}

fn pngLength(comptime width: u32, comptime height: u32) usize {
    const pixels = (1 + width * 4) * height;
    return 8 + (12 + 13) + (12 + 2 + 5 + pixels + 4) + 12;
}

/// A PNG chunk: its length, its type and data, and the CRC of both.
fn chunkOf(comptime kind: *const [4]u8, comptime data: []const u8) [12 + data.len]u8 {
    var chunk: [12 + data.len]u8 = undefined;
    std.mem.writeInt(u32, chunk[0..4], data.len, .big);
    chunk[4..8].* = kind.*;
    @memcpy(chunk[8 .. 8 + data.len], data);
    std.mem.writeInt(u32, chunk[8 + data.len ..][0..4], std.hash.Crc32.hash(chunk[4 .. 8 + data.len]), .big);
    return chunk;
}

/// The local machine, with no ledger and no sandbox.
pub fn openLocalMachine() !h.beak_handle {
    const local: h.beak_local_machine = .{ .ledger = beak.bytes(""), .sandbox_helper = beak.bytes("") };
    var machine: h.beak_handle = 0;
    var stopped: u64 = 0;
    try beak.check(h.beak_machine_open_local(&local, &machine, &stopped));
    return machine;
}

/// How a fiber ended: completed, failed or stopped, with its result or its error.
pub const Outcome = struct { status: enum { completed, failed, stopped }, said: []const u8 };

/// Starts a fiber of the program `kind` at the volume's root, keyed by `key`; its path.
pub fn startFiber(siphon: *Siphon, arena: Allocator, key: []const u8, kind: []const u8) ![]const u8 {
    var changes: Changes = .{ .arena = arena };
    try changes.start("", key, kind, siphon.runtime.versionOf(kind) orelse return error.NoSuchProgram, "", "");
    _ = try siphon.runtime.commit(&changes);
    return beak.childPath(arena, "", key);
}

/// Asks the fiber at `path` to stop, as a person's stop does: its stop handler runs, its requests are cut off.
pub fn stopFiber(siphon: *Siphon, arena: Allocator, path: []const u8) !void {
    var changes: Changes = .{ .arena = arena };
    try changes.terminate(path, "stopped");
    _ = try siphon.runtime.commit(&changes);
}

/// How the fiber at `path` ended; null while it lives.
pub fn outcomeOf(siphon: *Siphon, arena: *const Allocator, path: []const u8) !?Outcome {
    const entry = try siphon.runtime.volume.stat(arena, path) orelse return error.NoSuchFiber;
    const outcome = beak.outcomeOf(entry) orelse return null;
    const text = if (outcome.has_result) outcome.result else outcome.@"error";
    return .{
        .status = switch (outcome.status) {
            h.BEAK_OUTCOME_COMPLETED => .completed,
            h.BEAK_OUTCOME_FAILED => .failed,
            else => .stopped,
        },
        .said = beak.slice(text),
    };
}

/// Pumps until `ready` says the test may go on, waiting for news between pumps, as a handler's answer comes from its
/// task.
pub fn pumpUntil(siphon: *Siphon, context: anytype, comptime ready: fn (@TypeOf(context)) bool) !void {
    for (0..rounds_max) |_| {
        const pumped = try siphon.runtime.pump();
        if (ready(context)) return;
        if (!pumped.more) siphon.runtime.waitForNews(news_wait_ms);
    }
    return error.NeverReady;
}

/// Pumps until the thread `tid` stands at `status`.
pub fn pumpUntilStatus(siphon: *Siphon, arena: Allocator, tid: []const u8, status: threads.Status) !void {
    const At = struct {
        siphon: *Siphon,
        arena: Allocator,
        tid: []const u8,
        status: threads.Status,
        fn reached(at: *const @This()) bool {
            const now = threads.state(at.siphon.runtime, at.arena, at.tid) catch return false;
            return now.status == at.status;
        }
    };
    const at: At = .{ .siphon = siphon, .arena = arena, .tid = tid, .status = status };
    return pumpUntil(siphon, &at, At.reached);
}

/// Pumps until a fiber of the thread `tid` waits on a request named `name`; that request, as the thread's state shows
/// it.
pub fn pumpUntilAsked(siphon: *Siphon, arena: Allocator, tid: []const u8, name: []const u8) !threads.Open {
    const Asked = struct {
        siphon: *Siphon,
        arena: Allocator,
        tid: []const u8,
        name: []const u8,

        fn find(asked: *const @This()) ?threads.Open {
            const now = threads.state(asked.siphon.runtime, asked.arena, asked.tid) catch return null;
            for (now.processes) |process| for (process.requests) |request| {
                if (std.mem.eql(u8, request.name, asked.name)) return request;
            };
            return null;
        }

        fn made(asked: *const @This()) bool {
            return asked.find() != null;
        }
    };
    const asked: Asked = .{ .siphon = siphon, .arena = arena, .tid = tid, .name = name };
    try pumpUntil(siphon, &asked, Asked.made);
    return asked.find().?;
}

/// Pumps until the fiber at `path` ended; how it ended.
pub fn pumpUntilEnded(siphon: *Siphon, arena: *const Allocator, path: []const u8) !Outcome {
    const Ended = struct {
        siphon: *Siphon,
        arena: *const Allocator,
        path: []const u8,

        fn check(ended: *const @This()) bool {
            return (outcomeOf(ended.siphon, ended.arena, ended.path) catch return false) != null;
        }
    };
    const ended: Ended = .{ .siphon = siphon, .arena = arena, .path = path };
    try pumpUntil(siphon, &ended, Ended.check);
    return (try outcomeOf(siphon, arena, path)).?;
}

/// Pumps until the thread `tid` is at rest — a turn settled, none running, nothing waiting; its state then.
pub fn pumpUntilSettled(siphon: *Siphon, arena: Allocator, tid: []const u8) !threads.State {
    const Settled = struct {
        siphon: *Siphon,
        arena: Allocator,
        tid: []const u8,

        fn check(settled: *const @This()) bool {
            const now = threads.state(settled.siphon.runtime, settled.arena, settled.tid) catch return false;
            return now.status != .created and now.status != .running and now.inbox.len == 0;
        }
    };
    const settled: Settled = .{ .siphon = siphon, .arena = arena, .tid = tid };
    try pumpUntil(siphon, &settled, Settled.check);
    return threads.state(siphon.runtime, arena, tid);
}

const rounds_max = 200;
const news_wait_ms = 50;
