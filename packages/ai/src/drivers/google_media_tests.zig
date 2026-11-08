//! Google's media kinds against their recorded exchanges and what their requests become on the wire.
const std = @import("std");
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const FailureKind = vocabulary.FailureKind;
const seam = @import("../driver.zig");
const fixtures = @import("../testing/fixtures.zig");
const TestHost = @import("../testing/host.zig").Host;
const google = @import("google.zig");
const images = @import("google/images.zig");

const options: fixtures.Options = .{ .driver = &google.driver, .key = "AIzaSy-test" };

/// A tiny PNG.
const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";

/// When the fixtures' interactions were created: 2026-10-29 12:00:00 UTC.
const created: i64 = 1_793_275_200;

const Outcome = @import("../media/stream.zig").Outcome(vocabulary.images.ImageResponse);

fn generated(a: std.mem.Allocator, request: []const u8, http: foundation.http.Http, with: fixtures.Options) !Outcome {
    const models = try fixtures.modelsOver(a, http, with);
    return models.generateImages(a, try foundation.json.decode(vocabulary.images.ImageRequest, a, request));
}

/// An interaction that makes one image, its `tokens` made.
fn oneImage(a: std.mem.Allocator, tokens: u64) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\data: {{"event_type":"step.start","index":0,"step":{{"type":"model_output"}}}}
        \\
        \\data: {{"event_type":"step.delta","index":0,"delta":{{"type":"image","data":"{s}","mime_type":"image/png"}}}}
        \\
        \\data: {{"event_type":"interaction.completed","interaction":{{"status":"completed","usage":{{"total_input_tokens":4,"total_output_tokens":{d},"output_tokens_by_modality":[{{"modality":"image","tokens":{d}}}]}}}}}}
        \\
        \\
    , .{ png, tokens, tokens });
}

/// A model of the catalogue's Nano Banana, as a host passes it without the settings it takes.
const host_options: fixtures.Options = .{ .driver = &google.driver, .key = "AIzaSy-test", .models = &.{.{
    .id = "gemini-nano-banana-host",
    .architecture = .{ .input_modalities = &.{ .text, .image }, .output_modalities = &.{ .text, .image } },
    .octoii = .{ .kinds = &.{.image} },
}} };

test "every recorded image exchange of Google's is sent as recorded, a thought's image a preview and its text reasoning" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqual(@as(usize, 4), (try fixtures.mediaNames(a, "google", "image")).len);
    for (try fixtures.mediaNames(a, "google", "image")) |name| {
        errdefer std.debug.print("google/{s}\n", .{name});
        _ = try fixtures.images(a, name, options);
    }
    const made = try fixtures.images(a, "image", options);
    try std.testing.expectEqual(@as(usize, 3), made.events.len);
    try std.testing.expectEqual(.reasoning, made.events[0].text_chunk.phase);
    try std.testing.expectEqual(@as(u32, 0), made.events[1].partial_image.partial_image_index);
    const completed = made.events[2].completed;
    try std.testing.expectEqualStrings("image/png", completed.media_type.?);
    try std.testing.expectEqual(created, completed.created);
    try fixtures.expectJson(a, "{\"prompt_tokens\":12,\"completion_tokens\":1300,\"total_tokens\":1312,\"completion_tokens_details\":{\"image_tokens\":1120,\"reasoning_tokens\":180}}", try foundation.json.encode(a, completed.usage.?));
    // Nano Banana 2.1: $1.50 a million tokens read, $7.50 written and $30 of images made.
    try fixtures.expectUsage(.{ .input = 12, .output = 180, .reasoning = 180, .output_image = 1120, .cost = 12 * 0.0000015 + 180 * 0.0000075 + 1120 * 0.00003 }, completed.octoii.?.usage.?);
    const followed = try fixtures.images(a, "image-reference", options);
    try fixtures.expectJson(a, "{\"type\":\"image_generation.text_chunk\",\"text\":\"Here is your cat.\",\"phase\":\"content\"}", try foundation.json.encode(a, followed.events[0]));
    const cat = followed.events[1].completed;
    try std.testing.expectEqualStrings("image/jpeg", cat.media_type.?);
    try fixtures.expectUsage(.{ .input = 270, .output = 5, .output_image = 1290, .cost = 270 * 0.00000025 + 5 * 0.0000015 + 1290 * 0.00003 }, cat.octoii.?.usage.?);
}

test "Google is asked for an image at an address by its uri, with the seed, and nothing else" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const model = try fixtures.catalogueModel(a, "google", "gemini-nano-banana-2.1");
    const provider: seam.Provider = .{ .id = "google", .name = "Google", .driver = &google.driver };
    var test_host: TestHost = .{};
    var nothing: foundation.replay.Replay = .init(a, &.{});
    const host = test_host.host(nothing.http());
    var call: seam.Call = .{ .arena = a, .provider = &provider, .host = &host };
    const request = try foundation.json.decode(vocabulary.images.ImageRequest, a, "{\"model\":\"google/gemini-nano-banana-2.1\",\"prompt\":\"Like this\",\"seed\":7,\"input_references\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\"https://example.com/cat.png\"}}]}");
    try fixtures.expectJson(a,
        \\{"model":"gemini-nano-banana-2.1","input":[{"type":"text","text":"Like this"},{"type":"image","uri":"https://example.com/cat.png","mime_type":"image/png"}],
        \\ "response_format":{"type":"image"},"generation_config":{"seed":7},"store":false,"stream":true}
    , try images.wireRequest(&call, &model, request));
}

test "Google is sent a request for n images n times, their usage added, and its own options over the body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var answering: fixtures.Answering = .{ .arena = a, .chunks = try a.dupe([]const u8, &.{try oneImage(a, 1290)}) };
    const response = (try generated(a, "{\"model\":\"google/gemini-nano-banana-host\",\"prompt\":\"A banana\",\"n\":2}", answering.http(), host_options)).made;
    try std.testing.expectEqual(@as(usize, 2), answering.sent.items.len);
    try std.testing.expectEqual(@as(usize, 2), response.data.len);
    try std.testing.expectEqual(@as(u64, 8), response.usage.?.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 2580), response.usage.?.completion_tokens);
    var optioned: fixtures.Answering = .{ .arena = a, .chunks = try a.dupe([]const u8, &.{try oneImage(a, 1)}) };
    _ = try generated(a, "{\"model\":\"google/gemini-nano-banana-2.1\",\"prompt\":\"A banana\",\"provider\":{\"options\":{\"google\":{\"response_format\":{\"mime_type\":\"image/jpeg\"},\"store\":true}}}}", optioned.http(), options);
    const body = try std.json.parseFromSliceLeaky(std.json.Value, a, optioned.sent.items[0].body.?, .{});
    try fixtures.expectJson(a, "{\"type\":\"image\",\"mime_type\":\"image/jpeg\"}", try foundation.json.encode(a, body.object.get("response_format").?));
    try std.testing.expectEqual(false, body.object.get("store").?.bool);
}

test "Google's images end with its error classified, an interaction that failed, or one without an image" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const broken = try fixtures.images(a, "image-stream-error", options);
    const raised = broken.events[broken.events.len - 1].@"error".@"error";
    try std.testing.expectEqualStrings("rate_limit_exceeded", raised.code);
    try std.testing.expectEqual(FailureKind.rate_limit, raised.octoii.kind);
    try std.testing.expect(raised.octoii.retryable);
    const failed = (try fixtures.images(a, "image-failed", options)).failure.?;
    try std.testing.expectEqual(FailureKind.invalid_request, failed.kind);
    try std.testing.expectEqualStrings("invalid_request", failed.code.?);
    try std.testing.expectEqualStrings("The prompt could not be processed.", failed.message);
    var empty: fixtures.Answering = .{ .arena = a, .chunks = &.{"data: {\"event_type\":\"interaction.completed\",\"interaction\":{\"status\":\"completed\",\"usage\":{\"total_input_tokens\":4}}}\n\n"} };
    const imageless = (try generated(a, "{\"model\":\"google/gemini-nano-banana-2.1\",\"prompt\":\"A banana\"}", empty.http(), options)).failed;
    try std.testing.expectEqual(FailureKind.invalid_response, imageless.kind);
    try std.testing.expectEqualStrings("The interaction completed without an image", imageless.message);
}

test "Google's images fail before anything is sent for a setting it does not take, and send a stored reference inline" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cases = [_]struct { []const u8, []const u8, fixtures.Options }{
        .{ "{\"model\":\"google/gemini-nano-banana-host\",\"prompt\":\"A banana\",\"quality\":\"high\"}", "cannot take quality: Google does not offer it", host_options },
        .{ "{\"model\":\"google/gemini-nano-banana-2.1\",\"prompt\":\"A banana\",\"provider\":{\"sort\":\"price\"}}", "Google takes no routing preferences, such as sort", options },
        .{ "{\"model\":\"google/gemini-nano-banana-2.1\",\"prompt\":\"A banana\",\"n\":2}", "does not take n", options },
    };
    for (cases) |case| {
        var nothing: foundation.replay.Replay = .init(a, &.{});
        const failure = (try generated(a, case[0], nothing.http(), case[2])).failed;
        if (std.mem.indexOf(u8, failure.message, case[1]) == null) {
            std.debug.print("{s}: {s}\n", .{ case[1], failure.message });
            return error.TestUnexpectedMessage;
        }
        try std.testing.expectEqual(@as(usize, 0), nothing.sent.items.len);
    }
    const decoder = std.base64.standard.Decoder;
    const bytes = try a.alloc(u8, try decoder.calcSizeForSlice(png));
    try decoder.decode(bytes, png);
    var with = options;
    with.stored = &.{.{ .ref = "blob:1", .bytes = bytes }};
    var answering: fixtures.Answering = .{ .arena = a, .chunks = try a.dupe([]const u8, &.{try oneImage(a, 1)}) };
    _ = try generated(a, "{\"model\":\"google/gemini-nano-banana-2.1\",\"prompt\":\"Like this\",\"input_references\":[{\"type\":\"image_url\",\"image_url\":{},\"octoii\":{\"ref\":\"blob:1\"}}]}", answering.http(), with);
    const sent = answering.sent.items[0].body.?;
    try std.testing.expect(std.mem.indexOf(u8, sent, "{\"type\":\"image\",\"data\":\"" ++ png ++ "\",\"mime_type\":\"image/png\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "octoii") == null);
}

const SpeechOutcome = @import("../media/stream.zig").Outcome(vocabulary.speech.SpeechResponse);

fn spoken(a: std.mem.Allocator, request: []const u8, http: foundation.http.Http) !SpeechOutcome {
    const models = try fixtures.modelsOver(a, http, options);
    return models.createSpeech(a, try foundation.json.decode(vocabulary.speech.SpeechRequest, a, request));
}

/// An interaction that speaks a little PCM.
const spoken_chunks: []const []const u8 = &.{"data: {\"event_type\":\"step.start\",\"index\":0,\"step\":{\"type\":\"model_output\"}}\n\ndata: {\"event_type\":\"step.delta\",\"index\":0,\"delta\":{\"type\":\"audio\",\"data\":\"AAAA\",\"mime_type\":\"audio/l16\"}}\n\ndata: {\"event_type\":\"interaction.completed\",\"interaction\":{\"status\":\"completed\"}}\n\n"};

test "Google's speech streams PCM at the rate its deltas name, priced by its tokens, and a dialogue as two speakers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for (try fixtures.mediaNames(a, "google", "speech")) |name| _ = try fixtures.speech(a, name, options);
    const streamed = try fixtures.speech(a, "speech", options);
    try std.testing.expectEqual(@as(usize, 3), streamed.events.len);
    try std.testing.expectEqualStrings("audio/pcm;rate=24000", streamed.events[0].delta.octoii.media_type);
    const done = streamed.events[2].done;
    try fixtures.expectJson(a, "{\"input_tokens\":9,\"output_tokens\":75,\"total_tokens\":84}", try foundation.json.encode(a, done.usage.?));
    // Gemini 3.8 Flash TTS: $0.50 a million tokens of text read and $9 of audio made; the characters only describe it.
    try fixtures.expectUsage(.{ .characters = 21, .input = 9, .output = 75, .cost = 9 * 0.0000005 + 75 * 0.000009 }, done.octoii.?.usage.?);
    const dialogue = try fixtures.speech(a, "speech-dialogue", options);
    try std.testing.expectEqualStrings("audio/mpeg", dialogue.events[0].delta.octoii.media_type);
    try std.testing.expectApproxEqAbs(21 * 0.0000005 + 160 * 0.000006, dialogue.events[dialogue.events.len - 1].done.octoii.?.usage.?.cost.?, 1e-12);
    const limited = (try fixtures.speech(a, "speech-rate-limited", options)).failure.?;
    try std.testing.expectEqual(FailureKind.rate_limit, limited.kind);
    try std.testing.expectEqual(@as(?u16, 429), limited.status);
    try std.testing.expectEqualStrings("rate_limit_exceeded", limited.code.?);
}

test "Google is given a voice made for the account by its id, one voice for every turn, none where none is named" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var answering: fixtures.Answering = .{ .arena = a, .chunks = spoken_chunks };
    _ = try spoken(a, "{\"model\":\"google/gemini-3.8-flash-tts\",\"voice\":{\"id\":\"voice_abc\"},\"input\":[{\"text\":\"One.\"},{\"text\":\"Two.\"}]}", answering.http());
    const body = try std.json.parseFromSliceLeaky(std.json.Value, a, answering.sent.items[0].body.?, .{});
    try fixtures.expectJson(a, "{\"speech_config\":[{\"voice\":\"voice_abc\"}]}", try foundation.json.encode(a, body.object.get("generation_config").?));
    try fixtures.expectJson(a, "[{\"type\":\"user_input\",\"content\":[{\"type\":\"text\",\"text\":\"One.\"},{\"type\":\"text\",\"text\":\"Two.\"}]}]", try foundation.json.encode(a, body.object.get("input").?));
    var bare: fixtures.Answering = .{ .arena = a, .chunks = spoken_chunks };
    _ = try spoken(a, "{\"model\":\"google/gemini-3.8-flash-tts\",\"input\":\"Hi\"}", bare.http());
    try std.testing.expect(std.mem.indexOf(u8, bare.sent.items[0].body.?, "generation_config") == null);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"model\":\"google/gemini-3.8-flash-tts\",\"input\":\"Hi\",\"speed\":1.5}", "cannot take speed" },
        .{ "{\"model\":\"google/gemini-3.8-flash-tts\",\"input\":[{\"text\":\"A\",\"voice\":\"Kore\"},{\"text\":\"B\",\"voice\":\"Puck\"},{\"text\":\"C\",\"voice\":\"Zephyr\"}]}", "speaks in at most 2 voices a request, and the turns ask for 3" },
        .{ "{\"model\":\"google/gemini-3.8-flash-tts\",\"input\":[{\"text\":\"A\",\"voice\":\"Kore\"},{\"text\":\"B\",\"voice\":\"Puck\"},{\"text\":\"C\"}]}", "Each turn names its voice" },
        .{ "{\"model\":\"google/gemini-3.8-flash-tts\",\"input\":\"Hi\",\"provider\":{\"zdr\":true}}", "cannot take a data policy" },
        .{ "{\"model\":\"google/gemini-3.8-flash-tts\",\"input\":\"Hi\",\"voice\":\"alloy\"}", "has no voice \"alloy\"" },
    };
    for (cases) |case| {
        var nothing: foundation.replay.Replay = .init(a, &.{});
        const failure = (try spoken(a, case[0], nothing.http())).failed;
        if (std.mem.indexOf(u8, failure.message, case[1]) == null) {
            std.debug.print("{s}: {s}\n", .{ case[1], failure.message });
            return error.TestUnexpectedMessage;
        }
        try std.testing.expectEqual(@as(usize, 0), nothing.sent.items.len);
    }
}
