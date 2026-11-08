//! Octoii's account of what a media or decision request used: its meters, read from the usage in its protocol's shape
//! as each kind says, or given by its provider as `octoii.usage`, and its cost, the provider's where it says, else the
//! model's prices at the time the request was sent.
const std = @import("std");
const vocabulary = @import("vocabulary");
const Usage = vocabulary.Usage;
const Model = @import("../catalogue/model.zig").Model;
const pricing = @import("../catalogue/pricing.zig");

/// `meters` with their cost: the one they carry, which their provider gave, else `provider_cost`, else the model's
/// prices that applied when the request was sent at `sent_at_ms`; none where none of these gives one.
pub fn priced(model: *const Model, meters: Usage, provider_cost: ?f64, sent_at_ms: i64) Usage {
    if (meters.cost != null) return meters;
    var made = meters;
    made.cost = provider_cost orelse pricing.cost(model, meters, .{ .sent_at_ms = sent_at_ms });
    return made;
}

/// The meters of an image request's usage: of the prompt tokens, the cached and written ones apart and the rest
/// `input`; of the completion tokens, the image tokens `output_image` and the rest `output`, its reasoning among it.
pub fn imageMeters(usage: ?vocabulary.images.ImageUsage) Usage {
    const given = usage orelse return .{};
    const cached = if (given.prompt_tokens_details) |details| details.cached_tokens orelse 0 else 0;
    const written = if (given.prompt_tokens_details) |details| details.cache_write_tokens orelse 0 else 0;
    const images = if (given.completion_tokens_details) |details| details.image_tokens orelse 0 else 0;
    const reasoning = if (given.completion_tokens_details) |details| details.reasoning_tokens orelse 0 else 0;
    return .{
        .input = counted(given.prompt_tokens -| cached -| written),
        .cache_read = counted(cached),
        .cache_write = counted(written),
        .output = counted(given.completion_tokens -| images),
        .output_image = counted(images),
        .reasoning = counted(reasoning),
    };
}

/// The meters of speech: the characters of the request's text and of every turn's, and of the usage its provider
/// reports, the text tokens read as `input` and the audio tokens made as `output_audio` where the model prices them
/// apart, else `output`.
pub fn speechMeters(model: *const Model, request: *const vocabulary.speech.SpeechRequest, usage: @FieldType(vocabulary.speech.SpeechAudioDoneEvent, "usage")) Usage {
    var characters: u64 = 0;
    switch (request.input) {
        .text => |text| characters += std.unicode.utf8CountCodepoints(text) catch text.len,
        .parts => |turns| for (turns) |turn| {
            characters += std.unicode.utf8CountCodepoints(turn.text) catch turn.text.len;
        },
    }
    var meters: Usage = .{ .characters = counted(characters) };
    if (usage) |given| {
        meters.input = counted(given.input_tokens);
        const audio_priced = if (model.pricing) |prices| prices.audio_output != null else false;
        if (audio_priced) meters.output_audio = counted(given.output_tokens) else meters.output = counted(given.output_tokens);
    }
    return meters;
}

/// The meters of a transcription: the seconds heard, and of the tokens its provider counts, the audio read as
/// `input_audio` where the model prices it apart, else `input`, and the text written as `output`.
pub fn transcriptionMeters(model: *const Model, usage: ?vocabulary.transcriptions.TranscriptionUsage) Usage {
    const given = usage orelse return .{};
    const audio_priced = if (model.pricing) |prices| prices.audio != null else false;
    const read = counted(given.input_tokens orelse 0);
    return .{
        .seconds = if (given.seconds) |seconds| (if (seconds > 0) seconds else null) else null,
        .input_audio = if (audio_priced) read else null,
        .input = if (audio_priced) null else read,
        .output = counted(given.output_tokens orelse 0),
    };
}

/// The meters of a realtime transcription's item: the seconds of its audio, or of its tokens the audio read as
/// `input_audio` where the model prices it apart, else `input`, the text read as `input`, and the text written as
/// `output`.
pub fn realtimeMeters(model: *const Model, given: vocabulary.realtime.TranscriptionUsage) Usage {
    switch (given) {
        .duration => |duration| return .{ .seconds = if (duration.seconds > 0) duration.seconds else null },
        .tokens => |tokens| {
            const audio_priced = if (model.pricing) |prices| prices.audio != null else false;
            const audio = if (tokens.input_token_details) |details| details.audio_tokens orelse 0 else tokens.input_tokens;
            const text = tokens.input_tokens -| audio;
            return .{
                .input_audio = if (audio_priced) counted(audio) else null,
                .input = counted(if (audio_priced) text else tokens.input_tokens),
                .output = counted(tokens.output_tokens),
            };
        },
    }
}

/// A meter where it counts something.
pub fn counted(amount: u64) ?u64 {
    return if (amount > 0) amount else null;
}
