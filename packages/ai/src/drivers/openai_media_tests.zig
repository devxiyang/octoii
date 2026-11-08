//! OpenAI's media kinds against their recorded exchanges and what their requests become on the wire.
const std = @import("std");
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const FailureKind = vocabulary.FailureKind;
const seam = @import("../driver.zig");
const fixtures = @import("../testing/fixtures.zig");
const TestHost = @import("../testing/host.zig").Host;
const openai = @import("openai.zig");
const images = @import("openai/images.zig");

const options: fixtures.Options = .{ .driver = &openai.driver, .key = "sk-test" };

/// A tiny PNG.
const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";

const Outcome = @import("../media/stream.zig").Outcome(vocabulary.images.ImageResponse);

fn generated(a: std.mem.Allocator, request: []const u8, http: foundation.http.Http, with: fixtures.Options) !Outcome {
    const models = try fixtures.modelsOver(a, http, with);
    return models.generateImages(a, try foundation.json.decode(vocabulary.images.ImageRequest, a, request));
}

fn expectMessage(failure: @import("../failure.zig").Failure, words: []const u8) !void {
    if (std.mem.indexOf(u8, failure.message, words) != null) return;
    std.debug.print("{s}: {s}\n", .{ words, failure.message });
    return error.TestUnexpectedMessage;
}

test "every recorded image exchange of OpenAI's is sent as recorded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const names = try fixtures.mediaNames(a, "openai", "image");
    try std.testing.expectEqual(@as(usize, 3), names.len);
    for (names) |name| {
        errdefer std.debug.print("openai/{s}\n", .{name});
        const streamed = try fixtures.images(a, name, options);
        for (streamed.replay.sent.items) |sent| try std.testing.expect(std.mem.indexOf(u8, sent.body.?, "octoii") == null);
    }
}

test "OpenAI's images stream previews and the image, priced by its own meters of text and images" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const streamed = try fixtures.images(a, "image", options);
    try std.testing.expectEqual(@as(usize, 2), streamed.events.len);
    try fixtures.expectJson(a, "{\"type\":\"image_generation.partial_image\",\"partial_image_index\":0,\"b64_json\":\"" ++ png ++ "\"}", try foundation.json.encode(a, streamed.events[0]));
    const completed = streamed.events[1].completed;
    try std.testing.expectEqualStrings("image/png", completed.media_type.?);
    try std.testing.expectEqual(@as(i64, 1793275200), completed.created);
    try fixtures.expectJson(a, "{\"prompt_tokens\":50,\"completion_tokens\":50,\"total_tokens\":100,\"completion_tokens_details\":{\"image_tokens\":50}}", try foundation.json.encode(a, completed.usage.?));
    // 10 text tokens at $5, 40 image tokens read at $8 and 50 made at $30 a million.
    try fixtures.expectUsage(.{ .input = 10, .input_image = 40, .output_image = 50, .cost = 0.00187 }, completed.octoii.?.usage.?);
    try std.testing.expectEqualStrings("text/event-stream", foundation.http.find(streamed.replay.sent.items[0].headers, "accept").?);
}

test "OpenAI's images are edited at /images/edits, and come whole from a model that answers with JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const edited = try fixtures.images(a, "image-edit", options);
    const completed = edited.events[edited.events.len - 1].completed;
    try std.testing.expectEqual(@as(i64, 1793275260), completed.created);
    try std.testing.expectEqualStrings("image/webp", completed.media_type.?);
    const used = completed.octoii.?.usage.?;
    try std.testing.expectEqual(@as(?u64, 12), used.input);
    try std.testing.expectEqual(@as(?u64, 288), used.input_image);
    try std.testing.expectEqual(@as(?u64, 1056), used.output_image);
    var still = options;
    still.models = &.{.{ .id = "gpt-image-still", .supports_streaming = false, .octoii = .{ .kinds = &.{.image} } }};
    var answering: fixtures.Answering = .{
        .arena = a,
        .chunks = &.{"{\"created\":1793275300,\"data\":[{\"b64_json\":\"" ++ png ++ "\"},{\"b64_json\":\"" ++ png ++ "\"}],\"output_format\":\"jpeg\",\"usage\":{\"input_tokens\":20,\"output_tokens\":200,\"total_tokens\":220,\"input_tokens_details\":{\"text_tokens\":20,\"image_tokens\":0}}}"},
        .content_type = "application/json",
    };
    const response = (try generated(a, "{\"model\":\"openai/gpt-image-still\",\"prompt\":\"Two foxes\",\"n\":2,\"output_format\":\"jpeg\"}", answering.http(), still)).made;
    try std.testing.expectEqualStrings("image/jpeg", response.data[0].media_type.?);
    try std.testing.expectEqualStrings("image/jpeg", response.data[1].media_type.?);
    try std.testing.expectEqual(@as(?u64, 20), response.octoii.?.usage.?.input);
    try std.testing.expectEqual(@as(?u64, 200), response.octoii.?.usage.?.output_image);
    try fixtures.expectJson(a, "{\"prompt\":\"Two foxes\",\"n\":2,\"output_format\":\"jpeg\",\"model\":\"gpt-image-still\"}", answering.sent.items[0].body.?);
}

test "OpenAI is sent the image settings it takes, its own options, and a stream for a model that streams" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const model = try fixtures.catalogueModel(a, "openai", "gpt-image-2.5-sunburst");
    const provider: seam.Provider = .{ .id = "openai", .name = "OpenAI", .driver = &openai.driver };
    var test_host: TestHost = .{};
    var nothing: foundation.replay.Replay = .init(a, &.{});
    const host = test_host.host(nothing.http());
    var call: seam.Call = .{ .arena = a, .provider = &provider, .host = &host };
    const request = try foundation.json.decode(vocabulary.images.ImageRequest, a, "{\"model\":\"openai/x\",\"prompt\":\"A fox\",\"size\":\"1536x1024\",\"background\":\"transparent\",\"provider\":{\"options\":{\"openai\":{\"moderation\":\"low\"}}}}");
    try fixtures.expectJson(a, "{\"prompt\":\"A fox\",\"size\":\"1536x1024\",\"background\":\"transparent\",\"moderation\":\"low\",\"model\":\"gpt-image-2.5-sunburst\",\"stream\":true}", try images.wireRequest(&call, &model, request));
}

test "OpenAI's images fail before anything is sent for a setting the model or OpenAI does not take" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var unlisted = options;
    unlisted.models = &.{.{ .id = "gpt-image-host", .octoii = .{ .kinds = &.{.image} } }};
    const cases = [_]struct { []const u8, []const u8, fixtures.Options }{
        .{ "{\"model\":\"openai/gpt-image-2.5-sunburst\",\"prompt\":\"A fox\",\"size\":\"4K\"}", "does not take the size \"4K\"", options },
        .{ "{\"model\":\"openai/gpt-image-2.5-sunburst\",\"prompt\":\"A fox\",\"aspect_ratio\":\"16:9\"}", "does not take aspect_ratio", options },
        .{ "{\"model\":\"openai/gpt-image-2.5-sunburst\",\"prompt\":\"A fox\",\"provider\":{\"order\":[\"openai\"]}}", "OpenAI's image API takes no provider order: its provider takes options alone", options },
        .{ "{\"model\":\"openai/gpt-image-host\",\"prompt\":\"A fox\",\"seed\":1}", "OpenAI's image API takes no seed: give the image's size instead", unlisted },
    };
    for (cases) |case| {
        var nothing: foundation.replay.Replay = .init(a, &.{});
        const failure = (try generated(a, case[0], nothing.http(), case[2])).failed;
        try std.testing.expectEqual(FailureKind.invalid_request, failure.kind);
        try expectMessage(failure, case[1]);
        try std.testing.expectEqual(@as(usize, 0), nothing.sent.items.len);
    }
}

test "OpenAI is sent a stored reference inline at /images/edits, and its errors end the stream classified" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const decoder = std.base64.standard.Decoder;
    const bytes = try a.alloc(u8, try decoder.calcSizeForSlice(png));
    try decoder.decode(bytes, png);
    var with = options;
    with.stored = &.{.{ .ref = "blob:1", .bytes = bytes }};
    var answering: fixtures.Answering = .{ .arena = a, .chunks = &.{"data: {\"type\":\"image_edit.completed\",\"b64_json\":\"" ++ png ++ "\",\"created_at\":1,\"output_format\":\"png\"}\n\n"} };
    _ = try generated(a, "{\"model\":\"openai/gpt-image-2.5-sunburst\",\"prompt\":\"Like this\",\"input_references\":[{\"type\":\"image_url\",\"image_url\":{},\"octoii\":{\"ref\":\"blob:1\"}}]}", answering.http(), with);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/images/edits", answering.sent.items[0].url);
    try std.testing.expect(std.mem.indexOf(u8, answering.sent.items[0].body.?, "{\"image_url\":\"data:image/png;base64," ++ png ++ "\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, answering.sent.items[0].body.?, "octoii") == null);
    const blocked = try fixtures.images(a, "image-moderation", options);
    try std.testing.expectEqual(@as(usize, 1), blocked.events.len);
    try fixtures.expectJson(a,
        \\{"type":"error","error":{"code":"moderation_blocked","message":"Your request was rejected by the safety system.","octoii":{"kind":"content_filter","retryable":false,"status":400}}}
    , try foundation.json.encode(a, blocked.events[0]));
    var failing: fixtures.Answering = .{ .arena = a, .chunks = &.{
        "data: {\"type\":\"image_generation.partial_image\",\"b64_json\":\"" ++ png ++ "\",\"partial_image_index\":0}\n\n",
        "data: {\"type\":\"error\",\"error\":{\"code\":\"server_error\",\"message\":\"The image failed\",\"type\":\"server_error\"}}\n\n",
    } };
    const models = try fixtures.modelsOver(a, failing.http(), options);
    var stream = models.imageStream(a, .{ .model = "openai/gpt-image-2.5-sunburst", .prompt = "A fox" });
    try std.testing.expect((try stream.next()).? == .partial_image);
    const raised = (try stream.next()).?.@"error".@"error";
    try std.testing.expectEqualStrings("server_error", raised.code);
    try std.testing.expectEqualStrings("The image failed", raised.message);
    try std.testing.expectEqual(FailureKind.server, raised.octoii.kind);
    try std.testing.expectEqual(null, try stream.next());
}

const SpeechOutcome = @import("../media/stream.zig").Outcome(vocabulary.speech.SpeechResponse);

/// The provider of OpenAI, with its host's models.
fn hostOptions(a: std.mem.Allocator) !fixtures.Options {
    var with = options;
    with.models = try @import("../testing/host_models.zig").openai(a);
    return with;
}

fn spoken(a: std.mem.Allocator, request: []const u8, http: foundation.http.Http) !SpeechOutcome {
    const models = try fixtures.modelsOver(a, http, try hostOptions(a));
    return models.createSpeech(a, try foundation.json.decode(vocabulary.speech.SpeechRequest, a, request));
}

test "OpenAI's speech streams as server-sent events, a voice of the account by its id, priced by the tokens it reports" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const streamed = try fixtures.speech(a, "speech", try hostOptions(a));
    const mp3 = "SUQzBAAAAAAAI1RTU0UAAAAPAAADTGF2ZjYxLjcuMTAwAAAAAAAAAAAAAAD/+0DAAAAAAAAAAAAAAAAAAAAAAAA=";
    try fixtures.expectJson(a, "{\"type\":\"speech.audio.delta\",\"audio\":\"" ++ mp3 ++ "\",\"octoii\":{\"media_type\":\"audio/mpeg\"}}", try foundation.json.encode(a, streamed.events[0]));
    const done = streamed.events[streamed.events.len - 1].done;
    try fixtures.expectJson(a, "{\"input_tokens\":14,\"output_tokens\":101,\"total_tokens\":115}", try foundation.json.encode(a, done.usage.?));
    // 14 text tokens at $0.60 and 101 audio tokens at $12 a million; the characters only describe it.
    try fixtures.expectUsage(.{ .characters = 45, .input = 14, .output_audio = 101, .cost = 0.0012204 }, done.octoii.?.usage.?);
    var replay: foundation.replay.Replay = .init(a, (try foundation.json.decode(fixtures.MediaFixture(vocabulary.speech.SpeechRequest), a, try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/fixtures/openai/speech.json", a, .limited(1 << 20)))).exchanges);
    const response = (try spoken(a, "{\"model\":\"openai/gpt-4o-mini-tts\",\"input\":\"The quick brown fox jumped over the lazy dog.\",\"voice\":{\"id\":\"voice_1234\"},\"instructions\":\"Speak warmly.\"}", replay.http())).made;
    try std.testing.expectEqualStrings("audio/mpeg", response.media_type);
    try std.testing.expectEqualStrings(mp3, response.data);
}

test "OpenAI names PCM by its rate, sends what its speech takes, and refuses turns, samples, unknown voices and data policies" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var answering: fixtures.Answering = .{ .arena = a, .chunks = &.{"data: {\"type\":\"speech.audio.delta\",\"audio\":\"AAAA\"}\n\ndata: {\"type\":\"speech.audio.done\"}\n\n"} };
    const response = (try spoken(a, "{\"model\":\"openai/gpt-4o-mini-tts\",\"input\":\"Hi\",\"voice\":{\"id\":\"voice_1234\"},\"response_format\":\"pcm\"}", answering.http())).made;
    try std.testing.expectEqualStrings("audio/pcm;rate=24000", response.media_type);
    try fixtures.expectJson(a, "{\"input\":\"Hi\",\"voice\":{\"id\":\"voice_1234\"},\"response_format\":\"pcm\",\"model\":\"gpt-4o-mini-tts\",\"stream_format\":\"sse\"}", answering.sent.items[0].body.?);
    var plain: fixtures.Answering = .{ .arena = a, .chunks = answering.chunks };
    _ = try spoken(a, "{\"model\":\"openai/gpt-4o-mini-tts\",\"input\":\"Hi\",\"voice\":\"marin\",\"speed\":1.25,\"session_id\":\"s\",\"user\":\"u\"}", plain.http());
    try fixtures.expectJson(a, "{\"input\":\"Hi\",\"voice\":\"marin\",\"speed\":1.25,\"model\":\"gpt-4o-mini-tts\",\"stream_format\":\"sse\"}", plain.sent.items[0].body.?);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"model\":\"openai/gpt-4o-mini-tts\",\"input\":[{\"text\":\"Hi\"},{\"text\":\"Hello\"}]}", "OpenAI's speech API speaks one text: it takes no turns of several speakers" },
        .{ "{\"model\":\"openai/gpt-4o-mini-tts\",\"input\":\"Hi\",\"input_references\":[{\"type\":\"text\",\"text\":\"Hi\"}]}", "takes no input_references" },
        .{ "{\"model\":\"openai/gpt-4o-mini-tts\",\"input\":\"Hi\",\"voice\":\"george\"}", "has no voice \"george\"" },
        .{ "{\"model\":\"openai/gpt-4o-mini-tts\",\"input\":\"Hi\",\"provider\":{\"zdr\":true}}", "OpenAI's speech API takes no provider zdr: its provider takes options alone" },
    };
    for (cases) |case| {
        var nothing: foundation.replay.Replay = .init(a, &.{});
        try expectMessage((try spoken(a, case[0], nothing.http())).failed, case[1]);
        try std.testing.expectEqual(@as(usize, 0), nothing.sent.items.len);
    }
}

const transcriptions = vocabulary.transcriptions;
const TranscriptionOutcome = @import("../media/stream.zig").Outcome(transcriptions.TranscriptionResponse);
const mp3_bytes = "SUQzBAAAAAAAI1RTU0UAAAAPAAADTGF2ZjYxLjcuMTAwAAAAAAAAAAAAAAD/+0DAAAAAAAAAAAAAAAAAAAAAAAA=";

fn transcribed(a: std.mem.Allocator, request: []const u8, http: foundation.http.Http, with: fixtures.Options) !TranscriptionOutcome {
    const models = try fixtures.modelsOver(a, http, with);
    return models.createTranscription(a, try foundation.json.decode(transcriptions.TranscriptionRequest, a, request));
}

test "OpenAI streams gpt-transcribe's text, its languages and keyterms named as OpenAI names them, the language heard kept" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const with = try hostOptions(a);
    for (try fixtures.mediaNames(a, "openai", "transcription")) |name| _ = try fixtures.transcriptions(a, name, with);
    const streamed = try fixtures.transcriptions(a, "transcription", with);
    try std.testing.expectEqual(@as(usize, 3), streamed.events.len);
    const done = streamed.events[2].done;
    try std.testing.expectEqualStrings("Bonjour, pouvez-vous m'entendre ?", done.text);
    try fixtures.expectJson(a, "{\"input_tokens\":24,\"output_tokens\":11,\"total_tokens\":35}", try foundation.json.encode(a, done.usage.?));
    try std.testing.expectEqualStrings("fr", done.octoii.?.transcription.?.language.?);
    const response = (try fixtures.created(transcriptions.TranscriptionRequest, @import("../Models.zig").createTranscription, a, "transcription", with)).made;
    try std.testing.expectEqualStrings("fr", response.language.?);
    // gpt-transcribe bills by the second, so its tokens are given no cost.
    try fixtures.expectUsage(.{ .input = 24, .output = 11 }, response.octoii.?.usage.?);
    var answering: fixtures.Answering = .{ .arena = a, .chunks = &.{"data: {\"type\":\"transcript.text.done\",\"text\":\"Hi\",\"usage\":{\"type\":\"duration\",\"seconds\":60}}\n\n"} };
    const timed = (try transcribed(a, "{\"model\":\"openai/gpt-transcribe\",\"input_audio\":{\"data\":\"" ++ mp3_bytes ++ "\",\"format\":\"mp3\"}}", answering.http(), with)).made;
    try fixtures.expectJson(a, "{\"seconds\":60}", try foundation.json.encode(a, timed.usage.?));
    try std.testing.expectApproxEqAbs(0.0045, timed.octoii.?.usage.?.cost.?, 1e-12);
}

test "OpenAI fetches a recording at an address, keeps a verbose transcript, and uploads a stored one by its format" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const with = try hostOptions(a);
    const verbose = try fixtures.transcriptions(a, "transcription-verbose", with);
    const done = verbose.events[verbose.events.len - 1].done;
    const details = done.octoii.?.transcription.?;
    try std.testing.expectEqualStrings("transcribe", details.task.?);
    try std.testing.expectEqualStrings("english", details.language.?);
    try std.testing.expectEqual(@as(?f64, 0.5), details.duration);
    try std.testing.expectEqualStrings("Hello", details.words.?[0].word);
    try fixtures.expectUsage(.{ .seconds = 1, .cost = 0.0001 }, done.octoii.?.usage.?);
    try std.testing.expectEqualStrings("https://example.com/hello.mp3", verbose.replay.sent.items[0].url);
    try std.testing.expectEqual(null, foundation.http.find(verbose.replay.sent.items[0].headers, "authorization"));
    try std.testing.expectEqualStrings("application/json", foundation.http.find(verbose.replay.sent.items[1].headers, "accept").?);
    const decoder = std.base64.standard.Decoder;
    const bytes = try a.alloc(u8, try decoder.calcSizeForSlice(mp3_bytes));
    try decoder.decode(bytes, mp3_bytes);
    var stored = with;
    stored.stored = &.{.{ .ref = "blob:2", .bytes = bytes }};
    var answering: fixtures.Answering = .{ .arena = a, .chunks = &.{"{\"text\":\"Hi\"}"}, .content_type = "application/json" };
    _ = try transcribed(a, "{\"model\":\"openai/whisper-1\",\"input_audio\":{\"octoii\":{\"ref\":\"blob:2\"}}}", answering.http(), stored);
    const sent = answering.sent.items[0];
    const form = (try foundation.multipart.parse(a, foundation.http.find(sent.headers, "content-type").?, sent.body.?)).?;
    try std.testing.expectEqual(@as(usize, 2), form.len);
    try std.testing.expectEqualStrings("audio.mp3", form[0].filename.?);
    try std.testing.expectEqualStrings("audio/mpeg", form[0].content_type.?);
    try std.testing.expectEqualSlices(u8, bytes, form[0].data.?);
    try std.testing.expectEqualStrings("whisper-1", form[1].value.?);
}

test "OpenAI's transcription fails before anything is sent for what its models do not take, and as a rate limit with its wait" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const with = try hostOptions(a);
    var told = with;
    told.models = try foundation.json.decode([]const @import("../catalogue/facts.zig").ModelFacts, a, "[{\"id\":\"whisper-1\",\"architecture\":{\"input_modalities\":[\"audio\"],\"output_modalities\":[\"transcription\"]},\"octoii\":{\"kinds\":[\"transcription\"],\"speakers\":true}}]");
    const audio = "\"input_audio\":{\"data\":\"" ++ mp3_bytes ++ "\",\"format\":\"mp3\"}";
    const cases = [_]struct { []const u8, []const u8, fixtures.Options }{
        .{ "{\"model\":\"openai/gpt-transcribe\"," ++ audio ++ ",\"response_format\":\"verbose_json\"}", "The model openai/gpt-transcribe does not answer in verbose_json: its octoii.response_formats list json", with },
        .{ "{\"model\":\"openai/gpt-transcribe\"," ++ audio ++ ",\"diarize\":true}", "does not tell speakers apart", with },
        .{ "{\"model\":\"openai/whisper-1\"," ++ audio ++ ",\"response_format\":\"verbose_json\",\"diarize\":true}", "OpenAI's transcription API takes no diarize", told },
        .{ "{\"model\":\"openai/gpt-transcribe\"," ++ audio ++ ",\"provider\":{\"data_collection\":\"deny\"}}", "OpenAI's transcription API takes no provider data_collection: its provider takes options alone", with },
        .{ "{\"model\":\"openai/gpt-transcribe\",\"input_audio\":{\"url\":\"http://example.com/a.mp3\"}}", "not https", with },
    };
    for (cases) |case| {
        var nothing: foundation.replay.Replay = .init(a, &.{});
        try expectMessage((try transcribed(a, case[0], nothing.http(), case[2])).failed, case[1]);
        try std.testing.expectEqual(@as(usize, 0), nothing.sent.items.len);
    }
    const limited = try fixtures.transcriptions(a, "transcription-rate-limited", with);
    try fixtures.expectJson(a,
        \\[{"type":"error","error":{"code":"rate_limit_exceeded","message":"Rate limit reached for gpt-transcribe on requests per min (RPM): Limit 5000, Used 5000, Requested 1.","octoii":{"kind":"rate_limit","retryable":true,"retry_after_ms":1500,"status":429}}}]
    , try foundation.json.encode(a, limited.events));
}

const voices = vocabulary.voices;

test "OpenAI makes and removes a voice for the account from a sample and a consent it recorded, each as a form" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const voice_fixture = try foundation.json.decode(fixtures.MediaFixture(voices.VoiceCreateParams), a, try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/fixtures/openai/voice.json", a, .limited(1 << 20)));
    var replay: foundation.replay.Replay = .init(a, voice_fixture.exchanges);
    const models = try fixtures.modelsOver(a, replay.http(), options);
    const voice = (try models.createVoice(a, voice_fixture.request)).made;
    try std.testing.expectEqualStrings("voice_1234", voice.id);
    try std.testing.expectEqualStrings("openai", voice.octoii.provider);
    try std.testing.expect((try models.deleteVoice(a, voice)) == .made);
    try std.testing.expectEqual(null, replay.mismatch);
    try std.testing.expectEqual(@as(usize, 0), replay.unused().len);
    const consent_fixture = try foundation.json.decode(fixtures.MediaFixture(voices.VoiceConsentCreateParams), a, try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test/fixtures/openai/voice-consent.json", a, .limited(1 << 20)));
    var consents: foundation.replay.Replay = .init(a, consent_fixture.exchanges);
    const recording = try fixtures.modelsOver(a, consents.http(), options);
    const consent = (try recording.createVoiceConsent(a, consent_fixture.request)).made;
    try std.testing.expectEqualStrings("cons_1234", consent.id);
    try std.testing.expectEqual(null, consents.mismatch);
    var nothing: foundation.replay.Replay = .init(a, &.{});
    const idle = try fixtures.modelsOver(a, nothing.http(), options);
    const unknown = (try idle.createVoice(a, .{ .name = "N", .audio_sample = .{ .inline_data = .{ .data = "UklGRg==", .format = "wav" } }, .octoii = .{ .provider = "elsewhere" } })).failed;
    try expectMessage(unknown, "No provider elsewhere is among the host's providers");
    const routed = (try idle.createVoice(a, .{ .name = "N", .audio_sample = .{ .inline_data = .{ .data = "UklGRg==", .format = "wav" } }, .provider = .{ .zdr = true }, .octoii = .{ .provider = "openai" } })).failed;
    try expectMessage(routed, "OpenAI's voices API takes no provider zdr");
    try std.testing.expectEqual(@as(usize, 0), nothing.sent.items.len);
}
