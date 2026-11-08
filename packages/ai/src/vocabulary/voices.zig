//! The voice calls: voices made for the account and the consents a provider asks for first, as OpenAI's voices and
//! voice consents APIs define them, each call naming its provider under `octoii`.
const transcriptions = @import("transcriptions.zig");
const ProviderPreferences = @import("provider.zig").ProviderPreferences;

/// A recording a voice call carries: base64 and its format, an address, or a stored file, as a transcription's.
pub const VoiceAudio = transcriptions.TranscriptionAudio;

/// The provider a voice call goes to.
pub const VoiceProvider = struct { provider: []const u8 };

/// A consent recorded for a voice: the person speaking the provider's consent phrase.
pub const VoiceConsentCreateParams = struct {
    /// A label for the consent.
    name: []const u8,
    /// The BCP 47 tag of the consent phrase, such as "en-US".
    language: []const u8,
    recording: VoiceAudio,
    octoii: VoiceProvider,
};

/// A voice to make for the account from a sample of it.
pub const VoiceCreateParams = struct {
    name: []const u8,
    audio_sample: VoiceAudio,
    /// The id of the consent its speaker recorded, where its provider asks for one.
    consent: ?[]const u8 = null,
    /// Its provider's own options alone; a provider refuses any other preference.
    provider: ?ProviderPreferences = null,
    octoii: VoiceProvider,
};

/// A voice made for the account, which a speech request names by its `id`.
pub const Voice = struct { id: []const u8, octoii: VoiceProvider };

/// A consent recorded for a voice, whose `id` a voice's `consent` names.
pub const VoiceConsent = struct { id: []const u8, octoii: VoiceProvider };
