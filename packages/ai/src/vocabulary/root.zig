//! The model protocol: every request, item, content part, tool, event and response as a Zig type, decoded with checks
//! and encoded canonically through foundation's JSON. It is the Responses vocabulary for text as OpenRouter defines
//! it, with Octoii's extensions under an `octoii` key that never reach a provider; names keep their snake case.
//!
//! - A union is told apart by its variant's `type`, or by the kind of its JSON; an item or content part of a type the
//!   vocabulary does not know is refused, and so is a file given without a source.
//! - A field left out and a field given as `null` are one: neither is written; but a `Nullable` member, whose `null`
//!   says something its absence does not, keeps it. A message's `type`, which the protocol lets a message leave out, is
//!   written where it was given.
//! - What is the provider's or the caller's to shape — a JSON Schema, metadata, a provider's own data — is kept as
//!   `Raw` JSON, carried and written back as it came.
/// The vocabulary's version: what stores or sends its items — a thread's log, a model request handed to a host — names
/// it, so that a reader knows the shape it reads. It changes only with a change its readers must know of.
pub const version = 1;

pub const content = @import("content.zig");
pub const tools = @import("tools.zig");
pub const items = @import("items.zig");
pub const request = @import("request.zig");
pub const response = @import("response.zig");
pub const events = @import("events.zig");
pub const extensions = @import("extensions.zig");
pub const plugins = @import("plugins.zig");
pub const provider = @import("provider.zig");
pub const estimate = @import("estimate.zig");
pub const media = @import("media.zig");
pub const images = @import("images.zig");
pub const speech = @import("speech.zig");
pub const transcriptions = @import("transcriptions.zig");
pub const videos = @import("videos.zig");
pub const decisions = @import("decisions.zig");
pub const voices = @import("voices.zig");
pub const realtime = @import("realtime.zig");

pub const TextOr = content.TextOr;
pub const InputContent = content.InputContent;
pub const OutputContent = content.OutputContent;
pub const Tool = tools.Tool;
pub const ToolChoice = tools.ToolChoice;
pub const Item = items.Item;
pub const OutputItem = items.OutputItem;
pub const ResponsesRequest = request.ResponsesRequest;
pub const Response = response.Response;
pub const ResponseStreamEvent = events.ResponseStreamEvent;
pub const FailureKind = extensions.FailureKind;
pub const Usage = @import("usage.zig").Usage;

test {
    _ = content;
    _ = tools;
    _ = items;
    _ = request;
    _ = response;
    _ = events;
    _ = extensions;
    _ = plugins;
    _ = provider;
    _ = estimate;
    _ = media;
    _ = images;
    _ = speech;
    _ = transcriptions;
    _ = videos;
    _ = decisions;
    _ = voices;
    _ = realtime;
    _ = @import("usage.zig");
    _ = @import("tests.zig");
}
