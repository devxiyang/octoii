//! The transcription kind: OpenRouter's transcription API, its request and its response, and the events of OpenAI's
//! transcription stream, whose last carries the rest of the response and Octoii's account of the usage under `octoii`.
const foundation = @import("foundation");
const Raw = foundation.json.Raw;
const Variants = foundation.json.Variants;
const media = @import("media.zig");
const extensions = @import("extensions.zig");
const FileExtension = extensions.FileExtension;
const Usage = @import("usage.zig").Usage;

/// The recording a transcription request carries: base64, an address its provider fetches, or a stored file.
pub const TranscriptionAudio = union(enum) {
    /// Base64, not a data URL.
    inline_data: struct { data: []const u8, format: []const u8, octoii: ?FileExtension = null },
    addressed: struct { url: []const u8, format: ?[]const u8 = null, octoii: ?FileExtension = null },
    stored: Stored,

    pub const Stored = struct {
        format: ?[]const u8 = null,
        octoii: FileExtension,

        pub fn valid(stored: Stored) bool {
            return stored.octoii.ref != null;
        }
    };

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

pub const TimestampGranularity = enum { segment, word };

/// A request to transcribe a recording.
pub const TranscriptionRequest = struct {
    /// The model's reference.
    model: []const u8,
    input_audio: TranscriptionAudio,
    /// ISO-639-1, such as "en"; detected when left out.
    language: ?[]const u8 = null,
    temperature: ?f64 = null,
    response_format: ?enum { json, verbose_json } = null,
    /// With `verbose_json`.
    timestamp_granularities: ?[]const TimestampGranularity = null,
    /// Each word's speaker, with `verbose_json`.
    diarize: ?bool = null,
    /// Terms, names or phrases to listen for.
    keyterms: ?[]const []const u8 = null,
    session_id: ?[]const u8 = null,
    trace: ?Raw = null,
    user: ?[]const u8 = null,
    provider: ?media.DataPolicy = null,
};

/// A stretch of a transcript with its times, in seconds.
pub const TranscriptionSegment = struct {
    id: f64,
    start: f64,
    end: f64,
    text: []const u8,
    speaker: ?f64 = null,
    speaker_label: ?[]const u8 = null,
    channel: ?f64 = null,
    avg_logprob: ?f64 = null,
    compression_ratio: ?f64 = null,
    no_speech_prob: ?f64 = null,
    seek: ?f64 = null,
    temperature: ?f64 = null,
    tokens: ?[]const f64 = null,
};

/// A word of a transcript, or the tag of a sound such as "(laughter)", with its times, in seconds.
pub const TranscriptionWord = struct {
    word: []const u8,
    type: ?enum { word, audio_event } = null,
    start: f64,
    end: f64,
    speaker: ?f64 = null,
    speaker_label: ?[]const u8 = null,
    confidence: ?f64 = null,
    channel: ?f64 = null,
};

/// What a transcription used, as the transcription API reports it.
pub const TranscriptionUsage = struct {
    seconds: ?f64 = null,
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    total_tokens: ?u64 = null,
    cost: ?f64 = null,
};

/// A transcription's language, duration, segments, words and entities: all of it but its text and usage.
pub const TranscriptionDetails = struct {
    task: ?[]const u8 = null,
    language: ?[]const u8 = null,
    language_confidence: ?f64 = null,
    /// Seconds.
    duration: ?f64 = null,
    confidence: ?f64 = null,
    segments: ?[]const TranscriptionSegment = null,
    words: ?[]const TranscriptionWord = null,
    entities: ?[]const struct { text: []const u8, type: []const u8, start_char: u64, end_char: u64 } = null,
};

/// What was said in a recording, and what transcribing it used.
pub const TranscriptionResponse = struct {
    text: []const u8,
    task: ?[]const u8 = null,
    language: ?[]const u8 = null,
    language_confidence: ?f64 = null,
    duration: ?f64 = null,
    confidence: ?f64 = null,
    segments: ?[]const TranscriptionSegment = null,
    words: ?[]const TranscriptionWord = null,
    entities: @FieldType(TranscriptionDetails, "entities") = null,
    usage: ?TranscriptionUsage = null,
    octoii: ?media.MediaUsageExtension = null,
};

/// Text of the transcript, settled, as it comes.
pub const TranscriptTextDeltaEvent = struct {
    type: enum { @"transcript.text.delta" } = .@"transcript.text.delta",
    delta: []const u8,
    logprobs: ?[]const Raw = null,
    segment_id: ?[]const u8 = null,
};

/// A stretch of the transcript and its speaker, from a model that tells speakers apart.
pub const TranscriptTextSegmentEvent = struct {
    type: enum { @"transcript.text.segment" } = .@"transcript.text.segment",
    id: []const u8,
    start: f64,
    end: f64,
    text: []const u8,
    speaker: []const u8,
};

/// The whole transcript, its usage as the response gives it, and under `octoii` Octoii's account and the rest of the
/// response.
pub const TranscriptTextDoneEvent = struct {
    type: enum { @"transcript.text.done" } = .@"transcript.text.done",
    text: []const u8,
    logprobs: ?[]const Raw = null,
    usage: ?TranscriptionUsage = null,
    octoii: ?struct {
        usage: ?Usage = null,
        transcription: ?TranscriptionDetails = null,
    } = null,
};

/// An event of a transcription stream: text, segments, the whole transcript, or the failure that ends it.
pub const TranscriptionStreamEvent = union(enum) {
    delta: TranscriptTextDeltaEvent,
    segment: TranscriptTextSegmentEvent,
    done: TranscriptTextDoneEvent,
    @"error": media.MediaErrorEvent,

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};
