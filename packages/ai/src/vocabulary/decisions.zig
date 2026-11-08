//! The decision kind: OpenRouter's Decisions API, its request of typed questions about a state and its answers with
//! probabilities, with Octoii's account of the usage under `octoii`.
const std = @import("std");
const foundation = @import("foundation");
const Raw = foundation.json.Raw;
const Variants = foundation.json.Variants;
const media = @import("media.zig");
const ProviderPreferences = @import("provider.zig").ProviderPreferences;

/// Text, or JSON whose fields the text names, an object or an array; it may hold images, audio and video as items.
pub const DecisionsText = std.json.Value;

/// A question about the state, of one of four types.
pub const DecisionsQuestion = union(enum) {
    /// Whether it holds.
    noul: struct { type: enum { noul } = .noul, instructions: DecisionsText, criteria: ?struct { true: DecisionsText, false: DecisionsText } = null },
    /// Which option; an option's criteria null where its name says enough.
    choice: struct { type: enum { choice } = .choice, instructions: DecisionsText, criteria: std.json.ArrayHashMap(DecisionsText) },
    /// Where among ordered levels.
    score: struct { type: enum { score } = .score, instructions: DecisionsText, criteria: []const DecisionsText },
    /// Where in an image.
    box: struct { type: enum { box } = .box, instructions: DecisionsText },

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// A request of typed questions about a state.
pub const DecisionsRequest = struct {
    /// The model's reference.
    model: []const u8,
    /// What the questions are about.
    state: DecisionsText,
    questions: std.json.ArrayHashMap(DecisionsQuestion),
    provider: ?ProviderPreferences = null,
    session_id: ?[]const u8 = null,
    trace: ?Raw = null,
    user: ?[]const u8 = null,
};

/// An answer, of its question's type, with its probabilities.
pub const DecisionsAnswer = union(enum) {
    /// The probability that it holds.
    noul: struct { type: enum { noul } = .noul, noul: f64 },
    choice: struct { type: enum { choice } = .choice, choice: []const u8, probabilities: ?std.json.ArrayHashMap(f64) = null, confidence: ?f64 = null },
    score: struct {
        type: enum { score } = .score,
        /// The probability-weighted level, from 0.
        score: f64,
        probabilities: ?std.json.ArrayHashMap(f64) = null,
        confidence: ?f64 = null,
        /// The criteria by level.
        legend: ?std.json.ArrayHashMap(DecisionsText) = null,
    },
    box: struct {
        type: enum { box } = .box,
        /// Fractions of the image from its top-left corner.
        box: struct { top: f64, bottom: f64, left: f64, right: f64 },
        confidence: ?f64 = null,
    },

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// The answers to a request's questions, by question, and what answering them used.
pub const DecisionsResponse = struct {
    id: ?[]const u8 = null,
    answers: std.json.ArrayHashMap(DecisionsAnswer),
    /// The provider's id of the model that answered, such as a version of an alias.
    model: []const u8,
    /// Who served it, where OpenRouter chose.
    provider: ?[]const u8 = null,
    usage: struct { input_tokens: u64, output_tokens: u64, cost: ?f64 = null },
    octoii: ?media.MediaUsageExtension = null,
};
