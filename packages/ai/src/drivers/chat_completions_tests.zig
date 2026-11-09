//! Z.ai's and a Chat Completions server's drivers, Chat Completions as each speaks it, against their recorded
//! exchanges and against what their requests become on the wire.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const Usage = vocabulary.Usage;
const seam = @import("../driver.zig");
const Models = @import("../Models.zig");
const ModelFacts = @import("../catalogue/facts.zig").ModelFacts;
const fixtures = @import("../testing/fixtures.zig");
const TestHost = @import("../testing/host.zig").Host;
const zai = @import("zai.zig");
const server = @import("chat_completions.zig");

const zai_options: fixtures.Options = .{ .driver = &zai.driver, .key = "zai-test-key" };
const plan_options: fixtures.Options = .{ .driver = &zai.coding_plan, .key = "zai-plan-test-key" };

/// Qwen 3.6 27B as a host lists it on a server on this machine, which nothing prices.
const qwen: ModelFacts = .{
    .id = "qwen3.6-27b",
    .name = "Qwen 3.6 27B",
    .context_length = 32_768,
    .architecture = .{ .input_modalities = &.{ .text, .image, .file }, .output_modalities = &.{.text} },
    .reasoning = .{ .mandatory = false },
};

/// The server on this machine, as a host makes it, needing no key.
const local_options: fixtures.Options = .{
    .driver = &server.driver,
    .provider = "local",
    .folder = "chat-completions",
    .key = null,
    .models = &.{ qwen, .{ .id = "model", .reasoning = .{ .mandatory = false }, .architecture = .{ .input_modalities = &.{ .text, .image, .file }, .output_modalities = &.{.text} } } },
    .settings = .{ .base_url = "http://127.0.0.1:8080/v1" },
};

/// A stream that ends at once, whole.
const done_chunks: []const []const u8 = &.{"data: {\"id\":\"r\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hi\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"};

/// The body of the last request `fields` sent to `model` through `options`, read as JSON.
fn sentBody(arena: Allocator, model: []const u8, fields: []const u8, options: fixtures.Options) !std.json.Value {
    const answered = try fixtures.answered(arena, try fixtures.decoded(arena, try fixtures.requestWith(arena, model, fields)), done_chunks, options);
    if (answered.response.@"error") |failure| std.debug.print("failed: {s}\n", .{failure.message});
    try std.testing.expectEqual(vocabulary.response.ResponseStatus.completed, answered.response.status);
    return std.json.parseFromSliceLeaky(std.json.Value, arena, answered.sent[answered.sent.len - 1].body.?, .{});
}

fn expectMember(arena: Allocator, body: std.json.Value, key: []const u8, expected: []const u8) !void {
    try fixtures.expectJson(arena, expected, try foundation.json.encode(arena, body.object.get(key) orelse return error.TestExpectedEqual));
}

fn lastHeader(replay: *const foundation.replay.Replay, name: []const u8) ?[]const u8 {
    return foundation.http.find(replay.sent.items[replay.sent.items.len - 1].headers, name);
}

/// The fixture `name` of `options`' provider, its exchanges answered twice, created twice: the two responses.
fn createdTwice(arena: Allocator, name: []const u8, options: fixtures.Options) ![2]vocabulary.Response {
    const fixture = try fixtures.load(arena, options.folder orelse options.provider orelse options.driver.id, name);
    var replay: foundation.replay.Replay = .init(arena, try std.mem.concat(arena, foundation.replay.Exchange, &.{ fixture.exchanges, fixture.exchanges }));
    var host: TestHost = .{ .keys = if (options.key) |key| &.{.{ .provider = options.provider orelse options.driver.id, .key = key }} else &.{} };
    const providers = try arena.dupe(seam.Provider, &.{.{ .id = options.provider orelse options.driver.id, .name = "p", .driver = options.driver, .settings = options.settings, .models = options.models }});
    const models = try Models.init(arena, .{ .providers = providers, .host = host.host(replay.http()) });
    return .{ try models.create(arena, fixture.request), try models.create(arena, fixture.request) };
}

fn callIds(arena: Allocator, responses: []const vocabulary.Response) ![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    for (responses) |response| for (response.output) |item| if (item == .function_call) try ids.append(arena, item.function_call.call_id);
    return ids.items;
}

fn expectUnique(ids: []const []const u8) !void {
    for (ids, 0..) |id, index| {
        try fixtures.expectMinted(id);
        for (ids[index + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, id, other));
    }
}

test "Z.ai and its GLM Coding Plan serve the catalogue's models, the plan's without prices" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    try std.testing.expectEqualStrings("zai", zai.driver.catalogue.?);
    try std.testing.expectEqualStrings("zai-coding-plan", zai.coding_plan.catalogue.?);
    var plan: usize = 0;
    for (try @import("../catalogue/catalogue.zig").bundled(arena)) |model| if (std.mem.eql(u8, model.octoii.provider, "zai-coding-plan")) {
        plan += 1;
        try std.testing.expect(model.pricing == null);
    };
    try std.testing.expect(plan > 0);
}

test "every recorded text stream of Z.ai's is sent as recorded, with its key and for a stream, and carries nothing of ai's" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    for ([_]fixtures.Options{ zai_options, plan_options }) |options| {
        for (try fixtures.textNames(arena, options.driver.id)) |name| {
            const streamed = try fixtures.streamFixture(arena, name, options);
            const body = try fixtures.sentBody(arena, streamed.replay, 0);
            for ([_][]const u8{ "octoii", "signature", "provider_metadata" }) |key| try std.testing.expect(!fixtures.holds(body, key));
            try std.testing.expectEqualStrings("text/event-stream", lastHeader(streamed.replay, "accept").?);
        }
    }
    const text = try fixtures.streamFixture(arena, "text", zai_options);
    try std.testing.expectEqualStrings("Bearer zai-test-key", lastHeader(text.replay, "authorization").?);
    const plan = try fixtures.streamFixture(arena, "text", plan_options);
    try std.testing.expectEqualStrings("Bearer zai-plan-test-key", lastHeader(plan.replay, "authorization").?);
    try std.testing.expectEqualStrings("https://api.z.ai/api/coding/paas/v4/chat/completions", plan.replay.sent.items[0].url);
}

test "Z.ai serves its provider at a proxy's address, and fails as auth before anything is sent without a key" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const fixture = try fixtures.load(arena, "zai", "text");
    const proxied = try arena.dupe(foundation.replay.Exchange, fixture.exchanges);
    for (proxied) |*exchange| exchange.request.url = "https://proxy.example/v4/chat/completions";
    var options = zai_options;
    options.settings = .{ .base_url = "https://proxy.example/v4" };
    const streamed = try fixtures.stream(arena, fixture.request, proxied, options);
    try std.testing.expectEqual(vocabulary.response.ResponseStatus.completed, streamed.response.status);
    try std.testing.expectEqual(@as(usize, 0), streamed.replay.unused().len);
    var keyless = zai_options;
    keyless.key = null;
    const refused = try fixtures.stream(arena, fixture.request, &.{}, keyless);
    try std.testing.expectEqual(vocabulary.FailureKind.auth, refused.response.@"error".?.octoii.kind);
    try std.testing.expect(std.mem.indexOf(u8, refused.response.@"error".?.message, "The provider zai has no API key") != null);
    try std.testing.expectEqual(@as(usize, 0), refused.replay.sent.items.len);
}

/// A model Z.ai serves that the catalogue does not know, which takes every parameter and reads files.
const any_zai: fixtures.Options = .{
    .driver = &zai.driver,
    .key = "zai-test-key",
    .models = &.{
        .{ .id = "model", .architecture = .{ .input_modalities = &.{ .text, .image, .file }, .output_modalities = &.{.text} } },
        .{ .id = "plain", .supported_parameters = &.{"max_tokens"} },
    },
};

test "Z.ai thinks for a model that reasons, or that does not say and is asked an effort, and takes what it defines" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    try std.testing.expect((try sentBody(arena, "zai/plain", "\"max_output_tokens\":10", any_zai)).object.get("thinking") == null);
    try std.testing.expect((try sentBody(arena, "zai/model", "\"max_output_tokens\":10", any_zai)).object.get("thinking") == null);
    try expectMember(arena, try sentBody(arena, "zai/model", "\"reasoning\":{\"effort\":\"high\"}", any_zai), "thinking", "{\"type\":\"enabled\",\"clear_thinking\":false}");
    const body = try sentBody(arena, "zai/model", "\"text\":{\"format\":{\"type\":\"json_object\"}},\"stop\":\"END\",\"tool_choice\":\"auto\",\"temperature\":1", any_zai);
    try expectMember(arena, body, "response_format", "{\"type\":\"json_object\"}");
    try expectMember(arena, body, "stop", "[\"END\"]");
    try expectMember(arena, body, "tool_choice", "\"auto\"");
    try expectMember(arena, body, "temperature", "1");
}

test "Z.ai refuses what it does not take before anything is sent" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const refused = [_]struct { []const u8, []const u8 }{
        .{ "\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":\"answer\",\"schema\":{\"type\":\"object\"}}}", "json_schema" },
        .{ "\"temperature\":1.5", "temperature of 1.5" },
        .{ "\"stop\":[\"A\",\"B\"]", "2 stop sequences" },
        .{ "\"tool_choice\":\"none\"", "tool_choice other than auto" },
        .{ "\"top_k\":40", "top_k" },
        .{ "\"text\":{\"verbosity\":\"low\"}", "text.verbosity" },
        .{ "\"parallel_tool_calls\":true", "parallel_tool_calls" },
        .{ "\"reasoning\":{\"mode\":\"pro\"}", "reasoning.mode pro" },
    };
    for (refused) |case| {
        const failure = try fixtures.refusal(arena, try fixtures.requestWith(arena, "zai/model", case[0]), any_zai);
        try std.testing.expectEqual(vocabulary.FailureKind.invalid_request, failure.octoii.kind);
        if (std.mem.indexOf(u8, failure.message, case[1]) == null) {
            std.debug.print("{s}: {s}\n", .{ case[1], failure.message });
            return error.TestUnexpectedMessage;
        }
    }
    // A catalogue model's parameters lack structured outputs.
    const schema = try fixtures.refusal(arena, "{\"model\":\"zai/glm-5.2\",\"input\":\"Hi\",\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":\"a\",\"schema\":{}}}}", zai_options);
    try std.testing.expectEqual(vocabulary.FailureKind.invalid_request, schema.octoii.kind);
}

test "Z.ai is given a PDF at an address as its file_url, and a text file at one fetched as its text" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const answered = try fixtures.answered(arena, try fixtures.decoded(arena,
        \\{"model":"zai/model","input":[{"role":"user","content":[{"type":"input_file","file_url":"https://files.example.com/report.pdf"},
        \\ {"type":"input_file","file_url":"https://files.example.com/notes.txt"}]}]}
    ), done_chunks, any_zai);
    try std.testing.expectEqual(@as(usize, 2), answered.sent.len);
    try std.testing.expectEqualStrings("https://files.example.com/notes.txt", answered.sent[0].url);
    const body = try std.json.parseFromSliceLeaky(std.json.Value, arena, answered.sent[1].body.?, .{});
    try expectMember(arena, body, "messages",
        \\[{"role":"user","content":[{"type":"file","file":{"file_url":"https://files.example.com/report.pdf"}},
        \\ {"type":"text","text":"<file name=\"notes.txt\">\nParis: 18 \u00b0C\n</file>"}]}]
    );
}

test "Z.ai's responses hold its reasoning and answer, priced from the catalogue, and end as it finished" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const text = (try fixtures.streamFixture(arena, "text", zai_options));
    const response = text.response;
    try std.testing.expectEqualStrings("zai/glm-5.2", response.octoii.?.model.?);
    try std.testing.expectEqual(@as(?u64, 22), response.octoii.?.context_tokens);
    const reasoning = response.output[0].reasoning;
    try std.testing.expectEqualStrings("The user asks for France's capital: Paris.", reasoning.content.?[0].text);
    try std.testing.expectEqual(vocabulary.items.ItemStatus.completed, reasoning.status.?);
    try std.testing.expectEqualStrings("The capital of France is Paris.", (try fixtures.messageText(arena, response.output)).?);
    // GLM-5.2: $1.40 a million tokens read, $0.26 a million cached, $4.40 a million written.
    try fixtures.expectUsage(.{ .input = 14, .cache_read = 8, .output = 31, .cost = 14 * 0.0000014 + 8 * 0.00000026 + 31 * 0.0000044 }, Usage.ofResponse(response));
    var deltas: std.ArrayList([]const u8) = .empty;
    for (text.events) |event| if (event == .output_text_delta) try deltas.append(arena, event.output_text_delta.delta);
    try std.testing.expectEqual(@as(usize, 2), deltas.items.len);
    try std.testing.expectEqualStrings(" of France is Paris.", deltas.items[1]);
    const plan = (try fixtures.streamFixture(arena, "text", plan_options)).response;
    try std.testing.expectEqual(vocabulary.response.ResponseStatus.completed, plan.status);
    try std.testing.expectEqual(null, plan.usage.?.cost);
    const length = (try fixtures.streamFixture(arena, "length", zai_options)).response;
    try std.testing.expectEqual(.max_output_tokens, length.incomplete_details.?.reason.?);
    try std.testing.expectEqual(vocabulary.items.ItemStatus.incomplete, length.output[0].output_message.status.?);
    try std.testing.expectEqualStrings("1, 2, 3, 4", (try fixtures.messageText(arena, length.output)).?);
    try std.testing.expectEqual(.max_output_tokens, (try fixtures.streamFixture(arena, "context-window", zai_options)).response.incomplete_details.?.reason.?);
    try std.testing.expectEqual(.content_filter, (try fixtures.streamFixture(arena, "sensitive", zai_options)).response.incomplete_details.?.reason.?);
    try std.testing.expectEqual(vocabulary.response.ResponseStatus.completed, (try fixtures.streamFixture(arena, "crossing-models", zai_options)).response.status);
}

test "Z.ai's function calls each have a call_id of their own, unique across responses where it repeats call_0" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const responses = try createdTwice(arena, "function-call", zai_options);
    const ids = try callIds(arena, &responses);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try expectUnique(ids);
    const call = responses[0].output[responses[0].output.len - 1].function_call;
    try std.testing.expectEqualStrings("get_weather", call.name);
    try std.testing.expectEqualStrings("{\"city\":\"Paris\"}", call.arguments);
}

test "Z.ai's failures are classified by its codes" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const broken = try fixtures.streamFixture(arena, "network-error", zai_options);
    const raised = broken.events[broken.events.len - 2].@"error";
    try std.testing.expectEqualStrings("network_error", raised.code);
    try std.testing.expectEqual(vocabulary.FailureKind.server, raised.octoii.kind);
    try std.testing.expect(raised.octoii.retryable);
    try std.testing.expectEqual(@as(u64, 3), broken.response.usage.?.output_tokens);
    try std.testing.expectEqual(vocabulary.items.ItemStatus.incomplete, broken.response.output[0].output_message.status.?);
    try std.testing.expectEqualStrings("Hello! How", (try fixtures.messageText(arena, broken.response.output)).?);
    const cases = [_]struct { []const u8, fixtures.Options, vocabulary.FailureKind, []const u8, bool }{
        .{ "unauthorized", zai_options, .auth, "1000", false },
        .{ "rate-limited", zai_options, .rate_limit, "1302", true },
        .{ "balance", zai_options, .quota, "1113", false },
        .{ "context-overflow", zai_options, .context_overflow, "1261", false },
        .{ "content-filter", zai_options, .content_filter, "1301", false },
        .{ "overloaded", zai_options, .server, "1305", true },
        .{ "server", zai_options, .server, "1234", true },
        .{ "plan-limit", plan_options, .quota, "1310", false },
        .{ "model-not-in-plan", plan_options, .auth, "1311", false },
    };
    for (cases) |case| {
        const failure = try fixtures.failureOf(arena, case[0], case[1]);
        try std.testing.expectEqual(case[2], failure.octoii.kind);
        try std.testing.expectEqualStrings(case[3], failure.code);
        try std.testing.expectEqual(case[4], failure.octoii.retryable);
    }
    const unauthorized = try fixtures.failureOf(arena, "unauthorized", zai_options);
    try std.testing.expectEqual(@as(?u16, 401), unauthorized.octoii.status);
    try std.testing.expectEqualStrings("Authentication Failed", unauthorized.message);
    try std.testing.expectEqual(@as(?u64, 30_000), (try fixtures.failureOf(arena, "rate-limited", zai_options)).octoii.retry_after_ms);
    try std.testing.expectEqual(@as(?u16, 429), (try fixtures.failureOf(arena, "balance", zai_options)).octoii.status);
    try std.testing.expectEqual(@as(?u16, 500), (try fixtures.failureOf(arena, "server", zai_options)).octoii.status);
}

test "every recorded stream of a Chat Completions server is sent as recorded, without a key where the host holds none" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    for (try fixtures.textNames(arena, "chat-completions")) |name| {
        const streamed = try fixtures.streamFixture(arena, name, local_options);
        try std.testing.expect(!fixtures.holds(try fixtures.sentBody(arena, streamed.replay, 0), "octoii"));
        try std.testing.expectEqual(null, lastHeader(streamed.replay, "authorization"));
    }
    var keyed = local_options;
    keyed.key = "sk-local";
    const fixture = try fixtures.load(arena, "chat-completions", "text");
    const streamed = try fixtures.stream(arena, fixture.request, fixture.exchanges, keyed);
    try std.testing.expectEqualStrings("Bearer sk-local", lastHeader(streamed.replay, "authorization").?);
    try std.testing.expectEqualStrings("text/event-stream", lastHeader(streamed.replay, "accept").?);
}

test "a Chat Completions server fails as auth, sending nothing, where the host holds a sign-in for it" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var replay: foundation.replay.Replay = .init(arena, &.{});
    var test_host: TestHost = .{ .saved = .{ .provider = "local", .credential = .{ .oauth = .{ .issuer = "https://issuer.example", .client_id = "client" } } } };
    const host = test_host.host(replay.http());
    const providers = try arena.dupe(seam.Provider, &.{.{ .id = "local", .name = "Local", .driver = &server.driver, .settings = local_options.settings, .models = local_options.models }});
    const models = try Models.init(arena, .{ .providers = providers, .host = host });
    const response = try models.create(arena, try fixtures.decoded(arena, "{\"model\":\"local/qwen3.6-27b\",\"input\":\"Hi\"}"));
    try std.testing.expectEqual(vocabulary.FailureKind.auth, response.@"error".?.octoii.kind);
    try std.testing.expectEqual(@as(usize, 0), replay.sent.items.len);
}

test "a Chat Completions server lists its models at /models with its key, and gives the person's where it lists none" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var answering: fixtures.Answering = .{ .arena = arena, .chunks = &.{"{\"object\":\"list\",\"data\":[{\"id\":\"qwen3.6-27b\",\"object\":\"model\"},{\"id\":\"gemma-4\"}]}"}, .content_type = "application/json" };
    var test_host: TestHost = .{ .keys = &.{.{ .provider = "local", .key = "sk-local" }} };
    const listing = try arena.dupe(seam.Provider, &.{.{ .id = "local", .name = "Local", .driver = &server.driver, .settings = local_options.settings }});
    const models = try Models.init(arena, .{ .providers = listing, .host = test_host.host(answering.http()) });
    try models.refresh();
    const listed = try models.list(arena, null);
    try std.testing.expectEqual(@as(usize, 2), listed.len);
    try std.testing.expectEqualStrings("qwen3.6-27b", listed[0].id);
    try std.testing.expectEqualStrings("gemma-4", listed[1].id);
    const gemma = (try models.find(arena, "local/gemma-4")).?.model;
    try std.testing.expectEqual(@import("../catalogue/model.zig").Source.listing, gemma.octoii.sources.?.map.get("octoii.kinds").?);
    try std.testing.expectEqual(@import("../catalogue/model.zig").Source.assumed, gemma.octoii.sources.?.map.get("context_length").?);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/v1/models", answering.sent.items[0].url);
    try std.testing.expectEqualStrings("Bearer sk-local", foundation.http.find(answering.sent.items[0].headers, "authorization").?);
    try std.testing.expect((try models.status(arena, "local")).connected);
    var nowhere: foundation.replay.Replay = .init(arena, &.{});
    const absent = try Models.init(arena, .{ .providers = try arena.dupe(seam.Provider, &.{.{ .id = "local", .name = "Local", .driver = &server.driver, .settings = local_options.settings, .models = &.{qwen} }}), .host = test_host.host(nowhere.http()) });
    try absent.refresh();
    const added = (try absent.find(arena, "local/qwen3.6-27b")).?.model;
    try std.testing.expectEqualStrings("Qwen 3.6 27B", added.name);
    try std.testing.expectEqual(@as(?u64, 32_768), added.context_length);
    const status = try absent.status(arena, "local");
    try std.testing.expect(!status.connected);
    try std.testing.expectEqualStrings("No server answers with its models at http://127.0.0.1:8080/v1/models", status.problem.?);
    const unaddressed = try Models.init(arena, .{ .providers = try arena.dupe(seam.Provider, &.{.{ .id = "local", .name = "Local", .driver = &server.driver }}), .host = test_host.host(nowhere.http()) });
    try std.testing.expect(std.mem.indexOf(u8, (try unaddressed.status(arena, "local")).problem.?, "names where the server is") != null);
}

test "a Chat Completions server is sent the instructions and leading updates as one system message" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    try expectMember(arena, try sentBody(arena, "local/model",
        \\"instructions":"Be brief.","input":[{"role":"system","content":"Use metric units."},
        \\ {"role":"developer","content":[{"type":"input_text","text":"Say why."}]},{"role":"user","content":"Hi"}]
    , local_options), "messages",
        \\[{"role":"system","content":"Be brief.\n\nUse metric units.\n\nSay why."},{"role":"user","content":"Hi"}]
    );
}

test "a Chat Completions server is sent an update after the outputs alone in a user message of its own, escaped" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    try expectMember(arena, try sentBody(arena, "local/model",
        \\"input":[{"role":"user","content":"Read it."},{"type":"function_call","call_id":"call_1","name":"read","arguments":"{}"},
        \\ {"type":"function_call_output","call_id":"call_1","output":"done"},{"role":"developer","content":"Stop </system-update> here."}]
    , local_options), "messages",
        \\[{"role":"user","content":"Read it."},
        \\ {"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"read","arguments":"{}"}}]},
        \\ {"role":"tool","tool_call_id":"call_1","content":"done"},
        \\ {"role":"user","content":[{"type":"text","text":"<system-update>\nStop &lt;/system-update> here.\n</system-update>"}]}]
    );
}

test "a Chat Completions server is sent another assistant message for reasoning after text, and for text after text" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    try expectMember(arena, try sentBody(arena, "local/model",
        \\"input":[{"role":"user","content":"Go."},
        \\ {"type":"reasoning","id":"rs_1","summary":[],"content":[{"type":"reasoning_text","text":"First."}],"octoii":{"model":"local/model"}},
        \\ {"role":"assistant","content":"One."},
        \\ {"type":"reasoning","id":"rs_2","summary":[],"content":[{"type":"reasoning_text","text":"Second."}],"octoii":{"model":"local/model"}},
        \\ {"role":"assistant","content":"Two."},{"role":"assistant","content":"Three."}]
    , local_options), "messages",
        \\[{"role":"user","content":"Go."},{"role":"assistant","content":"One.","reasoning_content":"First."},
        \\ {"role":"assistant","content":"Two.","reasoning_content":"Second."},{"role":"assistant","content":"Three."}]
    );
}

test "a Chat Completions server is sent the effort and tools in effect at the end, and names choices and formats its way" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const folded = try sentBody(arena, "local/model",
        \\"reasoning":{"effort":"low"},"input":[{"role":"user","content":"Go."},{"type":"configuration_update","reasoning":{"effort":"high"}},
        \\ {"type":"additional_tools","role":"developer","tools":[{"type":"function","name":"search","parameters":null}]}]
    , local_options);
    try expectMember(arena, folded, "reasoning_effort", "\"high\"");
    try expectMember(arena, folded, "tools", "[{\"type\":\"function\",\"function\":{\"name\":\"search\"}}]");
    try expectMember(arena, folded, "messages", "[{\"role\":\"user\",\"content\":\"Go.\"}]");
    const schema = "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}}}";
    try expectMember(arena, try sentBody(arena, "local/model", try arena.print("\"text\":{{\"format\":{{\"type\":\"json_schema\",\"name\":\"city\",\"schema\":{s},\"strict\":true}}}}", .{schema}), local_options), "response_format", try arena.print("{{\"type\":\"json_schema\",\"json_schema\":{{\"name\":\"city\",\"schema\":{s},\"strict\":true}}}}", .{schema}));
    const tools = "\"tools\":[{\"type\":\"function\",\"name\":\"search\"}],";
    try expectMember(arena, try sentBody(arena, "local/model", tools ++ "\"tool_choice\":{\"type\":\"function\",\"name\":\"search\"}", local_options), "tool_choice", "{\"type\":\"function\",\"function\":{\"name\":\"search\"}}");
    try expectMember(arena, try sentBody(arena, "local/model", tools ++ "\"tool_choice\":{\"type\":\"allowed_tools\",\"mode\":\"required\",\"tools\":[{\"type\":\"function\",\"name\":\"search\"}]}", local_options), "tool_choice",
        \\{"type":"allowed_tools","allowed_tools":{"mode":"required","tools":[{"type":"function","function":{"name":"search"}}]}}
    );
}

test "a Chat Completions server is sent its own provider options, a stream still, and none of the identifiers kept for records" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const options = try sentBody(arena, "local/model", "\"provider\":{\"options\":{\"chat-completions\":{\"min_p\":0.05,\"stream\":false},\"other\":{\"seed\":1}}}", local_options);
    try expectMember(arena, options, "min_p", "0.05");
    try expectMember(arena, options, "stream", "true");
    try std.testing.expect(options.object.get("seed") == null);
    const bare = try sentBody(arena, "local/model", "\"metadata\":{\"run\":\"1\"},\"user\":\"u\",\"safety_identifier\":\"s\",\"prompt_cache_key\":\"k\",\"session_id\":\"c\"", local_options);
    var keys: std.ArrayList([]const u8) = .empty;
    for (bare.object.keys()) |key| try keys.append(arena, key);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    try fixtures.expectJson(arena, "[\"messages\",\"model\",\"stream\",\"stream_options\"]", try foundation.json.encode(arena, keys.items));
}

test "a Chat Completions server is refused a deeper reasoning and any tool but a function, and fetches a text file as its text" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    try std.testing.expectEqual(vocabulary.FailureKind.invalid_request, (try fixtures.refusal(arena, "{\"model\":\"local/model\",\"input\":\"Hi\",\"reasoning\":{\"mode\":\"pro\"}}", local_options)).octoii.kind);
    try std.testing.expectEqual(vocabulary.FailureKind.invalid_request, (try fixtures.refusal(arena, "{\"model\":\"local/model\",\"input\":\"Hi\",\"tools\":[{\"type\":\"custom\",\"name\":\"patch\"}]}", local_options)).octoii.kind);
    var searching = local_options;
    searching.models = &.{.{ .id = "model", .octoii = .{ .hosted_tools = &.{.web_search} } }};
    const search = try fixtures.refusal(arena, "{\"model\":\"local/model\",\"input\":\"Hi\",\"tools\":[{\"type\":\"web_search\"}]}", searching);
    try std.testing.expect(std.mem.indexOf(u8, search.message, "functions alone") != null);
    try expectMember(arena, try sentBody(arena, "local/model", "\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_file\",\"file_url\":\"https://files.example.com/notes.md\"}]}]", local_options), "messages",
        \\[{"role":"user","content":[{"type":"text","text":"<file name=\"notes.md\">\nParis: 18 \u00b0C\n</file>"}]}]
    );
}

test "a Chat Completions server's responses hold its reasoning, its answer with log probabilities, its calls and its usage" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const text = try fixtures.streamFixture(arena, "text", local_options);
    const response = text.response;
    try std.testing.expectEqualStrings("chatcmpl-local-1", response.id);
    try std.testing.expectEqualStrings("local/qwen3.6-27b", response.octoii.?.model.?);
    try std.testing.expectEqual(@as(?u64, 18), response.octoii.?.context_tokens);
    try std.testing.expectEqualStrings("France's capital is Paris.", response.output[0].reasoning.content.?[0].text);
    const answer = response.output[1].output_message.content.parts[0].output_text;
    try std.testing.expectEqualStrings("Paris.", answer.text);
    try std.testing.expectEqual(@as(usize, 2), answer.logprobs.?.len);
    try std.testing.expectEqualStrings(".", answer.logprobs.?[1].token);
    for (text.events) |event| if (event == .output_text_delta) {
        try std.testing.expectEqualStrings("Paris", event.output_text_delta.logprobs[0].token);
        try std.testing.expectEqual(@as(f64, -0.01), event.output_text_delta.logprobs[0].logprob);
        break;
    };
    try fixtures.expectUsage(.{ .input = 18, .output = 12, .reasoning = 5 }, Usage.ofResponse(response));
    const called = (try fixtures.streamFixture(arena, "function-call", local_options)).response;
    try std.testing.expectEqualStrings("Two searches.", called.output[0].reasoning.content.?[0].text);
    var arguments: std.ArrayList([]const u8) = .empty;
    for (called.output) |item| if (item == .function_call) try arguments.append(arena, item.function_call.arguments);
    try fixtures.expectJson(arena, "[\"{\\\"query\\\":\\\"Paris\\\"}\",\"{\\\"query\\\":\\\"Lyon\\\"}\"]", try foundation.json.encode(arena, arguments.items));
    const twice = try createdTwice(arena, "function-call", local_options);
    const ids = try callIds(arena, &twice);
    try std.testing.expectEqual(@as(usize, 4), ids.len);
    try expectUnique(ids);
    const answered = (try fixtures.streamFixture(arena, "function-call-output", local_options)).response;
    try std.testing.expectEqualStrings("Paris is the capital; Lyon is on the Rh\u{f4}ne.", (try fixtures.messageText(arena, answered.output)).?);
    const used = Usage.ofResponse(answered);
    try std.testing.expectEqual(@as(?u64, 84), used.input);
    try std.testing.expectEqual(@as(?u64, 96), used.cache_read);
    try std.testing.expectEqual(@as(?u64, 14), used.output);
    const refused = (try fixtures.streamFixture(arena, "refusal", local_options)).response;
    try std.testing.expectEqual(.content_filter, refused.incomplete_details.?.reason.?);
    try std.testing.expectEqualStrings("I cannot help with that.", refused.output[0].output_message.content.parts[0].refusal.refusal);
}

test "a Chat Completions server's failures: in its stream, cut off, and refused before it" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const broken = try fixtures.streamFixture(arena, "mid-stream-error", local_options);
    const raised = broken.events[broken.events.len - 2].@"error";
    try std.testing.expectEqualStrings("server_error", raised.code);
    try std.testing.expectEqual(vocabulary.FailureKind.server, raised.octoii.kind);
    try std.testing.expect(raised.octoii.retryable);
    try std.testing.expectEqual(vocabulary.items.ItemStatus.incomplete, broken.response.output[0].output_message.status.?);
    try std.testing.expectEqualStrings("Hello! How", (try fixtures.messageText(arena, broken.response.output)).?);
    const cut = try fixtures.failureOf(arena, "cut-off", local_options);
    try std.testing.expectEqual(vocabulary.FailureKind.transport, cut.octoii.kind);
    try std.testing.expect(cut.octoii.retryable);
    const overflow = try fixtures.failureOf(arena, "context-overflow", local_options);
    try std.testing.expectEqual(vocabulary.FailureKind.context_overflow, overflow.octoii.kind);
    try std.testing.expectEqual(@as(?u16, 400), overflow.octoii.status);
    try std.testing.expectEqualStrings("exceed_context_size_error", overflow.code);
    const unauthorized = try fixtures.failureOf(arena, "unauthorized", local_options);
    try std.testing.expectEqual(vocabulary.FailureKind.auth, unauthorized.octoii.kind);
    try std.testing.expectEqualStrings("invalid_api_key", unauthorized.code);
    const limited = try fixtures.failureOf(arena, "rate-limited", local_options);
    try std.testing.expectEqual(vocabulary.FailureKind.rate_limit, limited.octoii.kind);
    try std.testing.expectEqual(@as(?u64, 1500), limited.octoii.retry_after_ms);
    try std.testing.expectEqualStrings("rate_limit_exceeded", limited.code);
}
