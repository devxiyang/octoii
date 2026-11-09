//! xAI's media kinds against their recorded exchanges and what their requests become on the wire.
const std = @import("std");
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const FailureKind = vocabulary.FailureKind;
const seam = @import("../driver.zig");
const fixtures = @import("../testing/fixtures.zig");
const TestHost = @import("../testing/host.zig").Host;
const now_ms = @import("../testing/host.zig").now_ms;
const xai = @import("xai.zig");
const images = @import("xai/images.zig");

/// The provider of xAI, with its host's models.
fn optionsOf(arena: std.mem.Allocator) !fixtures.Options {
    return .{ .driver = &xai.driver, .key = "xai-test", .models = try @import("../testing/host_models.zig").xai(arena) };
}

/// A tiny PNG and GIF.
const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
const gif = "R0lGODlhAQABAAAAACw=";

const Outcome = @import("../media/stream.zig").Outcome(vocabulary.images.ImageResponse);

fn generated(arena: std.mem.Allocator, request: []const u8, http: foundation.http.Http) !Outcome {
    const models = try fixtures.modelsOver(arena, http, try optionsOf(arena));
    return models.generateImages(arena, try foundation.json.decode(vocabulary.images.ImageRequest, arena, request));
}

test "every recorded image exchange of xAI's is sent as recorded, each image completed and priced at xAI's cost" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const options = try optionsOf(arena);
    try std.testing.expectEqual(@as(usize, 3), (try fixtures.mediaNames(arena, "xai", "image")).len);
    for (try fixtures.mediaNames(arena, "xai", "image")) |name| {
        errdefer std.debug.print("xai/{s}\n", .{name});
        _ = try fixtures.images(arena, name, options);
    }
    const made = try fixtures.images(arena, "image", options);
    try std.testing.expectEqual(@as(usize, 2), made.events.len);
    try std.testing.expectEqualStrings("image/png", made.events[0].completed.media_type.?);
    try std.testing.expectEqual(@divFloor(now_ms, 1000), made.events[0].completed.created);
    const last = made.events[1].completed;
    try std.testing.expectEqual(@as(u64, 110), last.usage.?.total_tokens);
    try std.testing.expectEqual(@as(?f64, 0.08), last.usage.?.cost);
    try fixtures.expectUsage(.{ .images_made = 2, .cost = 0.08 }, last.octoii.?.usage.?);
    const edited = try fixtures.images(arena, "image-edit", options);
    try std.testing.expectEqualStrings("https://api.x.ai/v1/images/edits", edited.replay.sent.items[0].url);
    try std.testing.expectEqualStrings("image/jpeg", edited.events[0].completed.media_type.?);
    try fixtures.expectUsage(.{ .images_made = 1, .images_read = 1, .cost = 0.04 }, edited.events[0].completed.octoii.?.usage.?);
    const limited = (try fixtures.images(arena, "image-rate-limited", options)).failure.?;
    try std.testing.expectEqual(FailureKind.rate_limit, limited.kind);
    try std.testing.expectEqual(@as(?u64, 20_000), limited.retry_after_ms);
    try std.testing.expectEqual(@as(?u16, 429), limited.status);
}

test "xAI is sent several references as images and its options among the fields, and prices by the catalogue without a cost" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const model = try fixtures.catalogueModel(arena, "xai", "grok-imagine-image-2.0");
    const provider: seam.Provider = .{ .id = "xai", .name = "xAI", .driver = &xai.driver };
    var test_host: TestHost = .{};
    var nothing: foundation.replay.Replay = .init(arena, &.{});
    const host = test_host.host(nothing.http());
    var call: seam.Call = .{ .arena = arena, .provider = &provider, .host = &host };
    const request = try foundation.json.decode(vocabulary.images.ImageRequest, arena,
        \\{"model":"xai/grok-imagine-image-2.0","prompt":"Put <IMAGE_0> in <IMAGE_1>","input_references":[{"type":"image_url","image_url":{"url":"https://a.example/1.png"}},
    ++ "{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64," ++ png ++ "\"}}],\"provider\":{\"options\":{\"xai\":{\"storage_options\":{\"filename\":\"out.jpg\"}}}}}");
    const wire = try images.wireRequest(&call, &model, request);
    try std.testing.expectEqualStrings("/images/edits", wire.path);
    try fixtures.expectJson(arena, "{\"model\":\"grok-imagine-image-2.0\",\"prompt\":\"Put <IMAGE_0> in <IMAGE_1>\",\"images\":[{\"url\":\"https://a.example/1.png\"},{\"url\":\"data:image/png;base64," ++ png ++ "\"}],\"storage_options\":{\"filename\":\"out.jpg\"},\"response_format\":\"b64_json\"}", wire.body);
    var answering: fixtures.Answering = .{ .arena = arena, .chunks = &.{"{\"data\":[{\"b64_json\":\"" ++ png ++ "\"}]}"}, .content_type = "application/json" };
    const response = (try generated(arena, "{\"model\":\"xai/grok-imagine-image\",\"prompt\":\"A fox\"}", answering.http())).made;
    try fixtures.expectUsage(.{ .images_made = 1, .cost = 0.02 }, response.octoii.?.usage.?);
}

test "xAI's images fail before anything is sent for a setting, routing or an image it does not take" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const six = "{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64," ++ png ++ "\"}}";
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"model\":\"xai/grok-imagine-image\",\"prompt\":\"A fox\",\"quality\":\"low\"}", "does not take quality" },
        .{ "{\"model\":\"xai/grok-imagine-image-2.0\",\"prompt\":\"A fox\",\"input_references\":[" ++ six ++ "," ++ six ++ "," ++ six ++ "," ++ six ++ "," ++ six ++ "," ++ six ++ "]}", "does not take the input_references 6" },
        .{ "{\"model\":\"xai/grok-imagine-image\",\"prompt\":\"A fox\",\"provider\":{\"zdr\":true}}", "xAI's image API takes no provider zdr" },
        .{ "{\"model\":\"xai/grok-imagine-image\",\"prompt\":\"Like this\",\"input_references\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/gif;base64," ++ gif ++ "\"}}]}", "is image/gif, and xAI reads images of image/png, image/jpeg, image/webp alone" },
    };
    for (cases) |case| {
        var nothing: foundation.replay.Replay = .init(arena, &.{});
        const failure = (try generated(arena, case[0], nothing.http())).failed;
        try std.testing.expectEqual(FailureKind.invalid_request, failure.kind);
        if (std.mem.indexOf(u8, failure.message, case[1]) == null) {
            std.debug.print("{s}: {s}\n", .{ case[1], failure.message });
            return error.TestUnexpectedMessage;
        }
        try std.testing.expectEqual(@as(usize, 0), nothing.sent.items.len);
    }
}

const SpeechOutcome = @import("../media/stream.zig").Outcome(vocabulary.speech.SpeechResponse);

fn spoken(arena: std.mem.Allocator, request: []const u8, http: foundation.http.Http) !SpeechOutcome {
    const models = try fixtures.modelsOver(arena, http, try optionsOf(arena));
    return models.createSpeech(arena, try foundation.json.decode(vocabulary.speech.SpeechRequest, arena, request));
}

test "xAI's speech streams the audio's bytes, priced by the characters, PCM at 24 kHz in a voice made for the account" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const options = try optionsOf(arena);
    for (try fixtures.mediaNames(arena, "xai", "speech")) |name| _ = try fixtures.speech(arena, name, options);
    const streamed = try fixtures.speech(arena, "speech", options);
    try std.testing.expectEqual(@as(usize, 3), streamed.events.len);
    try std.testing.expectEqualStrings("audio/mpeg", streamed.events[0].delta.octoii.media_type);
    const characters: u64 = "Hello! Welcome to the Text to Speech API.".len;
    try fixtures.expectUsage(.{ .characters = characters, .cost = @as(f64, @floatFromInt(characters)) * 0.000015 }, streamed.events[2].done.octoii.?.usage.?);
    const pcm = try fixtures.speech(arena, "speech-pcm", options);
    try std.testing.expectEqualStrings("audio/pcm;rate=24000", pcm.events[0].delta.octoii.media_type);
    try std.testing.expectEqual(@as(?u64, 17), pcm.events[pcm.events.len - 1].done.octoii.?.usage.?.characters);
}

test "xAI is sent no model for speech, a voice made for the account by its id, and refuses what it does not take" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var answering: fixtures.Answering = .{ .arena = arena, .chunks = &.{"ID3"}, .content_type = "audio/mpeg" };
    _ = try spoken(arena, "{\"model\":\"xai/grok-voice-tts-1.0\",\"input\":\"Hi\"}", answering.http());
    try fixtures.expectJson(arena, "{\"text\":\"Hi\",\"language\":\"auto\"}", answering.sent.items[0].body.?);
    var voiced: fixtures.Answering = .{ .arena = arena, .chunks = &.{"ID3"}, .content_type = "audio/mpeg" };
    _ = try spoken(arena, "{\"model\":\"xai/grok-voice-tts-1.0\",\"input\":\"Hi\",\"voice\":{\"id\":\"nlbqfwie\"}}", voiced.http());
    try std.testing.expect(std.mem.indexOf(u8, voiced.sent.items[0].body.?, "\"voice_id\":\"nlbqfwie\"") != null);
    const long = try arena.alloc(u8, 60_001);
    @memset(long, 'a');
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"model\":\"xai/grok-voice-tts-1.0\",\"input\":\"Hi\",\"voice\":\"alloy\"}", "has no voice \"alloy\"" },
        .{ "{\"model\":\"xai/grok-voice-tts-1.0\",\"input\":\"Hi\",\"instructions\":\"warmly\"}", "takes no instructions on how to speak" },
        .{ "{\"model\":\"xai/grok-voice-tts-1.0\",\"input\":[{\"text\":\"Hi\",\"voice\":\"eve\"},{\"text\":\"Hello\",\"voice\":\"rex\"}]}", "xAI speaks text in one voice" },
        .{ "{\"model\":\"xai/grok-voice-tts-1.0\",\"input\":\"Hi\",\"speed\":2}", "xAI speaks at a speed of 0.7 to 1.5" },
        .{ try arena.print("{{\"model\":\"xai/grok-voice-tts-1.0\",\"input\":\"{s}\"}}", .{long}), "xAI speaks at most 60000 characters a request" },
        .{ "{\"model\":\"xai/grok-voice-tts-1.0\",\"input\":\"Hi\",\"input_references\":[{\"type\":\"input_audio\",\"input_audio\":{\"data\":\"UklGRg==\",\"format\":\"wav\"}}]}", "xAI's speech takes no samples" },
        .{ "{\"model\":\"xai/grok-voice-tts-1.0\",\"input\":\"Hi\",\"provider\":{\"options\":{\"xai\":{\"with_timestamps\":true}}}}", "with_timestamps" },
        .{ "{\"model\":\"xai/grok-voice-tts-1.0\",\"input\":\"Hi\",\"provider\":{\"zdr\":true}}", "xAI's speech API takes no provider zdr" },
    };
    for (cases) |case| {
        var nothing: foundation.replay.Replay = .init(arena, &.{});
        const failure = (try spoken(arena, case[0], nothing.http())).failed;
        if (std.mem.indexOf(u8, failure.message, case[1]) == null) {
            std.debug.print("{s}: {s}\n", .{ case[1], failure.message });
            return error.TestUnexpectedMessage;
        }
        try std.testing.expectEqual(@as(usize, 0), nothing.sent.items.len);
    }
}

const transcriptions = vocabulary.transcriptions;

test "xAI's transcription sends the recording last in a form, and gives the text with the seconds it heard, priced by the second" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const options = try optionsOf(arena);
    for (try fixtures.mediaNames(arena, "xai", "transcription")) |name| _ = try fixtures.transcriptions(arena, name, options);
    const Models = @import("../Models.zig");
    const response = (try fixtures.created(transcriptions.TranscriptionRequest, Models.createTranscription, arena, "transcription", options)).made;
    try std.testing.expectEqualStrings("The balance is $167,983.15.", response.text);
    try std.testing.expectEqual(null, response.words);
    try fixtures.expectUsage(.{ .seconds = 3.45, .cost = (3.45 * 0.1) / 3600.0 }, response.octoii.?.usage.?);
    const diarized = (try fixtures.created(transcriptions.TranscriptionRequest, Models.createTranscription, arena, "transcription-diarized", options)).made;
    try std.testing.expectEqualStrings("en", diarized.language.?);
    try std.testing.expectEqual(@as(?f64, 2.4), diarized.duration);
    try fixtures.expectJson(arena, "{\"word\":\"Is\",\"type\":\"word\",\"start\":0.1,\"end\":0.22,\"speaker\":0,\"confidence\":0.91}", try foundation.json.encode(arena, diarized.words.?[0]));
    try std.testing.expectEqual(@as(?f64, 1), diarized.words.?[3].speaker);
}

test "xAI's transcription names a raw recording's format with its rate, and refuses what xAI does not take" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var answering: fixtures.Answering = .{ .arena = arena, .chunks = &.{"{\"text\":\"Hi\"}"}, .content_type = "application/json" };
    const models = try fixtures.modelsOver(arena, answering.http(), try optionsOf(arena));
    _ = try models.createTranscription(arena, try foundation.json.decode(transcriptions.TranscriptionRequest, arena, "{\"model\":\"xai/grok-voice-transcribe-2.0\",\"input_audio\":{\"data\":\"AAAA\",\"format\":\"pcm\"},\"provider\":{\"options\":{\"xai\":{\"sample_rate\":16000}}}}"));
    const sent = answering.sent.items[0];
    const form = (try foundation.multipart.parse(arena, foundation.http.find(sent.headers, "content-type").?, sent.body.?)).?;
    try std.testing.expectEqual(@as(usize, 4), form.len);
    try std.testing.expectEqualStrings("grok-voice-transcribe-2.0", form[0].value.?);
    try std.testing.expectEqualStrings("pcm", form[1].value.?);
    try std.testing.expectEqualStrings("sample_rate", form[2].name);
    try std.testing.expectEqualStrings("16000", form[2].value.?);
    try std.testing.expectEqualStrings("audio.pcm", form[3].filename.?);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"model\":\"xai/grok-voice-transcribe-2.0\",\"input_audio\":{\"data\":\"UklGRg==\",\"format\":\"wav\"},\"temperature\":0.2}", "takes no temperature" },
        .{ "{\"model\":\"xai/grok-voice-transcribe-2.0\",\"input_audio\":{\"data\":\"UklGRg==\",\"format\":\"wav\"},\"response_format\":\"verbose_json\",\"timestamp_granularities\":[\"segment\"]}", "writes words and no segments" },
        .{ "{\"model\":\"xai/grok-voice-transcribe-2.0\",\"input_audio\":{\"data\":\"AAAA\",\"format\":\"mulaw\"}}", "give its sample_rate in the provider options" },
        .{ "{\"model\":\"xai/grok-voice-transcribe-2.0\",\"input_audio\":{\"data\":\"UklGRg==\",\"format\":\"wav\"},\"provider\":{\"data_collection\":\"deny\"}}", "xAI's transcription API takes no provider data_collection" },
    };
    for (cases) |case| {
        var nothing: foundation.replay.Replay = .init(arena, &.{});
        const refusing = try fixtures.modelsOver(arena, nothing.http(), try optionsOf(arena));
        const failure = (try refusing.createTranscription(arena, try foundation.json.decode(transcriptions.TranscriptionRequest, arena, case[0]))).failed;
        if (std.mem.indexOf(u8, failure.message, case[1]) == null) {
            std.debug.print("{s}: {s}\n", .{ case[1], failure.message });
            return error.TestUnexpectedMessage;
        }
        try std.testing.expectEqual(@as(usize, 0), nothing.sent.items.len);
    }
}
