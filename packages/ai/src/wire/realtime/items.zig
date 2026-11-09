//! The items of a realtime transcription whose provider has none, as Deepgram's and xAI's streams have none: the audio
//! sent counted into the item it makes, its text heard as partial and settled text, its speakers as segments, and its
//! end as the item committed and completed, with the seconds of the audio sent since the item before it. And what such
//! a stream, which takes its settings as it connects, shares: the settings it refuses, and its answer to a
//! `session.update`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const realtime = vocabulary.realtime;
const session_ = @import("session.zig");
const Out = session_.Out;
const Ids = session_.Ids;
const itemId = session_.itemId;

/// The bytes of a second of raw mono PCM16 at 24 kHz, the session's one format.
const pcm_bytes_per_second: f64 = realtime.pcm_rate_hz * 2;

/// A word heard, with its times in seconds and its speaker, where the provider tells speakers apart.
pub const HeardWord = struct { text: []const u8, start: f64, end: f64, speaker: ?i64 = null };

/// The item under way and the audio counted into the items before it.
pub const HeardItems = struct {
    gpa: Allocator,
    ids: *Ids,
    item: u64,
    previous: ?u64 = null,
    settled: std.ArrayList(u8) = .empty,
    partial: std.ArrayList(u8) = .empty,
    bytes_sent: u64 = 0,
    bytes_counted: u64 = 0,
    /// The seconds of audio, from the session's start, whose text `input_audio_buffer.clear` dropped.
    cleared_until_seconds: f64 = 0,

    pub fn init(gpa: Allocator, ids: *Ids) HeardItems {
        return .{ .gpa = gpa, .ids = ids, .item = ids.item() };
    }

    pub fn deinit(items: *HeardItems) void {
        items.settled.deinit(items.gpa);
        items.partial.deinit(items.gpa);
    }

    pub fn secondsSent(items: *const HeardItems) f64 {
        return @as(f64, @floatFromInt(items.bytes_sent)) / pcm_bytes_per_second;
    }

    /// Counts `bytes` of audio sent into the item under way.
    pub fn sent(items: *HeardItems, bytes: usize) void {
        items.bytes_sent += bytes;
    }

    /// Whether the item under way holds nothing: no audio sent into it and no text settled.
    pub fn isEmpty(items: *const HeardItems) bool {
        return items.bytes_sent == items.bytes_counted and items.settled.items.len == 0;
    }

    /// Whether what was heard from `start_seconds` for `duration_seconds` is of audio a clear dropped.
    pub fn isCleared(items: *const HeardItems, start_seconds: f64, duration_seconds: f64) bool {
        return start_seconds + duration_seconds <= items.cleared_until_seconds;
    }

    /// The text the item under way has settled so far.
    pub fn settledText(items: *const HeardItems) []const u8 {
        return items.settled.items;
    }

    /// Drops what comes of the audio sent so far, and says so.
    pub fn clear(items: *HeardItems, out: *Out) Allocator.Error!void {
        items.cleared_until_seconds = items.secondsSent();
        items.partial.clearRetainingCapacity();
        try out.give(.{ .cleared = .{ .event_id = try items.ids.event(out.arena) } });
    }

    /// The partial text of the item under way, where it changed.
    pub fn heard(items: *HeardItems, out: *Out, text: []const u8) Allocator.Error!void {
        if (std.mem.eql(u8, text, items.partial.items)) return;
        items.partial.clearRetainingCapacity();
        try items.partial.appendSlice(items.gpa, text);
        try out.give(.{ .partial = .{ .item_id = try itemId(out.arena, items.item), .content_index = 0, .text = try out.arena.dupe(u8, text), .event_id = try items.ids.event(out.arena) } });
    }

    /// `text` settled after what the item under way has settled, as a delta, and the partial text it ends.
    pub fn settle(items: *HeardItems, out: *Out, text: []const u8) Allocator.Error!void {
        items.partial.clearRetainingCapacity();
        if (text.len == 0) return;
        const delta = if (items.settled.items.len == 0) try out.arena.dupe(u8, text) else try out.arena.print(" {s}", .{text});
        try items.settled.appendSlice(items.gpa, delta);
        try out.give(.{ .delta = .{ .item_id = try itemId(out.arena, items.item), .content_index = 0, .delta = delta, .event_id = try items.ids.event(out.arena) } });
    }

    /// The segments of `words`, a run of words of one speaker each, for a provider that told their speakers.
    pub fn segments(items: *HeardItems, out: *Out, words: []const HeardWord) Allocator.Error!void {
        for (words) |word| if (word.speaker == null) return;
        var start: usize = 0;
        while (start < words.len) {
            var past = start + 1;
            while (past < words.len and words[past].speaker.? == words[start].speaker.?) past += 1;
            var text: std.ArrayList(u8) = .empty;
            for (words[start..past], 0..) |word, index| {
                if (index > 0) try text.append(out.arena, ' ');
                try text.appendSlice(out.arena, word.text);
            }
            try out.give(.{ .segment = .{
                .id = try items.ids.segment(out.arena),
                .item_id = try itemId(out.arena, items.item),
                .content_index = 0,
                .text = text.items,
                .speaker = try out.arena.print("{d}", .{words[start].speaker.?}),
                .start = words[start].start,
                .end = words[past - 1].end,
                .event_id = try items.ids.event(out.arena),
            } });
            start = past;
        }
    }

    /// That the provider heard speech begin at `seconds`, in the item under way.
    pub fn speechStarted(items: *HeardItems, out: *Out, seconds: f64) Allocator.Error!void {
        try out.give(.{ .speech_started = .{ .audio_start_ms = msOf(seconds), .item_id = try itemId(out.arena, items.item), .event_id = try items.ids.event(out.arena) } });
    }

    /// That the provider heard speech stop at `seconds`, ending the item under way.
    pub fn speechStopped(items: *HeardItems, out: *Out, seconds: f64) Allocator.Error!void {
        try out.give(.{ .speech_stopped = .{ .audio_end_ms = msOf(seconds), .item_id = try itemId(out.arena, items.item), .event_id = try items.ids.event(out.arena) } });
    }

    /// Ends the item under way, its transcript `transcript` where the provider gives the whole, else what it settled:
    /// it is committed and completed, with the seconds of the audio sent since the item before it; the next begins.
    pub fn end(items: *HeardItems, out: *Out, transcript: ?[]const u8) Allocator.Error!void {
        const id = try itemId(out.arena, items.item);
        const seconds = @as(f64, @floatFromInt(items.bytes_sent - items.bytes_counted)) / pcm_bytes_per_second;
        try out.give(.{ .committed = .{
            .item_id = id,
            .previous_item_id = if (items.previous) |previous| .{ .value = try itemId(out.arena, previous) } else .null,
            .event_id = try items.ids.event(out.arena),
        } });
        try out.give(.{ .completed = .{
            .item_id = id,
            .content_index = 0,
            .transcript = try out.arena.dupe(u8, transcript orelse items.settled.items),
            .usage = .{ .duration = .{ .seconds = seconds } },
            .event_id = try items.ids.event(out.arena),
        } });
        items.bytes_counted = items.bytes_sent;
        items.previous = items.item;
        items.item = items.ids.item();
        items.settled.clearRetainingCapacity();
        items.partial.clearRetainingCapacity();
    }
};

fn msOf(seconds: f64) u64 {
    return @intFromFloat(@round(@max(seconds, 0) * std.time.ms_per_s));
}

/// A setting a stream refuses, with why, for the caller to fail with or to answer an update with.
pub const Refusal = struct {
    message: ?[]const u8 = null,

    pub const Error = error{ OutOfMemory, Refused };

    pub fn refuse(refusal: *Refusal, arena: Allocator, comptime text: []const u8, arguments: anytype) Error {
        refusal.message = try arena.print(text, arguments);
        return error.Refused;
    }
};

/// Checks that `provider`, whose stream takes its settings as it connects, takes those of `session`: no prompt, delay,
/// noise reduction, logprobs, or turn detection by a VAD threshold or prefix padding, which Deepgram's and xAI's
/// streams have none of; `Refused` for the first it does not.
pub fn checkStreamSettings(arena: Allocator, refusal: *Refusal, provider: []const u8, session: *const realtime.Session) Refusal.Error!void {
    const input = &session.audio.input;
    const turn: ?realtime.TurnDetection = if (input.turn_detection) |given| given.given() else null;
    const noise = if (input.noise_reduction) |given| given.given() != null else false;
    const asked = [_]struct { []const u8, bool }{
        .{ "a prompt", input.transcription.prompt != null },
        .{ "a delay", input.transcription.delay != null },
        .{ "noise reduction", noise },
        .{ "logprobs", if (session.include) |include| include.len > 0 else false },
        .{ "a VAD threshold", turn != null and turn.?.threshold != null },
        .{ "a VAD prefix_padding_ms", turn != null and turn.?.prefix_padding_ms != null },
    };
    for (asked) |each| if (each[1]) return refusal.refuse(arena, "{s}'s realtime transcription takes no {s}", .{ provider, each[0] });
}

/// The session as its events give it: its settings, the model by reference.
pub fn sessionState(arena: Allocator, session: *const realtime.Session) Allocator.Error!foundation.json.Raw {
    return .{ .text = try foundation.json.encode(arena, session) };
}

/// The answer of a stream that takes its settings as it connects to a `session.update` of `session`: `session.updated`
/// where `asked` — the query `session` makes, or why it makes none — is the query it connected with, else an `error`, as
/// a setting cannot change once connected.
pub fn answerFixedUpdate(out: *Out, ids: *Ids, provider: []const u8, session: *const realtime.Session, asked: ?[]const u8, refusal: Refusal, connected: []const u8) Allocator.Error!void {
    const query = asked orelse return out.give(try session_.errorEvent(out.arena, ids, .invalid_request, "{s}", .{refusal.message.?}));
    if (!std.mem.eql(u8, query, connected)) {
        return out.give(try session_.errorEvent(out.arena, ids, .invalid_request, "{s}'s realtime transcription takes its settings as it connects: a session.update cannot change them", .{provider}));
    }
    try out.give(.{ .session_updated = .{ .session = try sessionState(out.arena, session), .event_id = try ids.event(out.arena) } });
}

/// The bytes of an append's audio, base64; null where it is none.
pub fn audioOf(arena: Allocator, audio: []const u8) Allocator.Error!?[]const u8 {
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(audio) catch return null;
    const bytes = try arena.alloc(u8, size);
    decoder.decode(bytes, audio) catch return null;
    return bytes;
}

test "an item counts its audio, settles its text after its partial text, and ends with its seconds" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var ids: Ids = .{};
    var items: HeardItems = .init(std.testing.allocator, &ids);
    defer items.deinit();
    var out: Out = .{ .arena = arena, .scratch_arena = arena };
    items.sent(9600);
    try items.heard(&out, "take met");
    try items.heard(&out, "take met");
    try items.settle(&out, "Take metformin daily.");
    try items.segments(&out, &.{ .{ .text = "Take", .start = 0.02, .end = 0.1, .speaker = 0 }, .{ .text = "metformin", .start = 0.1, .end = 0.2, .speaker = 0 }, .{ .text = "And?", .start = 0.21, .end = 0.3, .speaker = 1 } });
    try items.end(&out, null);
    const events = out.events.items;
    try std.testing.expectEqual(@as(usize, 6), events.len);
    try std.testing.expectEqualStrings("take met", events[0].partial.text);
    try std.testing.expectEqualStrings("Take metformin daily.", events[1].delta.delta.?);
    try std.testing.expectEqualStrings("Take metformin", events[2].segment.text);
    try std.testing.expectEqualStrings("1", events[3].segment.speaker);
    try std.testing.expectEqual(.null, std.meta.activeTag(events[4].committed.previous_item_id.?));
    try std.testing.expectEqualStrings("item_1", events[5].completed.item_id);
    try std.testing.expectEqual(@as(f64, 0.2), events[5].completed.usage.duration.seconds);
    try std.testing.expect(items.isEmpty());
}
