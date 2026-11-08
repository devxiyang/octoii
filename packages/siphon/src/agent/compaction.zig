//! Compaction: where a window of the conversation grows past what its model takes, everything before its latest work
//! is recapped by the model, and a new window begins — what the model is told, gathered anew, the recap, then the
//! person's latest input and the latest work, kept as they stand: nothing copied, every entry once in the log. A window
//! is cut before a step of the conversation — an input, or a reply with what came of it — so a call is never kept
//! without its result, and a cut within a turn keeps the input that began it as well. The cut is weighed before the
//! model is asked, and again where its provider refuses a request as too long; a window is compacted once for one
//! request, so a window too long still for its model fails its turn.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const threads = @import("../threads.zig");
const models = @import("models.zig");
const log = threads.log;
const Window = threads.Window;

/// The tokens a window keeps free, past its model's context less them it is compacted: room for what the next request
/// adds and for the reply.
pub const reserve_tokens = 16 * 1024;
/// The tokens of the latest entries a compaction keeps as they stand, at most — though always from the latest step on.
pub const kept_tokens = 20_000;

/// Where a window is cut: the input it keeps as the person gave it, the latest before the cut; the first entry it keeps
/// after, the input itself where the cut falls at one; and the last entry the recap covers.
pub const Cut = struct { kept: []const u8, from: []const u8, until: []const u8 };

/// Whether `window` is past what a model of `context_length` tokens takes, less `reserve_tokens`; never where the
/// model's context is not known, which its provider's refusal of a request too long tells instead.
pub fn isFull(arena: Allocator, window: Window, context_length: ?u64) !bool {
    const length = context_length orelse return false;
    return try tokensOf(arena, window) + reserve_tokens > length;
}

/// The tokens the window's next request takes, as near as its log tells: what the window's last request took, as its
/// reply says — its context, and what it gave — and a token for every four bytes of what has come since; of the whole
/// window where no reply of its own says.
pub fn tokensOf(arena: Allocator, window: Window) !u64 {
    var since: u64 = 0;
    var at = window.conversation.len;
    while (at > window.carried) {
        at -= 1;
        const line = window.conversation[at];
        if (std.mem.eql(u8, (try log.headOf(arena, line)).type, "reply")) {
            const reply = try foundation.json.decode(log.Reply, arena, line);
            const response = try foundation.json.decode(vocabulary.Response, arena, reply.response.text);
            const context = if (response.octoii) |extension| extension.context_tokens else null;
            if (context) |taken| return taken + (if (response.usage) |usage| usage.output_tokens else line.len / 4) + since;
        }
        since += line.len / 4;
    }
    var whole: u64 = 0;
    for (window.told) |line| whole += line.len / 4;
    if (window.compaction) |made| whole += (try recapIn(arena, made)).len / 4;
    for (window.conversation) |line| whole += line.len / 4;
    return whole;
}

/// The recap the compaction `made` holds: the text its response gave.
pub fn recapIn(arena: Allocator, made: log.Compaction) ![]const u8 {
    return try models.textOf(arena, try foundation.json.decode(vocabulary.Response, arena, made.response.text)) orelse error.NoRecap;
}

/// Where `window` is cut: before the earliest step whose entries from it on take at most `kept_tokens`, else before
/// the latest, so the latest work is kept as it stands, and the input of the step's turn with it; none where nothing
/// but that input stands before any step, to recap.
pub fn cutOf(arena: Allocator, window: Window) !?Cut {
    const lines = window.conversation;
    const heads = try arena.alloc(log.Head, lines.len);
    for (lines, heads) |line, *head| head.* = try log.headOf(arena, line);
    // The latest input at or before each entry: the one a cut before the entry keeps.
    const inputs = try arena.alloc(?usize, lines.len);
    var latest: ?usize = null;
    for (heads, inputs, 0..) |head, *input, index| {
        if (std.mem.eql(u8, head.type, "input")) latest = index;
        input.* = latest;
    }
    var tail: u64 = 0;
    var chosen: ?Cut = null;
    var at = lines.len;
    while (at > 0) {
        at -= 1;
        tail += lines[at].len / 4;
        if (!std.mem.eql(u8, heads[at].type, "input") and !std.mem.eql(u8, heads[at].type, "reply")) continue;
        if (chosen != null and tail > kept_tokens) break;
        const kept = inputs[at] orelse continue;
        // What the recap covers: every entry before the step but the input kept.
        const recapped = if (kept == at) at else at - 1;
        if (recapped == 0) continue;
        chosen = .{ .kept = heads[kept].id, .from = heads[at].id, .until = heads[at - 1].id };
    }
    return chosen;
}

/// What a recap request asks of the model, after the conversation it recaps.
pub const instruction =
    \\Write a recap of the conversation above, for a model that carries on the work with the recap in place of it, then the person's latest request and the latest messages as they are. That model is given the instructions and the environment anew, so leave them out. Keep:
    \\- what the person asked for, in their own words where the words matter, and what is still to do;
    \\- what was done and found: the files, the symbols, the commands and what they gave, the errors, word for word;
    \\- the decisions made, and why;
    \\- where the work stands: what is changed, what is tested, what is committed.
    \\Where the conversation begins with an earlier recap, carry forward what still holds: this recap takes its place. Write the recap alone, with no greeting, no question and no tool call.
;

fn inputLine(comptime id: []const u8) []const u8 {
    return "{\"id\":\"" ++ id ++ "\",\"type\":\"input\",\"delivery_id\":\"d\",\"actor\":\"person\",\"message\":{\"role\":\"user\",\"content\":\"x\"}}";
}

fn resultLine(arena: Allocator, id: []const u8, output: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"type\":\"result\",\"status\":\"ok\",\"call_output\":{{\"type\":\"function_call_output\",\"call_id\":\"c\",\"output\":\"{s}\"}}}}", .{ id, output });
}

fn replyLine(comptime id: []const u8, comptime context_tokens: []const u8) []const u8 {
    return "{\"id\":\"" ++ id ++ "\",\"type\":\"reply\",\"request\":\"q\",\"response\":{\"id\":\"r\",\"status\":\"completed\",\"output\":[],\"octoii\":{\"context_tokens\":" ++ context_tokens ++ "}}}";
}

test "a window is cut before the earliest step its kept tokens reach, else before the latest, with something to recap" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const long = try arena.alloc(u8, kept_tokens * 4);
    @memset(long, 'x');
    const turns = [_][]const u8{ inputLine("1"), try resultLine(arena, "2", long), inputLine("3"), inputLine("4") };
    const cut = (try cutOf(arena, try Window.of(arena, &turns))).?;
    try std.testing.expectEqualStrings("3", cut.kept);
    try std.testing.expectEqualStrings("3", cut.from);
    try std.testing.expectEqualStrings("2", cut.until);

    // One long turn is cut within it, before a reply, and keeps the input that began it.
    const one = [_][]const u8{ inputLine("1"), replyLine("2", "1"), try resultLine(arena, "3", long), replyLine("4", "1"), try resultLine(arena, "5", "y") };
    const within = (try cutOf(arena, try Window.of(arena, &one))).?;
    try std.testing.expectEqualStrings("1", within.kept);
    try std.testing.expectEqualStrings("4", within.from);
    try std.testing.expectEqualStrings("3", within.until);

    // Where nothing but the input stands before a step, there is nothing to recap.
    try std.testing.expect(try cutOf(arena, try Window.of(arena, turns[0..1])) == null);
    try std.testing.expect(try cutOf(arena, try Window.of(arena, &.{ inputLine("1"), replyLine("2", "1") })) == null);
    // Its model's context known, a window past it less what it keeps free is full.
    try std.testing.expect(try isFull(arena, try Window.of(arena, &turns), kept_tokens + reserve_tokens));
    try std.testing.expect(!try isFull(arena, try Window.of(arena, &turns), null));
}

test "a window is weighed by what its own replies say, never by those it carried from before its compaction" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = [_][]const u8{
        inputLine("1"),
        replyLine("2", "1000000"),
        inputLine("3"),
        \\{"id":"4","type":"compaction","request":"q4","response":{"id":"r","status":"completed","output":[{"type":"message","role":"assistant","content":"r"}]},"kept":"1","from":"2"}
        ,
    };
    const window = try Window.of(arena, &lines);
    try std.testing.expect(!try isFull(arena, window, 200_000));
    const asked = lines ++ [_][]const u8{replyLine("5", "190000")};
    try std.testing.expect(try isFull(arena, try Window.of(arena, &asked), 200_000));
}
