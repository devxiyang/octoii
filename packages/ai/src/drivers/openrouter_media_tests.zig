//! OpenRouter's media kinds against their recorded exchanges and what their requests become on the wire.
const std = @import("std");
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const FailureKind = vocabulary.FailureKind;
const fixtures = @import("../testing/fixtures.zig");
const openrouter = @import("openrouter.zig");
const images = @import("openrouter/images.zig");

const options: fixtures.Options = .{ .driver = &openrouter.driver, .key = "sk-or-v1-test" };

/// A tiny PNG.
const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";

fn generated(a: std.mem.Allocator, request: []const u8, http: foundation.http.Http, with: fixtures.Options) !@import("../media/stream.zig").Outcome(vocabulary.images.ImageResponse) {
    const models = try fixtures.modelsOver(a, http, with);
    return models.generateImages(a, try foundation.json.decode(vocabulary.images.ImageRequest, a, request));
}

test "every recorded image exchange of OpenRouter's is sent as recorded, with its key, carrying nothing of ai's" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const names = try fixtures.mediaNames(a, "openrouter", "image");
    try std.testing.expectEqual(@as(usize, 4), names.len);
    for (names) |name| {
        errdefer std.debug.print("openrouter/{s}\n", .{name});
        const streamed = try fixtures.images(a, name, options);
        for (streamed.replay.sent.items) |sent| {
            try std.testing.expectEqualStrings("Bearer sk-or-v1-test", foundation.http.find(sent.headers, "authorization").?);
            try std.testing.expect(std.mem.indexOf(u8, sent.body.?, "octoii") == null);
        }
    }
}

test "OpenRouter's images stream from a model that streams, each priced at the cost OpenRouter gives" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const streamed = try fixtures.images(a, "image", options);
    try std.testing.expectEqual(@as(usize, 2), streamed.events.len);
    try std.testing.expect(streamed.events[0] == .partial_image);
    const completed = streamed.events[1].completed;
    try std.testing.expectEqualStrings("image/png", completed.media_type.?);
    try fixtures.expectUsage(.{ .input = 16, .output_image = 4160, .cost = 0.124928 }, completed.octoii.?.usage.?);
    try std.testing.expectEqualStrings("text/event-stream", foundation.http.find(streamed.replay.sent.items[0].headers, "accept").?);
}

test "OpenRouter's images come whole from a model that answers with JSON, the response's usage once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const loaded = try foundation.json.decode(fixtures.MediaFixture(vocabulary.images.ImageRequest), a, try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/fixtures/openrouter/image-json.json", a, .limited(1 << 20)));
    var replay: foundation.replay.Replay = .init(a, loaded.exchanges);
    const models = try fixtures.modelsOver(a, replay.http(), options);
    const outcome = try models.generateImages(a, loaded.request);
    const response = outcome.made;
    try std.testing.expectEqual(@as(i64, 1793228547), response.created);
    try std.testing.expectEqual(@as(usize, 2), response.data.len);
    try std.testing.expectEqualStrings("image/png", response.data[1].media_type.?);
    try std.testing.expectEqual(@as(u64, 8355), response.usage.?.total_tokens);
    try std.testing.expectEqual(@as(?f64, 0.08), response.usage.?.cost);
    try fixtures.expectUsage(.{ .input = 5, .output_image = 8350, .cost = 0.08 }, response.octoii.?.usage.?);
    try std.testing.expect(std.mem.indexOf(u8, replay.sent.items[0].body.?, "\"stream\"") == null);
}

test "OpenRouter is asked for a stream of images only of a model that streams" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const request: vocabulary.images.ImageRequest = .{ .model = "openrouter/x", .prompt = "A fox" };
    const streaming = try fixtures.catalogueModel(a, "openrouter", "openai/gpt-image-2");
    try fixtures.expectJson(a, "{\"model\":\"openai/gpt-image-2\",\"prompt\":\"A fox\",\"stream\":true}", try images.wireRequest(a, &streaming, request));
    const whole = try fixtures.catalogueModel(a, "openrouter", "qwen/qwen-image-3-pro");
    try fixtures.expectJson(a, "{\"model\":\"qwen/qwen-image-3-pro\",\"prompt\":\"A fox\"}", try images.wireRequest(a, &whole, request));
}

test "OpenRouter's images end with its error, classified, and fail as a rate limit with the wait it asks for" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const broken = try fixtures.images(a, "image-stream-error", options);
    const raised = broken.events[broken.events.len - 1].@"error".@"error";
    try std.testing.expectEqualStrings("server_error", raised.code);
    try std.testing.expectEqualStrings("Generation failed", raised.message);
    try std.testing.expectEqualStrings("provider_error", raised.type.?);
    try std.testing.expectEqual(FailureKind.server, raised.octoii.kind);
    try std.testing.expect(raised.octoii.retryable);
    try std.testing.expectEqualStrings("server_error", broken.failure.?.code.?);
    const limited = (try fixtures.images(a, "image-rate-limited", options)).failure.?;
    try std.testing.expectEqual(FailureKind.rate_limit, limited.kind);
    try std.testing.expect(limited.retryable);
    try std.testing.expectEqual(@as(?u64, 30_000), limited.retry_after_ms);
    try std.testing.expectEqual(@as(?u16, 429), limited.status);
}

test "OpenRouter's images fail before anything is sent for a setting the model does not allow" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"model\":\"openrouter/openai/gpt-image-2\",\"prompt\":\"A fox\",\"quality\":\"max\"}", "does not take the quality \"max\": it takes auto, low, medium, high" },
        .{ "{\"model\":\"openrouter/openai/gpt-image-2\",\"prompt\":\"A fox\",\"n\":11}", "does not take the n 11: it takes 1 to 10" },
        .{ "{\"model\":\"openrouter/qwen/qwen-image-3-pro\",\"prompt\":\"A fox\",\"background\":\"opaque\"}", "does not take background: its octoii.image_parameters do not list it" },
        .{ "{\"model\":\"openrouter/openai/gpt-image-2\",\"prompt\":\"A fox\",\"provider\":{\"zdr\":true}}", "OpenRouter's image API takes no provider zdr" },
    };
    for (cases) |case| {
        var nothing: foundation.replay.Replay = .init(a, &.{});
        const failure = (try generated(a, case[0], nothing.http(), options)).failed;
        try std.testing.expectEqual(FailureKind.invalid_request, failure.kind);
        if (std.mem.indexOf(u8, failure.message, case[1]) == null) {
            std.debug.print("{s}: {s}\n", .{ case[1], failure.message });
            return error.TestUnexpectedMessage;
        }
        try std.testing.expectEqual(@as(usize, 0), nothing.sent.items.len);
    }
}

test "OpenRouter is sent a stored reference inline, of the type its bytes say, without ai's extension" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const decoder = std.base64.standard.Decoder;
    const bytes = try a.alloc(u8, try decoder.calcSizeForSlice(png));
    try decoder.decode(bytes, png);
    var with = options;
    with.stored = &.{.{ .ref = "blob:1", .bytes = bytes }};
    var answering: fixtures.Answering = .{ .arena = a, .chunks = &.{"{\"created\":1,\"data\":[{\"b64_json\":\"" ++ png ++ "\"}]}"}, .content_type = "application/json" };
    const outcome = try generated(a, "{\"model\":\"openrouter/qwen/qwen-image-3-pro\",\"prompt\":\"Like this\",\"input_references\":[{\"type\":\"image_url\",\"image_url\":{},\"octoii\":{\"ref\":\"blob:1\"}}]}", answering.http(), with);
    try std.testing.expect(outcome == .made);
    const body = try std.json.parseFromSliceLeaky(std.json.Value, a, answering.sent.items[0].body.?, .{});
    try fixtures.expectJson(a, "[{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64," ++ png ++ "\"}}]", try foundation.json.encode(a, body.object.get("input_references").?));
}

const SpeechOutcome = @import("../media/stream.zig").Outcome(vocabulary.speech.SpeechResponse);

fn spokenFixture(a: std.mem.Allocator, name: []const u8) !SpeechOutcome {
    const path = try std.fmt.allocPrint(a, "test/fixtures/openrouter/{s}.json", .{name});
    const fixture = try foundation.json.decode(fixtures.MediaFixture(vocabulary.speech.SpeechRequest), a, try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(1 << 20)));
    var replay = try a.create(foundation.replay.Replay);
    replay.* = .init(a, fixture.exchanges);
    const models = try fixtures.modelsOver(a, replay.http(), options);
    return models.createSpeech(a, fixture.request);
}

fn decodedLength(encoded: []const u8) !usize {
    return std.base64.standard.Decoder.calcSizeForSlice(encoded);
}

test "OpenRouter's speech streams the audio's bytes as they arrive, priced by the characters spoken, joined for create" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for (try fixtures.mediaNames(a, "openrouter", "speech")) |name| _ = try fixtures.speech(a, name, options);
    const streamed = try fixtures.speech(a, "speech", options);
    try std.testing.expect(streamed.events.len > 2);
    for (streamed.events[0 .. streamed.events.len - 1]) |event| try std.testing.expect(event == .delta);
    try std.testing.expectEqualStrings("audio/mpeg", streamed.events[0].delta.octoii.media_type);
    try fixtures.expectUsage(.{ .characters = 22, .cost = 22 * 0.00008 }, streamed.events[streamed.events.len - 1].done.octoii.?.usage.?);
    const response = (try spokenFixture(a, "speech")).made;
    try std.testing.expectEqualStrings("audio/mpeg", response.media_type);
    try std.testing.expect(std.mem.startsWith(u8, response.data, "SUQz"));
    const pcm = (try spokenFixture(a, "speech-pcm")).made;
    try std.testing.expectEqualStrings("audio/pcm;rate=24000", pcm.media_type);
    try std.testing.expectEqual(@as(usize, 96), try decodedLength(pcm.data));
    try std.testing.expectEqual(@as(?u64, "How's it going today, Jane?".len + "Not too bad, how about you?".len), pcm.usage.?.characters);
}

test "OpenRouter's speech fails before anything is sent for a voice, instructions or a voice of the account" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"model\":\"openrouter/elevenlabs/eleven-v4\",\"input\":\"Hi\",\"voice\":\"alloy\"}", "has no voice \"alloy\"" },
        .{ "{\"model\":\"openrouter/elevenlabs/eleven-v4\",\"input\":\"Hi\",\"instructions\":\"warmly\"}", "takes no instructions on how to speak" },
        .{ "{\"model\":\"openrouter/elevenlabs/eleven-v4\",\"input\":\"Hi\",\"voice\":{\"id\":\"voice_1\"}}", "OpenRouter has no voices made for the account" },
    };
    for (cases) |case| {
        var nothing: foundation.replay.Replay = .init(a, &.{});
        const models = try fixtures.modelsOver(a, nothing.http(), options);
        const failure = (try models.createSpeech(a, try foundation.json.decode(vocabulary.speech.SpeechRequest, a, case[0]))).failed;
        if (std.mem.indexOf(u8, failure.message, case[1]) == null) {
            std.debug.print("{s}: {s}\n", .{ case[1], failure.message });
            return error.TestUnexpectedMessage;
        }
        try std.testing.expectEqual(@as(usize, 0), nothing.sent.items.len);
    }
}

const transcriptions = vocabulary.transcriptions;

test "OpenRouter's transcription is the whole text, then the transcript with its usage and OpenRouter's cost" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for (try fixtures.mediaNames(a, "openrouter", "transcription")) |name| _ = try fixtures.transcriptions(a, name, options);
    const streamed = try fixtures.transcriptions(a, "transcription", options);
    try std.testing.expectEqual(@as(usize, 2), streamed.events.len);
    const Models = @import("../Models.zig");
    const response = (try fixtures.created(transcriptions.TranscriptionRequest, Models.createTranscription, a, "transcription", options)).made;
    try std.testing.expectEqualStrings("Hello, this is a test of speech-to-text transcription.", response.text);
    try fixtures.expectUsage(.{ .seconds = 9.2, .input = 83, .output = 30, .cost = 0.00069 }, response.octoii.?.usage.?);
    const verbose = (try fixtures.created(transcriptions.TranscriptionRequest, Models.createTranscription, a, "transcription-verbose", options)).made;
    try std.testing.expectEqualStrings("Hello from OpenRouter.", verbose.text);
    try std.testing.expectEqualStrings("eng", verbose.language.?);
    try std.testing.expectEqual(@as(?f64, 2.08), verbose.duration);
    try std.testing.expectEqual(@as(f64, 2.08), verbose.segments.?[0].end);
    try std.testing.expectEqualStrings("OpenRouter.", verbose.words.?[2].word);
    try fixtures.expectUsage(.{ .seconds = 2.08, .cost = 0.000127111111111088 }, verbose.octoii.?.usage.?);
}

test "OpenRouter is sent a stored recording as base64 in the format its media type names, and refuses what it cannot answer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var with = options;
    with.stored = &.{.{ .ref = "blob:2", .bytes = "RIFF$\x00\x00\x00WAVEfmt " }};
    var answering: fixtures.Answering = .{ .arena = a, .chunks = &.{"{\"text\":\"Hi\"}"}, .content_type = "application/json" };
    const models = try fixtures.modelsOver(a, answering.http(), with);
    _ = try models.createTranscription(a, try foundation.json.decode(transcriptions.TranscriptionRequest, a, "{\"model\":\"openrouter/openai/gpt-transcribe\",\"input_audio\":{\"octoii\":{\"ref\":\"blob:2\"}}}"));
    const body = answering.sent.items[0].body.?;
    try std.testing.expect(std.mem.indexOf(u8, body, "\"format\":\"wav\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "octoii") == null);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"model\":\"openrouter/openai/gpt-transcribe\",\"input_audio\":{\"data\":\"UklGRg==\",\"format\":\"wav\"},\"timestamp_granularities\":[\"word\"]}", "only verbose_json holds" },
        .{ "{\"model\":\"openrouter/openai/gpt-transcribe\",\"input_audio\":{\"data\":\"UklGRg==\",\"format\":\"wav\"},\"response_format\":\"verbose_json\",\"diarize\":true}", "does not tell speakers apart" },
    };
    for (cases) |case| {
        var nothing: foundation.replay.Replay = .init(a, &.{});
        const refusing = try fixtures.modelsOver(a, nothing.http(), options);
        const failure = (try refusing.createTranscription(a, try foundation.json.decode(transcriptions.TranscriptionRequest, a, case[0]))).failed;
        if (std.mem.indexOf(u8, failure.message, case[1]) == null) {
            std.debug.print("{s}: {s}\n", .{ case[1], failure.message });
            return error.TestUnexpectedMessage;
        }
        try std.testing.expectEqual(@as(usize, 0), nothing.sent.items.len);
    }
}

const decisions = vocabulary.decisions;

fn decidedFixture(a: std.mem.Allocator, name: []const u8) !struct { outcome: @import("../media/stream.zig").Outcome(decisions.DecisionsResponse), replay: *foundation.replay.Replay } {
    const path = try std.fmt.allocPrint(a, "test/fixtures/openrouter/{s}.json", .{name});
    const fixture = try foundation.json.decode(fixtures.MediaFixture(decisions.DecisionsRequest), a, try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(1 << 20)));
    const replay = try a.create(foundation.replay.Replay);
    replay.* = .init(a, fixture.exchanges);
    const models = try fixtures.modelsOver(a, replay.http(), options);
    const outcome = try models.decide(a, fixture.request);
    try std.testing.expectEqual(null, replay.mismatch);
    try std.testing.expectEqual(@as(usize, 0), replay.unused().len);
    return .{ .outcome = outcome, .replay = replay };
}

test "OpenRouter's decisions are answered at its Decisions API, typed by their questions and priced" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const decided = try decidedFixture(a, "decision");
    try std.testing.expectEqualStrings("https://openrouter.ai/api/alpha/decisions", decided.replay.sent.items[0].url);
    const response = decided.outcome.made;
    try fixtures.expectJson(a, "{\"type\":\"noul\",\"noul\":0.97}", try foundation.json.encode(a, response.answers.map.get("is_refund").?));
    try std.testing.expectEqualStrings("angry", response.answers.map.get("sentiment").?.choice.choice);
    try fixtures.expectUsage(.{ .input = 367, .output = 75, .cost = 0.000015414 }, response.octoii.?.usage.?);
    const imaged = (try decidedFixture(a, "decision-image")).outcome.made;
    try std.testing.expectEqual(@as(?u64, 289), imaged.octoii.?.usage.?.input);
    try std.testing.expectApproxEqAbs(289 * 0.0000001, imaged.octoii.?.usage.?.cost.?, 1e-12);
    const spent = (try decidedFixture(a, "decision-payment-required")).outcome.failed;
    try std.testing.expectEqual(FailureKind.quota, spent.kind);
    try std.testing.expectEqual(@as(?u16, 402), spent.status);
    const prohibited = (try decidedFixture(a, "decision-terms-of-service")).outcome.failed;
    try std.testing.expectEqual(FailureKind.forbidden, prohibited.kind);
    try std.testing.expect(!prohibited.retryable);
}

test "OpenRouter's decisions send a stored image inline, refuse a box to a model that answers none, and stand beside its APIs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const decoder = std.base64.standard.Decoder;
    const bytes = try a.alloc(u8, try decoder.calcSizeForSlice(png));
    try decoder.decode(bytes, png);
    var with = options;
    with.stored = &.{.{ .ref = "blob:3", .bytes = bytes }};
    var answering: fixtures.Answering = .{ .arena = a, .chunks = &.{"{\"model\":\"typesafe/jev-1.14\",\"answers\":{\"shown\":{\"type\":\"noul\",\"noul\":0.5}},\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}"}, .content_type = "application/json" };
    const models = try fixtures.modelsOver(a, answering.http(), with);
    const outcome = try models.decide(a, try foundation.json.decode(decisions.DecisionsRequest, a,
        \\{"model":"openrouter/typesafe/jev-1.14","state":{"photo":{"type":"image_url","image_url":{},"octoii":{"ref":"blob:3"}}},"questions":{"shown":{"type":"noul","instructions":"The photo shows a dog."}}}
    ));
    try std.testing.expect(outcome == .made);
    const body = try std.json.parseFromSliceLeaky(std.json.Value, a, answering.sent.items[0].body.?, .{});
    try fixtures.expectJson(a, "{\"photo\":{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64," ++ png ++ "\"}}}", try foundation.json.encode(a, body.object.get("state").?));
    var nothing: foundation.replay.Replay = .init(a, &.{});
    const refusing = try fixtures.modelsOver(a, nothing.http(), options);
    const boxed = (try refusing.decide(a, try foundation.json.decode(decisions.DecisionsRequest, a, "{\"model\":\"openrouter/openai/gpt-6-luna-decisions\",\"state\":\"x\",\"questions\":{\"where\":{\"type\":\"box\",\"instructions\":\"The dog\"}}}"))).failed;
    try std.testing.expect(std.mem.indexOf(u8, boxed.message, "answers no box questions, as where is") != null);
    try std.testing.expectEqual(@as(usize, 0), nothing.sent.items.len);
    const beside = @import("openrouter/decisions.zig").baseUrl;
    try std.testing.expectEqualStrings("https://openrouter.ai/api/alpha", try beside(a, "https://openrouter.ai/api/v1"));
    try std.testing.expectEqualStrings("https://proxy.example/alpha", try beside(a, "https://proxy.example/v1"));
}
