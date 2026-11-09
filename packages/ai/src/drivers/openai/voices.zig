//! OpenAI's voices for the account: its voice consents API, at `/audio/voice_consents`, records the consent its voices
//! API asks for, and its voices API makes a voice at `/audio/voices` from a sample and that consent and removes one at
//! `/audio/voices/{id}`. Each takes its recording as a file of multipart form data.
const std = @import("std");
const foundation = @import("foundation");
const multipart = foundation.multipart;
const vocabulary = @import("vocabulary");
const voices = vocabulary.voices;
const seam = @import("../../driver.zig");
const Call = seam.Call;
const Error = @import("../../failure.zig").Error;
const media = @import("media.zig");
const transcriptions = @import("transcriptions.zig");

pub const calls: seam.VoiceCalls = .{ .create = create, .delete = delete, .create_consent = createConsent };

fn create(call: *Call, params: *const voices.VoiceCreateParams) Error![]const u8 {
    const own = try media.options(call, params.provider, "voices API");
    var fields: std.ArrayList(multipart.Field) = .empty;
    try fields.append(call.arena, .{ .name = "name", .value = params.name });
    if (params.consent) |consent| try fields.append(call.arena, .{ .name = "consent", .value = consent });
    if (own) |options| try transcriptions.appendOptions(call.arena, &fields, options);
    try fields.append(call.arena, try transcriptions.recordingPart(call, "audio_sample", params.audio_sample));
    return (try sent(call, "/audio/voices", fields.items, "voice")).id;
}

fn delete(call: *Call, id: []const u8) Error!void {
    const path = try call.arena.print("/audio/voices/{f}", .{std.fmt.alt(std.Uri.Component{ .raw = id }, .formatEscaped)});
    const response = try media.send(call, .{ .method = .DELETE, .path = path, .accept = "application/json" });
    const removed = try media.jsonBody(struct { id: []const u8, deleted: bool }, call, response, "voice removed");
    if (!removed.deleted) return call.failWith(.invalid_response, "OpenAI answered that it did not remove the voice {s}", .{id});
}

fn createConsent(call: *Call, params: *const voices.VoiceConsentCreateParams) Error![]const u8 {
    const fields = [_]multipart.Field{ .{ .name = "name", .value = params.name }, .{ .name = "language", .value = params.language }, try transcriptions.recordingPart(call, "recording", params.recording) };
    return (try sent(call, "/audio/voice_consents", &fields, "voice consent")).id;
}

/// Sends `fields` as a form to `path`; what OpenAI made, by its id.
/// What OpenAI answers with a voice made or a consent recorded: its id, beside what ai does not keep.
const Made = struct { id: []const u8 };

fn sent(call: *Call, path: []const u8, fields: []const multipart.Field, what: []const u8) Error!Made {
    const form = try multipart.encode(call.arena, try call.host.boundary(call.arena), fields);
    const response = try media.send(call, .{ .path = path, .accept = "application/json", .body = form.bytes, .content_type = form.content_type });
    return media.jsonBody(Made, call, response, what);
}
