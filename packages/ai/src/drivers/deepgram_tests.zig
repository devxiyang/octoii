//! Deepgram's driver against its recorded exchanges and what its requests become on the wire.
const std = @import("std");
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const transcriptions = vocabulary.transcriptions;
const FailureKind = vocabulary.FailureKind;
const Models = @import("../Models.zig");
const fixtures = @import("../testing/fixtures.zig");
const deepgram = @import("deepgram.zig");

/// The provider of Deepgram, with its host's Nova-3.
fn optionsOf(a: std.mem.Allocator) !fixtures.Options {
    return .{ .driver = &deepgram.driver, .key = "dg-test", .models = try @import("../testing/host_models.zig").deepgram(a) };
}

fn transcribed(a: std.mem.Allocator, request: []const u8, http: foundation.http.Http, with: fixtures.Options) !@import("../media/stream.zig").Outcome(transcriptions.TranscriptionResponse) {
    const models = try fixtures.modelsOver(a, http, with);
    return models.createTranscription(a, try foundation.json.decode(transcriptions.TranscriptionRequest, a, request));
}

/// Deepgram's answer of `seconds` of a recording.
fn answer(a: std.mem.Allocator, seconds: u32) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"metadata\":{{\"duration\":{d}}},\"results\":{{\"channels\":[{{\"alternatives\":[{{\"transcript\":\"Hi\"}}]}}]}}}}", .{seconds});
}

test "every recorded transcription of Deepgram's is sent as recorded, with its key, its failures classified" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const options = try optionsOf(a);
    for (try fixtures.mediaNames(a, "deepgram", "transcription")) |name| {
        errdefer std.debug.print("deepgram/{s}\n", .{name});
        const streamed = try fixtures.transcriptions(a, name, options);
        try std.testing.expectEqualStrings("Token dg-test", foundation.http.find(streamed.replay.sent.items[0].headers, "authorization").?);
    }
    for ([_]struct { []const u8, FailureKind }{ .{ "unauthorized", .auth }, .{ "payment-required", .quota }, .{ "rate-limited", .rate_limit }, .{ "invalid-json", .invalid_request } }) |case| {
        errdefer std.debug.print("deepgram/{s}\n", .{case[0]});
        try std.testing.expectEqual(case[1], (try fixtures.transcriptions(a, case[0], options)).failure.?.kind);
    }
}

test "Deepgram is sent a recording at an address as JSON, and gives its seconds, unpriced for a model without a price" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const options = try optionsOf(a);
    const streamed = try fixtures.transcriptions(a, "transcription", options);
    try std.testing.expectEqual(@as(usize, 2), streamed.events.len);
    try std.testing.expectEqualStrings("application/json", foundation.http.find(streamed.replay.sent.items[0].headers, "content-type").?);
    const response = (try fixtures.created(transcriptions.TranscriptionRequest, Models.createTranscription, a, "transcription", options)).made;
    try std.testing.expect(std.mem.startsWith(u8, response.text, "Yeah. As as much as,"));
    try fixtures.expectJson(a, "{\"seconds\":25.933313}", try foundation.json.encode(a, response.usage.?));
    try fixtures.expectUsage(.{ .seconds = 25.933313 }, response.octoii.?.usage.?);
}

test "Deepgram is sent a recording's bytes, and gives a verbose transcript its utterances, speakers, words and language" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const options = try optionsOf(a);
    const streamed = try fixtures.transcriptions(a, "transcription-verbose", options);
    try std.testing.expectEqual(@as(usize, 4), streamed.events.len);
    const segment = streamed.events[2].segment;
    try std.testing.expectEqualStrings("And atorvastatin?", segment.text);
    try std.testing.expectEqualStrings("1", segment.speaker);
    try std.testing.expectEqual(@as(f64, 2.2), segment.start);
    const response = (try fixtures.created(transcriptions.TranscriptionRequest, Models.createTranscription, a, "transcription-verbose", options)).made;
    try std.testing.expectEqualStrings("Take metformin daily. And atorvastatin?", response.text);
    try std.testing.expectEqualStrings("transcribe", response.task.?);
    try std.testing.expectEqualStrings("en", response.language.?);
    try std.testing.expectEqual(@as(?f64, 0.97), response.language_confidence);
    try std.testing.expectEqual(@as(?f64, 4.2), response.duration);
    try std.testing.expectEqual(@as(?f64, 0.98), response.confidence);
    try std.testing.expectEqual(@as(?f64, 1), response.segments.?[1].speaker);
    try std.testing.expectEqualStrings("atorvastatin?", response.words.?[4].word);
    try std.testing.expectEqual(@as(?f64, 1), response.words.?[4].speaker);
}

test "Deepgram is priced by the second, sent a stored recording as the type it is, and its own options in the query" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const options = try optionsOf(a);
    var answering: fixtures.Answering = .{ .arena = a, .chunks = try a.dupe([]const u8, &.{try answer(a, 30)}), .content_type = "application/json" };
    const priced = (try transcribed(a, "{\"model\":\"deepgram/nova-3\",\"input_audio\":{\"url\":\"https://example.com/a.mp3\"}}", answering.http(), options)).made;
    try fixtures.expectUsage(.{ .seconds = 30, .cost = 0.0043 / 2.0 }, priced.octoii.?.usage.?);
    var stored = options;
    stored.stored = &.{.{ .ref = "blob:1", .bytes = "ID3\x04\x00\x00\x00\x00\x00\x00" }};
    var bytes: fixtures.Answering = .{ .arena = a, .chunks = try a.dupe([]const u8, &.{try answer(a, 1)}), .content_type = "application/json" };
    _ = try transcribed(a, "{\"model\":\"deepgram/nova-3-pharma\",\"input_audio\":{\"octoii\":{\"ref\":\"blob:1\",\"media_type\":\"audio/mpeg\"}}}", bytes.http(), stored);
    try std.testing.expectEqualStrings("audio/mpeg", foundation.http.find(bytes.sent.items[0].headers, "content-type").?);
    try std.testing.expectEqualStrings("https://api.deepgram.com/v1/listen?model=nova-3-pharma&smart_format=true&detect_language=true", bytes.sent.items[0].url);
    var optioned: fixtures.Answering = .{ .arena = a, .chunks = try a.dupe([]const u8, &.{try answer(a, 1)}), .content_type = "application/json" };
    _ = try transcribed(a, "{\"model\":\"deepgram/nova-3-pharma\",\"input_audio\":{\"url\":\"https://example.com/a.wav\"},\"language\":\"de\",\"provider\":{\"data_collection\":\"deny\",\"options\":{\"deepgram\":{\"numerals\":true,\"redact\":[\"pci\",\"pii\"]}}}}", optioned.http(), options);
    try std.testing.expectEqualStrings("https://api.deepgram.com/v1/listen?model=nova-3-pharma&smart_format=true&language=de&mip_opt_out=true&numerals=true&redact=pci&redact=pii", optioned.sent.items[0].url);
}

test "Deepgram's transcription fails before anything is sent for what Deepgram does not take" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const audio = "\"input_audio\":{\"url\":\"https://example.com/a.wav\"}";
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"model\":\"deepgram/nova-3-pharma\"," ++ audio ++ ",\"temperature\":0.2}", "cannot take temperature: Deepgram does not offer it" },
        .{ "{\"model\":\"deepgram/nova-3-pharma\"," ++ audio ++ ",\"provider\":{\"zdr\":true}}", "cannot take zdr" },
        .{ "{\"model\":\"deepgram/nova-3-pharma\"," ++ audio ++ ",\"provider\":{\"options\":{\"deepgram\":{\"extra\":{\"a\":1}}}}}", "Deepgram's option extra is a parameter of its query" },
        .{ "{\"model\":\"deepgram/nova-3\"," ++ audio ++ ",\"diarize\":true}", "only verbose_json holds" },
    };
    for (cases) |case| {
        var nothing: foundation.replay.Replay = .init(a, &.{});
        const failure = (try transcribed(a, case[0], nothing.http(), try optionsOf(a))).failed;
        if (std.mem.indexOf(u8, failure.message, case[1]) == null) {
            std.debug.print("{s}: {s}\n", .{ case[1], failure.message });
            return error.TestUnexpectedMessage;
        }
        try std.testing.expectEqual(@as(usize, 0), nothing.sent.items.len);
    }
}
