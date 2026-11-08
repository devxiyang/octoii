//! The realtime transcription kind: the transcription sessions of OpenAI's Realtime API in Octoii's subset — the
//! session, the client's events and the server's — with Octoii's partial text and, under `octoii`, a failure's kind and
//! Octoii's account of an item's usage. Where the protocol gives a member as `null`, it says so: a turn detection of
//! `null` turns it off, where its absence leaves it to the provider.
const foundation = @import("foundation");
const Raw = foundation.json.Raw;
const Nullable = foundation.json.Nullable;
const KeepingNulls = foundation.json.KeepingNulls;
const Variants = foundation.json.Variants;
const extensions = @import("extensions.zig");
const MediaUsageExtension = @import("media.zig").MediaUsageExtension;

/// How the provider hears the end of speech: its voice activity detection, by volume.
pub const TurnDetection = struct {
    type: enum { server_vad } = .server_vad,
    threshold: ?f64 = null,
    prefix_padding_ms: ?u32 = null,
    silence_duration_ms: ?u32 = null,
};

/// How far a model may wait for what follows before it settles text.
pub const Delay = enum { minimal, low, medium, high, xhigh };

/// What a session transcribes with: the model by reference, and what guides it.
pub const TranscriptionSettings = struct {
    /// The model's reference.
    model: []const u8,
    prompt: ?[]const u8 = null,
    language: ?[]const u8 = null,
    languages: ?[]const []const u8 = null,
    keywords: ?[]const []const u8 = null,
    delay: ?Delay = null,
};

/// The session's audio as the client sends it, and what is made of it.
pub const AudioInput = struct {
    /// Raw mono PCM16 at 24 kHz, the one format of the subset.
    format: ?struct { type: enum { @"audio/pcm" } = .@"audio/pcm", rate: ?u32 = null } = null,
    transcription: TranscriptionSettings,
    /// Left out, the provider's own; `null`, items end only when the client commits.
    turn_detection: ?Nullable(TurnDetection) = null,
    noise_reduction: ?Nullable(struct { type: ?enum { near_field, far_field } = null }) = null,

    pub const jsonParse = KeepingNulls(@This()).jsonParse;
    pub const jsonParseFromValue = KeepingNulls(@This()).jsonParseFromValue;
};

/// The one rate of the subset's audio, in Hz.
pub const pcm_rate_hz = 24_000;

/// A realtime transcription session's settings: its audio's format, its transcription, turn detection and noise
/// reduction.
pub const Session = struct {
    type: enum { transcription } = .transcription,
    audio: struct { input: AudioInput },
    include: ?[]const enum { @"item.input_audio_transcription.logprobs" } = null,
    provider: ?struct { options: ?Raw = null } = null,

    /// The settings' model, by reference.
    pub fn model(session: *const Session) []const u8 {
        return session.audio.input.transcription.model;
    }

    /// The languages it names: its `languages`, else its one `language`, else none.
    pub fn languages(session: *const Session) []const []const u8 {
        const transcription = &session.audio.input.transcription;
        if (transcription.languages) |given| return given;
        if (transcription.language) |*one| return one[0..1];
        return &.{};
    }
};

/// What connects the host to a session a client made by WebRTC, as its sideband.
pub const SidebandParams = struct {
    /// The model's reference.
    model: []const u8,
    call_id: []const u8,
};

/// A session for a client that connects by WebRTC: its settings and the client's offer.
pub const CallCreateParams = struct { session: Session, sdp: []const u8 };

/// A session made for a client: its call's id, and the answer the host gives the client.
pub const CallCreateResponse = struct { call_id: []const u8, sdp: []const u8 };

/// Changes the session's settings.
pub const SessionUpdate = struct {
    type: enum { @"session.update" } = .@"session.update",
    session: Session,
    event_id: ?[]const u8 = null,
};

/// Adds audio to the buffer: raw mono PCM16 at 24 kHz, base64.
pub const Append = struct {
    type: enum { @"input_audio_buffer.append" } = .@"input_audio_buffer.append",
    audio: []const u8,
    event_id: ?[]const u8 = null,
};

/// Ends the item the buffer's audio makes.
pub const Commit = struct {
    type: enum { @"input_audio_buffer.commit" } = .@"input_audio_buffer.commit",
    event_id: ?[]const u8 = null,
};

/// Drops the audio not yet committed.
pub const Clear = struct {
    type: enum { @"input_audio_buffer.clear" } = .@"input_audio_buffer.clear",
    event_id: ?[]const u8 = null,
};

/// What the client sends a realtime session.
pub const ClientEvent = union(enum) {
    session_update: SessionUpdate,
    append: Append,
    commit: Commit,
    clear: Clear,

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// A failure a session's provider reports, its kind under `octoii`.
pub const RealtimeError = struct {
    type: []const u8,
    code: ?Nullable([]const u8) = null,
    message: []const u8,
    param: ?Nullable([]const u8) = null,
    /// The client event that caused it.
    event_id: ?Nullable([]const u8) = null,
    octoii: extensions.FailureExtension,

    pub const jsonParse = KeepingNulls(@This()).jsonParse;
    pub const jsonParseFromValue = KeepingNulls(@This()).jsonParseFromValue;
};

/// What an item's transcription used: tokens, or the seconds of its audio.
pub const TranscriptionUsage = union(enum) {
    tokens: struct {
        type: enum { tokens } = .tokens,
        input_tokens: u64,
        output_tokens: u64,
        total_tokens: u64,
        input_token_details: ?struct { audio_tokens: ?u64 = null, text_tokens: ?u64 = null } = null,
    },
    duration: struct { type: enum { duration } = .duration, seconds: f64 },

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// The log probabilities of a transcription's tokens, where `include` asks for them.
const Logprobs = ?Nullable([]const Raw);

/// The session as it opened: its settings, the model by reference, with what the provider adds, such as its id.
pub const SessionCreated = struct {
    type: enum { @"session.created" } = .@"session.created",
    session: Raw,
    event_id: []const u8,
};

/// The session as a `session.update` changed it.
pub const SessionUpdated = struct {
    type: enum { @"session.updated" } = .@"session.updated",
    session: Raw,
    event_id: []const u8,
};

/// The buffer was committed: the item its audio makes.
pub const Committed = struct {
    type: enum { @"input_audio_buffer.committed" } = .@"input_audio_buffer.committed",
    item_id: []const u8,
    previous_item_id: ?Nullable([]const u8) = null,
    event_id: []const u8,

    pub const jsonParse = KeepingNulls(@This()).jsonParse;
    pub const jsonParseFromValue = KeepingNulls(@This()).jsonParseFromValue;
};

/// The audio not yet committed was dropped.
pub const Cleared = struct {
    type: enum { @"input_audio_buffer.cleared" } = .@"input_audio_buffer.cleared",
    event_id: []const u8,
};

/// The provider heard speech begin, in ms of the session's audio.
pub const SpeechStarted = struct {
    type: enum { @"input_audio_buffer.speech_started" } = .@"input_audio_buffer.speech_started",
    audio_start_ms: u64,
    item_id: []const u8,
    event_id: []const u8,
};

/// The provider heard speech stop, in ms of the session's audio.
pub const SpeechStopped = struct {
    type: enum { @"input_audio_buffer.speech_stopped" } = .@"input_audio_buffer.speech_stopped",
    audio_end_ms: u64,
    item_id: []const u8,
    event_id: []const u8,
};

/// Text of an item's transcript, settled, as it comes.
pub const TranscriptionDelta = struct {
    type: enum { @"conversation.item.input_audio_transcription.delta" } = .@"conversation.item.input_audio_transcription.delta",
    item_id: []const u8,
    content_index: ?u32 = null,
    delta: ?[]const u8 = null,
    logprobs: Logprobs = null,
    event_id: []const u8,

    pub const jsonParse = KeepingNulls(@This()).jsonParse;
    pub const jsonParseFromValue = KeepingNulls(@This()).jsonParseFromValue;
};

/// A stretch of an item's transcript and its speaker, from a model that tells speakers apart.
pub const TranscriptionSegment = struct {
    type: enum { @"conversation.item.input_audio_transcription.segment" } = .@"conversation.item.input_audio_transcription.segment",
    id: []const u8,
    item_id: []const u8,
    content_index: u32,
    text: []const u8,
    speaker: []const u8,
    /// Seconds.
    start: f64,
    end: f64,
    event_id: []const u8,
};

/// An item's whole transcript and what it used, with Octoii's account under `octoii`.
pub const TranscriptionCompleted = struct {
    type: enum { @"conversation.item.input_audio_transcription.completed" } = .@"conversation.item.input_audio_transcription.completed",
    item_id: []const u8,
    content_index: u32,
    transcript: []const u8,
    usage: TranscriptionUsage,
    /// The languages heard, by code, where the model detects them.
    languages: ?[]const struct { code: []const u8 } = null,
    logprobs: Logprobs = null,
    octoii: ?MediaUsageExtension = null,
    event_id: []const u8,

    pub const jsonParse = KeepingNulls(@This()).jsonParse;
    pub const jsonParseFromValue = KeepingNulls(@This()).jsonParseFromValue;
};

/// Why an item's transcription failed, its kind under `octoii`.
pub const ItemError = struct {
    code: ?Nullable([]const u8) = null,
    message: ?Nullable([]const u8) = null,
    param: ?Nullable([]const u8) = null,
    type: ?Nullable([]const u8) = null,
    octoii: extensions.FailureExtension,

    pub const jsonParse = KeepingNulls(@This()).jsonParse;
    pub const jsonParseFromValue = KeepingNulls(@This()).jsonParseFromValue;
};

/// An item's transcription failed.
pub const TranscriptionFailed = struct {
    type: enum { @"conversation.item.input_audio_transcription.failed" } = .@"conversation.item.input_audio_transcription.failed",
    item_id: []const u8,
    content_index: u32,
    @"error": ItemError,
    event_id: []const u8,
};

/// What was heard after an item's settled text and is not yet settled; each replaces the one before it for its item.
pub const TranscriptionPartial = struct {
    type: enum { @"octoii:conversation.item.input_audio_transcription.partial" } = .@"octoii:conversation.item.input_audio_transcription.partial",
    item_id: []const u8,
    content_index: u32,
    text: []const u8,
    event_id: []const u8,
};

/// A failure the session goes on after, or the last before a provider ends it.
pub const ErrorEvent = struct {
    type: enum { @"error" } = .@"error",
    @"error": RealtimeError,
    event_id: []const u8,
};

/// What a realtime session's provider sends the client.
pub const ServerEvent = union(enum) {
    session_created: SessionCreated,
    session_updated: SessionUpdated,
    committed: Committed,
    cleared: Cleared,
    speech_started: SpeechStarted,
    speech_stopped: SpeechStopped,
    delta: TranscriptionDelta,
    segment: TranscriptionSegment,
    completed: TranscriptionCompleted,
    failed: TranscriptionFailed,
    partial: TranscriptionPartial,
    @"error": ErrorEvent,

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;

    /// The item it is of, where it is of one.
    pub fn itemId(event: ServerEvent) ?[]const u8 {
        return switch (event) {
            inline .committed, .speech_started, .speech_stopped, .delta, .segment, .completed, .failed, .partial => |of| of.item_id,
            else => null,
        };
    }
};
