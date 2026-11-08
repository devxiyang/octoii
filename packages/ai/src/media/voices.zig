//! The voice calls as `Models` serves them: a voice made or removed for the account, or a consent recorded, at the
//! provider each names, which makes voices, its stored recording read, and what the provider made named with that
//! provider.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vocabulary = @import("vocabulary");
const voices = vocabulary.voices;
const driver = @import("../driver.zig");
const Call = driver.Call;
const Error = @import("../failure.zig").Error;
const Models = @import("../Models.zig");
const stream_ = @import("stream.zig");
const references = @import("references.zig");
const text_stream = @import("../text/stream.zig");

fn callOf(models: *Models, arena: Allocator) Call {
    return .{ .arena = arena, .provider = undefined, .host = &models.host, .wait = .{ .head_ms = text_stream.start_timeout_ms, .idle_ms = text_stream.idle_timeout_ms } };
}

fn outcome(comptime Made: type, call: *Call, given: Error!Made) Allocator.Error!stream_.Outcome(Made) {
    const made = given catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return .{ .failed = call.failure.? },
    };
    return .{ .made = made };
}

/// The voice calls of the provider `id`, which makes voices.
fn voiceCalls(models: *Models, call: *Call, id: []const u8) Error!driver.VoiceCalls {
    const provider = models.provider(id) orelse return call.failWith(.invalid_request, "No provider {s} is among the host's providers", .{id});
    call.provider = provider;
    return provider.driver.voices orelse call.failWith(.invalid_request, "The provider {s} makes no voices for the account", .{id});
}

/// A voice made from a sample at the provider `params.octoii.provider` names.
pub fn create(models: *Models, arena: Allocator, params: voices.VoiceCreateParams) Allocator.Error!stream_.Outcome(voices.Voice) {
    var call = callOf(models, arena);
    return outcome(voices.Voice, &call, created(models, &call, params));
}

fn created(models: *Models, call: *Call, params: voices.VoiceCreateParams) Error!voices.Voice {
    const calls = try voiceCalls(models, call, params.octoii.provider);
    var prepared = params;
    prepared.audio_sample = try references.readRecording(call, params.audio_sample, "The audio_sample");
    return .{ .id = try calls.create(call, &prepared), .octoii = .{ .provider = call.provider.id } };
}

/// Removes a voice made for the account.
pub fn delete(models: *Models, arena: Allocator, voice: voices.Voice) Allocator.Error!stream_.Outcome(void) {
    var call = callOf(models, arena);
    return outcome(void, &call, deleted(models, &call, voice));
}

fn deleted(models: *Models, call: *Call, voice: voices.Voice) Error!void {
    const calls = try voiceCalls(models, call, voice.octoii.provider);
    return calls.delete(call, voice.id);
}

/// Records a consent at the provider `params.octoii.provider` names.
pub fn createConsent(models: *Models, arena: Allocator, params: voices.VoiceConsentCreateParams) Allocator.Error!stream_.Outcome(voices.VoiceConsent) {
    var call = callOf(models, arena);
    return outcome(voices.VoiceConsent, &call, consented(models, &call, params));
}

fn consented(models: *Models, call: *Call, params: voices.VoiceConsentCreateParams) Error!voices.VoiceConsent {
    const calls = try voiceCalls(models, call, params.octoii.provider);
    const record = calls.create_consent orelse return call.failWith(.invalid_request, "The provider {s} asks for no consents before it makes a voice", .{call.provider.id});
    var prepared = params;
    prepared.recording = try references.readRecording(call, params.recording, "The recording");
    return .{ .id = try record(call, &prepared), .octoii = .{ .provider = call.provider.id } };
}
