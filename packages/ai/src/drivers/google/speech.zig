//! Google's speech kind: the Interactions API, asked for audio. The text, or each turn's, is a text input whose
//! `speech_metadata` gives its style, from its instructions, and its speaker where the turns speak in two voices,
//! which Google names in its speech config. Its audio comes as it is made, PCM by default, and its usage in tokens.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vocabulary = @import("vocabulary");
const speech = vocabulary.speech;
const Event = speech.SpeechStreamEvent;
const seam = @import("../../driver.zig");
const Call = seam.Call;
const Error = @import("../../failure.zig").Error;
const Model = @import("../../catalogue/model.zig").Model;
const json = @import("../../wire/json.zig");
const interactions = @import("interactions.zig");

/// The voices one request of Google's speaks in at most.
const speakers_max = 2;

/// The rate of Google's PCM where its deltas name none.
const pcm_rate_hz = 24_000;

/// A text input with its speech metadata.
const Text = struct {
    type: enum { text } = .text,
    text: []const u8,
    annotations: ?[]const Annotation = null,

    const Annotation = struct { type: enum { speech_metadata } = .speech_metadata, speaker: ?[]const u8 = null, style: ?[]const u8 = null };
};

const Speaker = struct { speaker: []const u8, voice: []const u8 };

/// Google's speech config: one voice, or two speakers.
const SpeechConfig = union(enum) {
    voices: []const struct { voice: []const u8 },
    speakers: struct { speakers: []const Speaker },

    pub fn jsonStringify(config: SpeechConfig, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (config) {
            inline else => |payload| try writer.write(payload),
        }
    }
};

const UserInput = struct { type: enum { user_input } = .user_input, content: []const Text };

const Interaction = struct {
    model: []const u8,
    input: []const UserInput,
    response_format: struct { type: enum { audio } = .audio, mime_type: []const u8 },
    generation_config: ?struct { speech_config: SpeechConfig } = null,
};

/// What ai asks Google for by each of the vocabulary's formats: headerless PCM, or MP3.
fn googleFormat(format: @FieldType(speech.SpeechRequest, "response_format")) []const u8 {
    return if (format == .mp3) "audio/mp3" else "audio/l16";
}

/// The interaction a speech request asks Google for: each turn a text input with its style and speaker, its one voice
/// or two speakers as its speech config, and audio of the format asked; `invalid_request` for what Google does not take.
pub fn wireRequest(call: *Call, model: *const Model, request: speech.SpeechRequest) Error![]const u8 {
    try checkRequest(call, model, request);
    const arena = call.arena;
    const turns: []const speech.SpeechTurn = switch (request.input) {
        .text => |text| try arena.dupe(speech.SpeechTurn, &.{.{ .text = text }}),
        .parts => |given| given,
    };
    var voices: std.ArrayList([]const u8) = .empty;
    for (turns) |turn| if (voiceOf(turn, request)) |voice| {
        for (voices.items) |each| {
            if (std.mem.eql(u8, each, voice)) break;
        } else try voices.append(arena, voice);
    };
    if (voices.items.len > speakers_max) {
        return call.failWith(.invalid_request, "The model {s} speaks in at most {d} voices a request, and the turns ask for {d}", .{ try model.reference(arena), speakers_max, voices.items.len });
    }
    const speakers = voices.items.len == speakers_max;
    const content = try arena.alloc(Text, turns.len);
    for (turns, content) |turn, *each| {
        const voice = voiceOf(turn, request);
        if (speakers and voice == null) return call.failWith(.invalid_request, "Each turn names its voice where the turns speak in two voices", .{});
        const speaker: ?[]const u8 = if (speakers) try speakerName(arena, indexOf(voices.items, voice.?)) else null;
        const style = turn.instructions orelse request.instructions;
        each.* = .{ .text = turn.text };
        if (speaker != null or style != null) each.annotations = try arena.dupe(Text.Annotation, &.{.{ .speaker = speaker, .style = style }});
    }
    const config: ?SpeechConfig = if (voices.items.len == 0) null else if (speakers) speakers: {
        const named = try arena.alloc(Speaker, voices.items.len);
        for (voices.items, named, 0..) |voice, *each, index| each.* = .{ .speaker = try speakerName(arena, index), .voice = voice };
        break :speakers .{ .speakers = .{ .speakers = named } };
    } else voices: {
        const one = try arena.alloc(@typeInfo(@FieldType(SpeechConfig, "voices")).pointer.child, voices.items.len);
        for (voices.items, one) |voice, *each| each.* = .{ .voice = voice };
        break :voices .{ .voices = one };
    };
    const own = try json.ownOptionsAlone(call, request.provider, "google", "The model cannot take {s}: Google does not offer it");
    return interactions.requestBody(arena, Interaction{
        .model = model.id,
        .input = try arena.dupe(UserInput, &.{.{ .content = content }}),
        .response_format = .{ .mime_type = googleFormat(request.response_format) },
        .generation_config = if (config) |given| .{ .speech_config = given } else null,
    }, own);
}

fn checkRequest(call: *Call, model: *const Model, request: speech.SpeechRequest) Error!void {
    const reference = try model.reference(call.arena);
    if (request.speed != null) return call.failWith(.invalid_request, "The model {s} cannot take speed: Google does not offer it", .{reference});
    if (request.input_references) |given| if (given.len > 0) {
        return call.failWith(.invalid_request, "The model {s} cannot take input_references: Google's voices are made apart, and named by their id: Google does not offer it", .{reference});
    };
    if (request.provider) |policy| if (policy.zdr != null or policy.data_collection != null) {
        return call.failWith(.invalid_request, "The model {s} cannot take a data policy: Google does not offer it", .{reference});
    };
}

/// A turn's voice as Google names it: one of the model's own by its name, one made for the account by its id.
fn voiceOf(turn: speech.SpeechTurn, request: speech.SpeechRequest) ?[]const u8 {
    const voice = turn.voice orelse request.voice orelse return null;
    return switch (voice) {
        .name => |name| name,
        .made => |made| made.id,
    };
}

fn indexOf(voices: []const []const u8, voice: []const u8) usize {
    for (voices, 0..) |each, index| if (std.mem.eql(u8, each, voice)) return index;
    unreachable;
}

/// The name of the speaker at `index` among the voices, as the turns and the speech config name them.
fn speakerName(arena: Allocator, index: usize) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "Speaker {d}", .{index + 1});
}

pub fn speak(call: *Call, model: *const Model, request: *const speech.SpeechRequest) Error!seam.SpeechSource {
    const made = try call.arena.create(Source);
    made.* = .{ .call = call, .reader = try .open(call, try wireRequest(call, model, request.*)), .asked = googleFormat(request.response_format) };
    return .{ .context = made, .vtable = &.{ .next = Source.next, .close = Source.close } };
}

/// The audio of a request as Google makes it, then its end with its usage.
const Source = struct {
    call: *Call,
    reader: interactions.MadeReader,
    asked: []const u8,

    fn next(context: *anyopaque) Error!?Event {
        const source: *Source = @ptrCast(@alignCast(context));
        while (try source.reader.next()) |event| switch (event) {
            .created => {},
            .made => |made| {
                if (!std.mem.eql(u8, made.content.type, "audio")) continue;
                const data = made.content.data orelse continue;
                return .{ .delta = .{ .audio = data, .octoii = .{ .media_type = try audioMediaType(source.call.arena, made.content, source.asked) } } };
            },
            .completed => |usage| return .{ .done = .{ .usage = if (usage) |given| speechUsage(given) else null } },
        };
        return null;
    }

    fn close(context: *anyopaque) void {
        const source: *Source = @ptrCast(@alignCast(context));
        source.reader.close();
    }
};

/// What a delta's audio is: as it says, else as asked, Google's PCM as the vocabulary's at the rate it names, and its
/// MP3 by the name the vocabulary gives it.
fn audioMediaType(arena: Allocator, content: interactions.Content, asked: []const u8) Allocator.Error![]const u8 {
    const media_type = content.mime_type orelse asked;
    if (std.mem.eql(u8, media_type, "audio/l16")) return std.fmt.allocPrint(arena, "audio/pcm;rate={d}", .{content.sample_rate orelse pcm_rate_hz});
    if (std.mem.eql(u8, media_type, "audio/mp3")) return "audio/mpeg";
    return media_type;
}

/// An interaction's usage as the speech stream's: the text's tokens read and the audio's made.
fn speechUsage(usage: interactions.Usage) @typeInfo(@FieldType(speech.SpeechAudioDoneEvent, "usage")).optional.child {
    const input = usage.total_input_tokens orelse 0;
    const output = usage.total_output_tokens orelse 0;
    return .{ .input_tokens = input, .output_tokens = output, .total_tokens = usage.total_tokens orelse input + output };
}
