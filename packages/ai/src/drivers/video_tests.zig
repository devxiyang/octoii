//! OpenRouter's and xAI's video jobs against their recorded exchanges: made, waited for on the host's clock and
//! downloaded, and what their requests become on the wire.
const std = @import("std");
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const videos = vocabulary.videos;
const FailureKind = vocabulary.FailureKind;
const seam = @import("../driver.zig");
const Models = @import("../Models.zig");
const fixtures = @import("../testing/fixtures.zig");
const TestHost = @import("../testing/host.zig").Host;
const now_ms = @import("../testing/host.zig").now_ms;
const media_videos = @import("../media/videos.zig");
const openrouter = @import("openrouter.zig");
const xai = @import("xai.zig");

/// A tiny PNG.
const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";

const openrouter_options: fixtures.Options = .{ .driver = &openrouter.driver, .key = "sk-or-v1-test" };

fn xaiOptions(arena: std.mem.Allocator) !fixtures.Options {
    return .{ .driver = &xai.driver, .key = "xai-test", .models = try @import("../testing/host_models.zig").xai(arena) };
}

/// The fixture `name`'s exchanges replayed: its request, `Models` over them, the replay and the test host.
const Replayed = struct { request: videos.VideoRequest, models: *Models, replay: *foundation.replay.Replay, host: *TestHost, exchanges: usize };

fn replayed(arena: std.mem.Allocator, name: []const u8, options: fixtures.Options) !Replayed {
    const path = try arena.print("test/fixtures/{s}/{s}.json", .{ options.driver.id, name });
    const fixture = try foundation.json.decode(fixtures.MediaFixture(videos.VideoRequest), arena, try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(4 << 20)));
    const replay = try arena.create(foundation.replay.Replay);
    replay.* = .init(arena, fixture.exchanges);
    const host = try arena.create(TestHost);
    host.* = .{ .keys = try arena.dupe(@typeInfo(@FieldType(TestHost, "keys")).pointer.child, &.{.{ .provider = options.driver.id, .key = options.key.? }}) };
    const providers = try arena.dupe(seam.Provider, &.{.{ .id = options.driver.id, .name = options.driver.id, .driver = options.driver, .models = options.models }});
    const models = try Models.init(arena, .{ .providers = providers, .host = host.host(replay.http()) });
    return .{ .request = fixture.request, .models = models, .replay = replay, .host = host, .exchanges = fixture.exchanges.len };
}

fn expectContains(text: []const u8, words: []const u8) !void {
    if (std.mem.indexOf(u8, text, words) != null) return;
    std.debug.print("{s}: {s}\n", .{ words, text });
    return error.TestUnexpectedMessage;
}

test "every recorded video job is made, waited for and downloaded as recorded, the key going to the provider's API alone" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    for ([_]fixtures.Options{ openrouter_options, try xaiOptions(arena) }) |options| for (try fixtures.mediaNames(arena, options.driver.id, "video")) |name| {
        errdefer std.debug.print("{s}/{s}\n", .{ options.driver.id, name });
        const played = try replayed(arena, name, options);
        const waited = try played.models.createAndPollVideo(arena, played.request);
        if (waited == .ended and waited.ended.status == .completed) _ = try played.models.downloadVideo(arena, waited.ended, 0);
        try std.testing.expectEqual(null, played.replay.mismatch);
        try std.testing.expectEqual(@as(usize, 0), played.replay.unused().len);
        for (played.replay.sent.items) |sent| {
            const api = std.mem.startsWith(u8, sent.url, "https://openrouter.ai/") or std.mem.startsWith(u8, sent.url, "https://api.x.ai/");
            try std.testing.expectEqual(api, foundation.http.find(sent.headers, "authorization") != null);
            if (sent.body) |body| try std.testing.expect(std.mem.indexOf(u8, body, "octoii") == null);
        }
    };
}

test "OpenRouter's video is a job retrieved every ten seconds until it completes, priced by its SKUs and then by OpenRouter" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const played = try replayed(arena, "video", openrouter_options);
    const created = (try played.models.createVideo(arena, played.request)).made;
    try std.testing.expectEqual(videos.VideoJobStatus.pending, created.status);
    try std.testing.expectEqualStrings("openrouter/alibaba/wan-3.0", created.octoii.model);
    try fixtures.expectUsage(.{ .seconds = 5, .cost = 0.5 }, created.octoii.usage.?);
    const fresh = try replayed(arena, "video", openrouter_options);
    const job = (try fresh.models.createAndPollVideo(arena, fresh.request)).ended;
    try std.testing.expectEqual(now_ms + @as(i64, @intCast(fresh.exchanges - 2)) * media_videos.check_interval_ms, fresh.host.clock_ms);
    try std.testing.expectEqual(videos.VideoJobStatus.completed, job.status);
    try std.testing.expectEqual(@as(?i64, 1793315140), job.expires_at);
    try fixtures.expectUsage(.{ .seconds = 5, .cost = 0.425 }, job.octoii.usage.?);
    try std.testing.expect(std.mem.indexOf(u8, job.urls.?[0], "X-Goog-Signature=") != null);
    const kept = try foundation.json.decode(videos.VideoJob, arena, try foundation.json.encode(arena, job));
    try fixtures.expectJson(arena, try foundation.json.encode(arena, job), try foundation.json.encode(arena, kept));
    const content = (try fresh.models.downloadVideo(arena, job, 0)).made;
    try std.testing.expectEqualStrings("video/mp4", content.media_type);
    try std.testing.expectEqualStrings("ftyp", content.data[4..8]);
}

test "OpenRouter's video that fails ends the wait classified, and an output it no longer keeps fails to download" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const failed = try replayed(arena, "video-failed", openrouter_options);
    const job = (try failed.models.createAndPollVideo(arena, failed.request)).ended;
    try std.testing.expectEqual(videos.VideoJobStatus.failed, job.status);
    try std.testing.expectEqualStrings("Content policy violation", job.@"error".?);
    try std.testing.expectEqual(FailureKind.content_filter, job.octoii.failure.?.kind);
    // Hailuo's SKUs: 5 seconds, until OpenRouter gives the job's cost.
    try fixtures.expectUsage(.{ .seconds = 5, .cost = 5 * 0.13 }, job.octoii.usage.?);
    const gone = try replayed(arena, "video-gone", openrouter_options);
    const completed = (try gone.models.createVideo(arena, gone.request)).made;
    const refused = (try gone.models.downloadVideo(arena, completed, 0)).failed;
    try std.testing.expectEqual(FailureKind.invalid_request, refused.kind);
    try std.testing.expectEqual(@as(?u16, 410), refused.status);
    try expectContains(refused.message, "OpenRouter no longer keeps the output 0");
}

test "OpenRouter's video waits at most thirty minutes, then fails as timeout carrying the job, and downloads nothing unfinished" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var answering: fixtures.Answering = .{ .arena = arena, .chunks = &.{"{\"id\":\"gen-vid-2\",\"polling_url\":\"x\",\"status\":\"in_progress\"}"}, .status = 202, .content_type = "application/json" };
    const models = try fixtures.modelsOver(arena, answering.http(), openrouter_options);
    const waited = (try models.createAndPollVideo(arena, .{ .model = "openrouter/alibaba/wan-3.0", .prompt = "Rain" })).failed;
    try std.testing.expectEqual(FailureKind.timeout, waited.failure.kind);
    try std.testing.expect(!waited.failure.retryable);
    try std.testing.expectEqualStrings("gen-vid-2", waited.job.?.id);
    try std.testing.expectEqual(videos.VideoJobStatus.in_progress, waited.job.?.status);
    var nothing: foundation.replay.Replay = .init(arena, &.{});
    const idle = try fixtures.modelsOver(arena, nothing.http(), openrouter_options);
    const unfinished = (try idle.downloadVideo(arena, .{ .id = "gen-vid-1", .status = .in_progress, .octoii = .{ .model = "openrouter/alibaba/wan-3.0" } }, 0)).failed;
    try expectContains(unfinished.message, "is in_progress: only a completed job has outputs");
    try std.testing.expectEqual(@as(usize, 0), nothing.sent.items.len);
}

test "OpenRouter's video fails before anything is sent for a setting the model does not list" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"model\":\"openrouter/alibaba/wan-3.0\",\"prompt\":\"Rain\",\"duration\":40}", "does not take the duration 40" },
        .{ "{\"model\":\"openrouter/minimax/hailuo-3\",\"prompt\":\"Rain\",\"seed\":1}", "takes no seed" },
        .{ "{\"model\":\"openrouter/x-ai/grok-imagine-video-1.5\",\"prompt\":\"Rain\",\"frame_images\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64," ++ png ++ "\"},\"frame_type\":\"last_frame\"}]}", "does not take the frame \"last_frame\"" },
        .{ "{\"model\":\"openrouter/alibaba/wan-3.0\",\"prompt\":\"Rain\",\"provider\":{\"options\":{},\"zdr\":true}}", "OpenRouter's video API takes no provider zdr" },
    };
    for (cases) |case| {
        var nothing: foundation.replay.Replay = .init(arena, &.{});
        const models = try fixtures.modelsOver(arena, nothing.http(), openrouter_options);
        try expectContains((try models.createVideo(arena, try foundation.json.decode(videos.VideoRequest, arena, case[0]))).failed.message, case[1]);
        try std.testing.expectEqual(@as(usize, 0), nothing.sent.items.len);
    }
}

test "xAI's video is a job retrieved until it completes, priced by its SKUs and then by xAI, its one output downloaded" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const options = try xaiOptions(arena);
    const played = try replayed(arena, "video", options);
    const created = (try played.models.createVideo(arena, played.request)).made;
    try std.testing.expectEqualStrings("a3d1008e-4544-40d4-d075-11527e794e4a", created.id);
    try fixtures.expectUsage(.{ .seconds = 5, .cost = 5 * 0.08 }, created.octoii.usage.?);
    const running = (try played.models.retrieveVideo(arena, created)).made;
    try std.testing.expectEqual(videos.VideoJobStatus.in_progress, running.status);
    const job = (try played.models.retrieveVideo(arena, running)).made;
    try std.testing.expectEqual(videos.VideoJobStatus.completed, job.status);
    try std.testing.expectEqualStrings("https://vidgen.x.ai/xai-vidgen-bucket/xai-video-a3d1008e-4544-40d4-d075-11527e794e4a.mp4", job.urls.?[0]);
    try std.testing.expectEqual(@as(?f64, 0.4), job.usage.?.cost);
    try fixtures.expectUsage(.{ .seconds = 5, .cost = 0.4 }, job.octoii.usage.?);
    const content = (try played.models.downloadVideo(arena, job, 0)).made;
    try std.testing.expectEqualStrings("video/mp4", content.media_type);
    try std.testing.expectEqualStrings("ftyp", content.data[4..8]);
    var methods: std.ArrayList(u8) = .empty;
    for (played.replay.sent.items) |sent| try methods.append(arena, @tagName(sent.method)[0]);
    try std.testing.expectEqualStrings("PGGGG", methods.items);
    const waited = try replayed(arena, "video", options);
    try std.testing.expectEqual(videos.VideoJobStatus.completed, (try waited.models.createAndPollVideo(arena, waited.request)).ended.status);
    try std.testing.expectEqual(now_ms + 2 * media_videos.check_interval_ms, waited.host.clock_ms);
}

test "xAI's video failures: moderation, its codes, a withheld video, a video no longer kept, and one output a job" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const options = try xaiOptions(arena);
    const failed = try replayed(arena, "video-failed", options);
    const job = (try failed.models.createAndPollVideo(arena, failed.request)).ended;
    try std.testing.expectEqualStrings("invalid_argument: The request was blocked by content moderation.", job.@"error".?);
    try std.testing.expectEqual(FailureKind.content_filter, job.octoii.failure.?.kind);
    try fixtures.expectUsage(.{ .seconds = 4, .cost = 4 * 0.02 }, job.octoii.usage.?);
    const pending: videos.VideoJob = .{ .id = "v-1", .status = .pending, .octoii = .{ .model = "xai/grok-imagine-video" } };
    for ([_]struct { []const u8, videos.VideoJobStatus, ?FailureKind }{
        .{ "{\"status\":\"failed\",\"error\":{\"code\":\"service_unavailable\",\"message\":\"Overloaded\"}}", .failed, .server },
        .{ "{\"status\":\"failed\",\"error\":{\"code\":\"permission_denied\",\"message\":\"No access\"}}", .failed, .forbidden },
        .{ "{\"status\":\"done\",\"video\":{\"url\":\"\",\"duration\":5,\"respect_moderation\":false}}", .failed, .content_filter },
        .{ "{\"status\":\"pending\",\"progress\":0}", .pending, null },
    }) |case| {
        var answering: fixtures.Answering = .{ .arena = arena, .chunks = try arena.dupe([]const u8, &.{case[0]}), .content_type = "application/json" };
        const models = try fixtures.modelsOver(arena, answering.http(), options);
        const now = (try models.retrieveVideo(arena, pending)).made;
        try std.testing.expectEqual(case[1], now.status);
        try std.testing.expectEqual(case[2], if (now.octoii.failure) |failure| failure.kind else null);
    }
    const gone = try replayed(arena, "video-gone", options);
    const completed = (try gone.models.createAndPollVideo(arena, gone.request)).ended;
    const refused = (try gone.models.downloadVideo(arena, completed, 0)).failed;
    try std.testing.expectEqual(FailureKind.invalid_request, refused.kind);
    try std.testing.expectEqual(@as(?u16, 403), refused.status);
    try expectContains(refused.message, "xAI no longer keeps the video of the job");
    var nothing: foundation.replay.Replay = .init(arena, &.{});
    const idle = try fixtures.modelsOver(arena, nothing.http(), options);
    try expectContains((try idle.downloadVideo(arena, .{ .id = "v-2", .status = .completed, .octoii = .{ .model = "xai/grok-imagine-video" } }, 1)).failed.message, "xAI makes one video a job");
    try std.testing.expectEqual(@as(usize, 0), nothing.sent.items.len);
}

test "xAI is sent a video's frames and references in its own fields, and refused what it does not take" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const options = try xaiOptions(arena);
    var answering: fixtures.Answering = .{ .arena = arena, .chunks = &.{"{\"request_id\":\"v-9\"}"}, .content_type = "application/json" };
    const models = try fixtures.modelsOver(arena, answering.http(), options);
    _ = (try models.createVideo(arena, try foundation.json.decode(videos.VideoRequest, arena,
        \\{"model":"xai/grok-imagine-video-1.5","prompt":"<IMAGE_1> walks in, speaking with <AUDIO_0>","duration":8,"resolution":"720p","generate_audio":true,
        \\ "frame_images":[{"type":"image_url","image_url":{"url":"https://a.example/first.png"},"frame_type":"first_frame"},{"type":"image_url","image_url":{"url":"https://a.example/last.png"},"frame_type":"last_frame"}],
        \\ "input_references":[{"type":"image_url","image_url":{"url":"https://a.example/person.png"}},{"type":"audio_url","audio_url":{"url":"https://a.example/voice.wav"}}],
        \\ "user":"user-1","session_id":"s-1","provider":{"options":{"xai":{"keyframes":[{"image":{"url":"https://a.example/mid.png"},"timestamp_s":4}]}}}}
    ))).made;
    try fixtures.expectJson(arena,
        \\{"model":"grok-imagine-video-1.5","prompt":"<IMAGE_1> walks in, speaking with <AUDIO_0>","duration":8,"resolution":"720p",
        \\ "image":{"url":"https://a.example/first.png"},"last_frame":{"url":"https://a.example/last.png"},"reference_images":[{"url":"https://a.example/person.png"}],
        \\ "reference_audios":[{"url":"https://a.example/voice.wav"}],"generate_audio":true,"user":"user-1","keyframes":[{"image":{"url":"https://a.example/mid.png"},"timestamp_s":4}]}
    , answering.sent.items[0].body.?);
    const frame = "{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64," ++ png ++ "\"}";
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"model\":\"xai/grok-imagine-video-1.5-lite\",\"prompt\":\"Rain\",\"frame_images\":[" ++ frame ++ ",\"frame_type\":\"last_frame\"}]}", "does not take the frame \"last_frame\"" },
        .{ "{\"model\":\"xai/grok-imagine-video\",\"prompt\":\"Rain\",\"seed\":1}", "takes no seed" },
        .{ "{\"model\":\"xai/grok-imagine-video\",\"prompt\":\"Rain\",\"size\":\"1280x720\"}", "does not take the size" },
        .{ "{\"model\":\"xai/grok-imagine-video\",\"prompt\":\"Rain\",\"input_references\":[{\"type\":\"audio_url\",\"audio_url\":{\"url\":\"https://a.example/v.wav\"}}]}", "does not read audio" },
        .{ "{\"model\":\"xai/grok-imagine-video\",\"aspect_ratio\":\"1:1\",\"frame_images\":[" ++ frame ++ ",\"frame_type\":\"first_frame\"}]}", "leave aspect_ratio out beside a first frame" },
        .{ "{\"model\":\"xai/grok-imagine-video\",\"prompt\":\"On\",\"previous_job_id\":\"v-0\"}", "continues no job" },
        .{ "{\"model\":\"xai/grok-imagine-video\",\"prompt\":\"Rain\",\"callback_url\":\"https://host.example/done\"}", "xAI tells no address when a video job ends" },
        .{ "{\"model\":\"xai/grok-imagine-video\",\"prompt\":\"Add a necklace\",\"input_references\":[{\"type\":\"video_url\",\"video_url\":{\"url\":\"https://a.example/clip.mp4\"}}]}", "video" },
    };
    for (cases) |case| {
        var nothing: foundation.replay.Replay = .init(arena, &.{});
        const refusing = try fixtures.modelsOver(arena, nothing.http(), options);
        try expectContains((try refusing.createVideo(arena, try foundation.json.decode(videos.VideoRequest, arena, case[0]))).failed.message, case[1]);
        try std.testing.expectEqual(@as(usize, 0), nothing.sent.items.len);
    }
}
