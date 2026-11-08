//! The speech kind: OpenRouter's speech API, which is OpenAI's, its request, and the events of OpenAI's speech
//! stream, with what each delta is and Octoii's account of the usage under `octoii`. The response, to which the
//! protocol gives no shape of its own, is Octoii's.
const foundation = @import("foundation");
const Raw = foundation.json.Raw;
const Variants = foundation.json.Variants;
const media = @import("media.zig");
const content = @import("content.zig");
const Usage = @import("usage.zig").Usage;

/// A voice a speech model speaks in: one of the model's `supported_voices`, or a voice made for the account.
pub const SpeechVoice = union(enum) {
    name: []const u8,
    made: struct { id: []const u8 },

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// One speaker's turn of a conversation spoken in one request.
pub const SpeechTurn = struct {
    text: []const u8,
    voice: ?SpeechVoice = null,
    instructions: ?[]const u8 = null,
};

/// A sample a model clones a voice from, the transcript of the sample beside it, or an image it designs a voice from.
pub const SpeechInputReference = union(enum) {
    audio: media.AudioInput,
    text: struct { type: enum { text } = .text, text: []const u8 },
    image: media.ImageReference,

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// A request to speak text.
pub const SpeechRequest = struct {
    /// The model's reference.
    model: []const u8,
    /// Text, or turns of several speakers.
    input: content.TextOr(SpeechTurn),
    /// The model's default when left out, where it has one.
    voice: ?SpeechVoice = null,
    /// How it is spoken, such as "warm and unhurried", for a model whose `octoii.instructions` is true.
    instructions: ?[]const u8 = null,
    response_format: ?enum { mp3, pcm } = null,
    speed: ?f64 = null,
    input_references: ?[]const SpeechInputReference = null,
    session_id: ?[]const u8 = null,
    trace: ?Raw = null,
    user: ?[]const u8 = null,
    provider: ?media.DataPolicy = null,
};

/// Text spoken: the audio, base64, what it is, and Octoii's account of the usage.
pub const SpeechResponse = struct {
    media_type: []const u8,
    data: []const u8,
    usage: ?Usage = null,
};

/// Audio as it is made, base64, naming what it is.
pub const SpeechAudioDeltaEvent = struct {
    type: enum { @"speech.audio.delta" } = .@"speech.audio.delta",
    audio: []const u8,
    /// What the audio is, such as `audio/mpeg` or `audio/pcm;rate=24000`.
    octoii: struct { media_type: []const u8 },
};

/// The end of the audio, with the usage where its provider reports one, and Octoii's account of it.
pub const SpeechAudioDoneEvent = struct {
    type: enum { @"speech.audio.done" } = .@"speech.audio.done",
    usage: ?struct { input_tokens: u64, output_tokens: u64, total_tokens: u64 } = null,
    octoii: ?media.MediaUsageExtension = null,
};

/// An event of a speech stream: audio, its end, or the failure that ends it.
pub const SpeechStreamEvent = union(enum) {
    delta: SpeechAudioDeltaEvent,
    done: SpeechAudioDoneEvent,
    @"error": media.MediaErrorEvent,

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};
