//! Ollama's and LM Studio's drivers: their listings answer from listings built by hand from their API references,
//! read on 2026-11-01 (https://docs.ollama.com/api/tags, https://docs.ollama.com/api-reference/show-model-details and
//! https://lmstudio.ai/docs/developer/rest/list), and their text requests replay the Chat Completions server's fixture.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const http = foundation.http;
const vocabulary = @import("vocabulary");
const seam = @import("../driver.zig");
const Models = @import("../Models.zig");
const ModelFacts = @import("../catalogue/facts.zig").ModelFacts;
const fixtures = @import("../testing/fixtures.zig");
const TestHost = @import("../testing/host.zig").Host;
const ollama = @import("ollama.zig");
const lmstudio = @import("lmstudio.zig");

/// One answer of a server: to a request at its address and, for a POST, with its body.
const Answer = struct { url: []const u8, body: ?[]const u8 = null, status: u16 = 200, answer: []const u8 };

/// Servers that answer each request from their answers, else through `rest`, else refuse the connection; each
/// request asked kept as its address and body.
const Servers = struct {
    arena: Allocator,
    answers: []const Answer,
    rest: ?http.Http = null,
    asked: std.ArrayList([]const u8) = .empty,

    fn network(servers: *Servers) http.Http {
        return .{ .context = servers, .vtable = &.{ .send = send } };
    }

    fn send(context: *anyopaque, request: http.Request) http.SendError!http.Response {
        const servers: *Servers = @ptrCast(@alignCast(context));
        const arena = servers.arena;
        try servers.asked.append(arena, if (request.body) |body| try std.fmt.allocPrint(arena, "{s} {s}", .{ request.url, body }) else try arena.dupe(u8, request.url));
        for (servers.answers) |answer| {
            if (!std.mem.eql(u8, answer.url, request.url)) continue;
            if (answer.body) |body| if (request.body == null or !std.mem.eql(u8, body, request.body.?)) continue;
            const reader = try arena.create(foundation.replay.ChunkReader);
            reader.* = .init(try arena.dupe([]const u8, &.{answer.answer}), try arena.alloc(u8, 4096));
            const headers = try arena.dupe(http.Header, &.{.{ .name = "content-type", .value = "application/json" }});
            return .{ .status = answer.status, .headers = headers, .body = &reader.reader, .context = reader, .vtable = &.{ .failure = failure, .close = close } };
        }
        if (servers.rest) |rest| return rest.send(request);
        return error.Transport;
    }

    fn failure(_: *anyopaque) http.Error {
        return error.Transport;
    }

    fn close(_: *anyopaque) void {}
};

/// What the driver of `provider` lists through `servers`.
fn listed(arena: Allocator, provider: seam.Provider, servers: *Servers) ![]const ModelFacts {
    var test_host: TestHost = .{};
    const host = test_host.host(servers.network());
    const owned = try arena.create(seam.Provider);
    owned.* = provider;
    var call: seam.Call = .{ .arena = arena, .provider = owned, .host = &host };
    return provider.driver.list.?(&call);
}

fn modelsOver(arena: Allocator, provider: seam.Provider, servers: *Servers) !*Models {
    const test_host = try arena.create(TestHost);
    test_host.* = .{};
    return Models.init(arena, .{ .providers = try arena.dupe(seam.Provider, &.{provider}), .host = test_host.host(servers.network()) });
}

fn providerOf(driver: *const seam.Driver, base_url: ?[]const u8) seam.Provider {
    return .{ .id = driver.id, .name = driver.name, .driver = driver, .settings = .{ .base_url = base_url } };
}

/// The facts of a text model of a server on this machine, as its driver lists them, as JSON.
fn localFacts(arena: Allocator, id: []const u8, name: []const u8, context_length: u64, images: bool) ![]const u8 {
    const inputs = if (images) "[\"text\",\"image\"]" else "[\"text\"]";
    return std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"context_length\":{d},\"architecture\":{{\"input_modalities\":{s},\"output_modalities\":[\"text\"]}},\"pricing\":{{\"prompt\":\"0\",\"completion\":\"0\"}},\"octoii\":{{\"kinds\":[\"text\"]}}}}", .{ id, name, context_length, inputs });
}

fn expectFacts(arena: Allocator, expected: []const []const u8, actual: []const ModelFacts) !void {
    try fixtures.expectJson(arena, try std.fmt.allocPrint(arena, "[{s}]", .{try std.mem.join(arena, ",", expected)}), try foundation.json.encode(arena, actual));
}

const ollama_url = "http://127.0.0.1:11434";

/// Ollama's details of a model: its capabilities and its architecture's facts.
fn shown(arena: Allocator, model: []const u8, capabilities: []const u8, architecture: []const u8, context_length: u64) !Answer {
    return .{
        .url = ollama_url ++ "/api/show",
        .body = try std.fmt.allocPrint(arena, "{{\"model\":\"{s}\"}}", .{model}),
        .answer = try std.fmt.allocPrint(arena,
            \\{{"capabilities":{s},"details":{{"format":"gguf","family":"{s}","parameter_size":"8.0B","quantization_level":"Q4_K_M"}},
            \\ "model_info":{{"general.architecture":"{s}","{s}.context_length":{d},"{s}.block_count":42}}}}
        , .{ capabilities, architecture, architecture, architecture, context_length, architecture }),
    };
}

/// Ollama answering for three models: one that reads images, one that does not, and one that embeds.
fn ollamaAnswers(arena: Allocator) ![]const Answer {
    return arena.dupe(Answer, &.{
        .{ .url = ollama_url ++ "/api/tags", .answer =
        \\{"models":[{"name":"gemma4:latest","model":"gemma4:latest","modified_at":"2026-10-03T23:34:03-07:00","size":9608350245,"digest":"c6eb","details":{"family":"gemma4"}},
        \\ {"name":"qwen3.6-27b","model":"qwen3.6-27b","modified_at":"2026-10-04T10:00:00-07:00","size":17000000000,"digest":"a1b2","details":{"family":"qwen3"}},
        \\ {"name":"nomic-embed-text:latest","model":"nomic-embed-text:latest","modified_at":"2026-09-01T10:00:00-07:00","size":274290560,"digest":"9f8e","details":{}}]}
        },
        try shown(arena, "gemma4:latest", "[\"completion\",\"thinking\",\"vision\"]", "gemma4", 131072),
        try shown(arena, "qwen3.6-27b", "[\"completion\",\"tools\",\"thinking\"]", "qwen3", 262144),
        try shown(arena, "nomic-embed-text:latest", "[\"embedding\"]", "nomic-bert", 2048),
    });
}

test "Ollama lists the models that complete, their window their architecture's, images read where they say vision" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqual(null, ollama.driver.catalogue);
    var servers: Servers = .{ .arena = a, .answers = try ollamaAnswers(a) };
    try expectFacts(a, &.{
        try localFacts(a, "gemma4:latest", "gemma4:latest", 131072, true),
        try localFacts(a, "qwen3.6-27b", "qwen3.6-27b", 262144, false),
    }, try listed(a, providerOf(&ollama.driver, null), &servers));
    // A model whose details cannot be read is left out.
    var busy_answers = try a.dupe(Answer, try ollamaAnswers(a));
    busy_answers[1].status = 500;
    busy_answers[1].answer = "{\"error\":\"model is busy\"}";
    var busy: Servers = .{ .arena = a, .answers = busy_answers };
    const left = try listed(a, providerOf(&ollama.driver, null), &busy);
    try std.testing.expectEqual(@as(usize, 1), left.len);
    try std.testing.expectEqualStrings("qwen3.6-27b", left[0].id);
}

test "Ollama lists no models at a server that is absent, failing or not Ollama, and asks its provider's address" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const servers = [_][]const Answer{
        &.{},
        &.{.{ .url = ollama_url ++ "/api/tags", .status = 404, .answer = "404 page not found" }},
        &.{.{ .url = ollama_url ++ "/api/tags", .answer = "{\"data\":[]}" }},
    };
    for (servers) |answers| {
        var each: Servers = .{ .arena = a, .answers = answers };
        try std.testing.expectEqual(@as(usize, 0), (try listed(a, providerOf(&ollama.driver, null), &each)).len);
    }
    var elsewhere: Servers = .{ .arena = a, .answers = &.{} };
    _ = try listed(a, providerOf(&ollama.driver, "http://192.168.1.20:11434"), &elsewhere);
    try std.testing.expectEqual(@as(usize, 1), elsewhere.asked.items.len);
    try std.testing.expectEqualStrings("http://192.168.1.20:11434/api/tags", elsewhere.asked.items[0]);
}

test "Ollama's provider is connected where its server answers, and gives the models it lists once listed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var servers: Servers = .{ .arena = a, .answers = try ollamaAnswers(a) };
    const models = try modelsOver(a, providerOf(&ollama.driver, null), &servers);
    try std.testing.expect((try models.status(a, "ollama")).connected);
    try models.refresh();
    const ids = try models.list(a, null);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqualStrings("gemma4:latest", ids[0].id);
    const qwen = (try models.find(a, "ollama/qwen3.6-27b")).?.model;
    try std.testing.expectEqual(@import("../catalogue/model.zig").Source.listing, qwen.octoii.sources.?.map.get("context_length").?);
    var absent: Servers = .{ .arena = a, .answers = &.{} };
    const none = try (try modelsOver(a, providerOf(&ollama.driver, null), &absent)).status(a, "ollama");
    try std.testing.expect(!none.connected);
    try std.testing.expectEqualStrings("No server answers with its models at " ++ ollama_url ++ "/api/tags", none.problem.?);
}

test "Ollama sends a listed model's text request to its Chat Completions server, needing no credential" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const fixture = try fixtures.load(a, "chat-completions", "text");
    const exchanges = try a.dupe(foundation.replay.Exchange, fixture.exchanges);
    for (exchanges) |*exchange| exchange.request.url = ollama_url ++ "/v1/chat/completions";
    var replay: foundation.replay.Replay = .init(a, exchanges);
    var servers: Servers = .{ .arena = a, .answers = try ollamaAnswers(a), .rest = replay.http() };
    const models = try modelsOver(a, providerOf(&ollama.driver, null), &servers);
    try models.refresh();
    var request = fixture.request;
    request.model = "ollama/qwen3.6-27b";
    const response = try models.create(a, request);
    if (replay.mismatch) |why| std.debug.print("{s}\n", .{why});
    try std.testing.expectEqual(vocabulary.response.ResponseStatus.completed, response.status);
    try std.testing.expectEqual(@as(usize, 0), replay.unused().len);
}

const lmstudio_url = "http://127.0.0.1:1234";

/// LM Studio's listing: a loaded model that reads images, one not loaded, and an embedding model.
const lmstudio_listing: Answer = .{ .url = lmstudio_url ++ "/api/v1/models", .answer =
    \\{"models":[{"type":"llm","publisher":"google","key":"google/gemma-4-26b-a4b","display_name":"Gemma 4 26B A4B","architecture":"gemma4",
    \\  "quantization":{"name":"Q4_K_M","bits_per_weight":4},"size_bytes":17990911801,"params_string":"26B-A4B",
    \\  "loaded_instances":[{"id":"google/gemma-4-26b-a4b","config":{"context_length":4096,"eval_batch_size":512,"parallel":4}}],
    \\  "max_context_length":262144,"format":"gguf","capabilities":{"vision":true,"trained_for_tool_use":true,"reasoning":{"allowed_options":["off","on"],"default":"on"}},"description":null},
    \\ {"type":"llm","publisher":"qwen","key":"qwen/qwen3.6-27b","display_name":"Qwen3.6 27B","architecture":"qwen3","loaded_instances":[],
    \\  "max_context_length":131072,"format":"mlx","capabilities":{"vision":false,"trained_for_tool_use":true}},
    \\ {"type":"embedding","publisher":"gaianet","key":"text-embedding-nomic-embed-text-v1.5-embedding","display_name":"Nomic Embed Text v1.5",
    \\  "loaded_instances":[],"max_context_length":2048,"format":"gguf"}]}
};

test "LM Studio lists its llm models, a loaded one's window its instance's, images read where they say vision" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqual(null, lmstudio.driver.catalogue);
    var servers: Servers = .{ .arena = a, .answers = &.{lmstudio_listing} };
    try expectFacts(a, &.{
        try localFacts(a, "google/gemma-4-26b-a4b", "Gemma 4 26B A4B", 4096, true),
        try localFacts(a, "qwen/qwen3.6-27b", "Qwen3.6 27B", 131072, false),
    }, try listed(a, providerOf(&lmstudio.driver, null), &servers));
}

test "LM Studio lists no models at a server that is absent or not LM Studio, says so, and asks its provider's address" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var absent: Servers = .{ .arena = a, .answers = &.{} };
    try std.testing.expectEqual(@as(usize, 0), (try listed(a, providerOf(&lmstudio.driver, null), &absent)).len);
    var other: Servers = .{ .arena = a, .answers = &.{.{ .url = lmstudio_url ++ "/api/v1/models", .answer = "{\"data\":[]}" }} };
    try std.testing.expectEqual(@as(usize, 0), (try listed(a, providerOf(&lmstudio.driver, null), &other)).len);
    try std.testing.expect(!(try (try modelsOver(a, providerOf(&lmstudio.driver, null), &absent)).status(a, "lmstudio")).connected);
    var elsewhere: Servers = .{ .arena = a, .answers = &.{} };
    _ = try listed(a, providerOf(&lmstudio.driver, "http://10.0.0.5:1234"), &elsewhere);
    try std.testing.expectEqualStrings("http://10.0.0.5:1234/api/v1/models", elsewhere.asked.items[0]);
}
