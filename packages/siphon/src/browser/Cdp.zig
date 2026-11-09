//! The DevTools protocol of a Chromium browser, spoken over the pipe it reads on descriptor 3 and writes on 4 — JSON
//! messages, each ended by a NUL — as the loop pumps: a command written never waiting, its answer handed, as it comes,
//! to what asked for it, by the key it asked with, as epoll hands back the data a descriptor was added with; an event
//! handed to the listener with the session it is of. What waits for an answer as the browser ends is told so, as a
//! call on a device gone fails. The loop alone touches it.
const Cdp = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const beak = @import("../beak.zig");
const h = beak.h;

const log = std.log.scoped(.siphon);

allocator: Allocator,
/// The browser's command, whose input is the pipe it reads.
command: h.beak_handle,
listener: Listener,
next_id: u64 = 1,
/// What waits for each command's answer, by the command's id.
waiting: std.AutoHashMapUnmanaged(u64, Answered) = .empty,
/// What came of the pipe and ends in no NUL yet.
partial: std.ArrayList(u8) = .empty,

/// The params of a command that takes none.
pub const none: struct {} = .{};

/// What hears the browser's events: each with the session it is of, none for the browser's own.
pub const Listener = struct {
    context: *anyopaque,
    event: *const fn (context: *anyopaque, session: ?[]const u8, method: []const u8, params: std.json.Value) void,
};

/// What hears a command's answer: the key it asked with, and the answer, which lasts the call.
pub const Answered = struct {
    context: *anyopaque,
    key: u64,
    answered: *const fn (context: *anyopaque, key: u64, answer: Answer) void,
};

/// A command's answer: its result; the browser's words for why it failed; or that the browser ended before it answered.
pub const Answer = union(enum) { result: std.json.Value, failure: []const u8, ended };

/// Lets go of the pipe's state, the browser ended: what waits for an answer told so.
pub fn deinit(cdp: *Cdp) void {
    var waiting = cdp.waiting;
    cdp.waiting = .empty;
    defer waiting.deinit(cdp.allocator);
    var each = waiting.valueIterator();
    while (each.next()) |waiter| waiter.answered(waiter.context, waiter.key, .ended);
    cdp.partial.deinit(cdp.allocator);
}

/// Sends `method` with `params` to the browser, or to the target of `session`; its answer handed to `answered`, where
/// something waits for it.
pub fn send(cdp: *Cdp, session: ?[]const u8, method: []const u8, params: anytype, answered: ?Answered) !void {
    const Params = @TypeOf(params);
    if (@typeInfo(Params) == .@"struct" and @typeInfo(Params).@"struct".is_tuple) @compileError("a command's params are an object, which a tuple is written as no more: give `none`");
    var written: std.Io.Writer.Allocating = .init(cdp.allocator);
    defer written.deinit();
    std.json.Stringify.value(params, .{ .emit_null_optional_fields = false }, &written.writer) catch return error.OutOfMemory;
    try cdp.sendJson(session, method, written.written(), answered);
}

/// Sends `method` with `params`, a JSON object as it is written, to the browser, or to the target of `session`; its
/// answer handed to `answered`, where something waits for it.
pub fn sendJson(cdp: *Cdp, session: ?[]const u8, method: []const u8, params: []const u8, answered: ?Answered) !void {
    const id = cdp.next_id;
    cdp.next_id += 1;
    var out: std.Io.Writer.Allocating = .init(cdp.allocator);
    defer out.deinit();
    const writer = &out.writer;
    writer.print("{{\"id\":{d},\"method\":{f}", .{ id, std.json.fmt(method, .{}) }) catch return error.OutOfMemory;
    if (session) |own| writer.print(",\"sessionId\":{f}", .{std.json.fmt(own, .{})}) catch return error.OutOfMemory;
    writer.print(",\"params\":{s}}}\x00", .{params}) catch return error.OutOfMemory;
    if (answered) |waiter| try cdp.waiting.put(cdp.allocator, id, waiter);
    errdefer _ = cdp.waiting.remove(id);
    try beak.check(h.beak_command_write(cdp.command, beak.bytes(out.written())));
}

/// Takes what the browser wrote: each message it ended handed on.
pub fn take(cdp: *Cdp, bytes: []const u8) void {
    cdp.partial.appendSlice(cdp.allocator, bytes) catch {
        log.warn("the browser's messages are lost: no room to hold them", .{});
        cdp.partial.clearRetainingCapacity();
        return;
    };
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, cdp.partial.items, start, 0)) |end| : (start = end + 1) {
        cdp.handle(cdp.partial.items[start..end]);
    }
    const rest = cdp.partial.items.len - start;
    std.mem.copyForwards(u8, cdp.partial.items[0..rest], cdp.partial.items[start..]);
    cdp.partial.shrinkRetainingCapacity(rest);
}

/// Hands on one message: an answer to what waits for it, an event to the listener.
fn handle(cdp: *Cdp, message: []const u8) void {
    var arena_allocator: std.heap.ArenaAllocator = .init(cdp.allocator);
    defer arena_allocator.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena_allocator.allocator(), message, .{}) catch return log.warn("the browser wrote what is no message", .{});
    if (parsed != .object) return;
    const object = parsed.object;
    if (object.get("id")) |id| {
        if (id != .integer) return;
        const waiter = (cdp.waiting.fetchRemove(@intCast(id.integer)) orelse return).value;
        const answer: Answer = if (object.get("error")) |failure| .{ .failure = textOf(failure, "message") orelse "failed" } else .{ .result = object.get("result") orelse .null };
        return waiter.answered(waiter.context, waiter.key, answer);
    }
    const method = object.get("method") orelse return;
    if (method != .string) return;
    const session = if (object.get("sessionId")) |value| if (value == .string) value.string else null else null;
    cdp.listener.event(cdp.listener.context, session, method.string, object.get("params") orelse .null);
}

/// The string member `name` of `value`, where it is an object that has one.
pub fn textOf(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const member = value.object.get(name) orelse return null;
    return if (member == .string) member.string else null;
}

/// The number member `name` of `value`, where it is an object that has one.
pub fn numberOf(value: std.json.Value, name: []const u8) ?f64 {
    if (value != .object) return null;
    return switch (value.object.get(name) orelse return null) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => null,
    };
}

/// The member `name` of `value`, where it is an object that has one.
pub fn memberOf(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}

test "messages are taken whole across what is read, answers handed to what waits by its key, events to the listener" {
    const Heard = struct {
        events: std.ArrayList([]const u8) = .empty,
        answers: std.ArrayList(u64) = .empty,
        failures: usize = 0,
        fn event(context: *anyopaque, session: ?[]const u8, method: []const u8, _: std.json.Value) void {
            const heard: *@This() = @ptrCast(@alignCast(context));
            heard.events.ensureUnusedCapacity(std.testing.allocator, 1) catch return;
            heard.events.appendAssumeCapacity(std.testing.allocator.print("{s} {s}", .{ session orelse "-", method }) catch return);
        }
        fn answered(context: *anyopaque, key: u64, answer: Answer) void {
            const heard: *@This() = @ptrCast(@alignCast(context));
            if (answer == .failure) heard.failures += 1;
            heard.answers.append(std.testing.allocator, key) catch {};
        }
    };
    var heard: Heard = .{};
    defer {
        for (heard.events.items) |each| std.testing.allocator.free(each);
        heard.events.deinit(std.testing.allocator);
        heard.answers.deinit(std.testing.allocator);
    }
    var cdp: Cdp = .{ .allocator = std.testing.allocator, .command = 0, .listener = .{ .context = &heard, .event = Heard.event } };
    defer cdp.deinit();
    try cdp.waiting.put(std.testing.allocator, 1, .{ .context = &heard, .key = 7, .answered = Heard.answered });
    try cdp.waiting.put(std.testing.allocator, 2, .{ .context = &heard, .key = 8, .answered = Heard.answered });
    cdp.take("{\"id\":1,\"result\":{}}\x00{\"method\":\"Page.loadEventFired\",\"sessionId\":\"S\",\"params\":{}}\x00{\"id\":2,\"err");
    cdp.take("or\":{\"message\":\"no\"}}\x00{\"method\":\"Target.targetCreated\",\"params\":{}}\x00");
    try std.testing.expectEqualSlices(u64, &.{ 7, 8 }, heard.answers.items);
    try std.testing.expectEqual(@as(usize, 1), heard.failures);
    try std.testing.expectEqual(@as(usize, 2), heard.events.items.len);
    try std.testing.expectEqualStrings("S Page.loadEventFired", heard.events.items[0]);
    try std.testing.expectEqualStrings("- Target.targetCreated", heard.events.items[1]);
    try std.testing.expectEqual(@as(usize, 0), cdp.partial.items.len);
}
