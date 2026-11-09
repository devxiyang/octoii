//! OpenRouter's driver against its recorded exchanges, and its requests as OpenRouter takes them.
const std = @import("std");
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const openrouter = @import("openrouter.zig");
const fixtures = @import("../testing/fixtures.zig");
const bundled = @import("../catalogue/catalogue.zig").bundled;
const Model = @import("../catalogue/model.zig").Model;
const Usage = vocabulary.Usage;

/// The time OpenRouter's fixtures were sent at: Wed, 28 Oct 2026 12:00:00 GMT.
const options: fixtures.Options = .{ .driver = &openrouter.driver, .now_ms = 1_793_188_800_000 };

/// The model the recorded text fixtures were sent to.
const flash = "openrouter/deepseek/deepseek-v4.1-flash-1017";

fn catalogueModel(arena: std.mem.Allocator, id: []const u8) !Model {
    for (try bundled(arena)) |model| if (std.mem.eql(u8, model.octoii.provider, "openrouter") and std.mem.eql(u8, model.id, id)) return model;
    return error.NotInCatalogue;
}

fn wire(arena: std.mem.Allocator, model: *const Model, json: []const u8) !std.json.Value {
    const request = try foundation.json.decode(vocabulary.ResponsesRequest, arena, json);
    return std.json.parseFromSliceLeaky(std.json.Value, arena, try openrouter.wireRequest(arena, model, request), .{});
}

fn expectJson(arena: std.mem.Allocator, expected: []const u8, actual: std.json.Value) !void {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, expected, .{});
    if (!foundation.json.equal(value, actual)) {
        std.debug.print("expected {s}\n   found {s}\n", .{ expected, try foundation.json.encode(arena, actual) });
        return error.TestExpectedEqual;
    }
}

test "every recorded stream of OpenRouter's is sent as recorded and holds to the stream's contract, carrying nothing of Octoii's" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const names = try fixtures.textNames(arena, "openrouter");
    try std.testing.expect(names.len >= 15);
    for (names) |name| {
        const streamed = try fixtures.streamFixture(arena, name, options);
        for (streamed.replay.sent.items, 0..) |_, index| {
            const body = try fixtures.sentBody(arena, streamed.replay, index);
            for ([_][]const u8{ "octoii", "octoii:tool_removal", "signature" }) |absent| try std.testing.expect(!fixtures.holds(body, absent));
        }
    }
}

test "OpenRouter is sent the key, asked for a stream, reached at a proxy, and refused before sending without a key" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const streamed = try fixtures.streamFixture(arena, "text", options);
    const headers = streamed.replay.sent.items[0].headers;
    try std.testing.expectEqualStrings("Bearer test-key", foundation.http.find(headers, "authorization").?);
    try std.testing.expectEqualStrings("text/event-stream", foundation.http.find(headers, "accept").?);
    const fixture = try fixtures.load(arena, "openrouter", "text");
    const proxied = try arena.dupe(foundation.replay.Exchange, fixture.exchanges);
    for (proxied) |*exchange| exchange.request.url = "https://proxy.example/v1/responses";
    var proxy = options;
    proxy.settings = .{ .base_url = "https://proxy.example/v1" };
    try std.testing.expectEqual(vocabulary.response.ResponseStatus.completed, (try fixtures.stream(arena, fixture.request, proxied, proxy)).response.status);
    var keyless = options;
    keyless.key = null;
    const refused = try fixtures.stream(arena, fixture.request, &.{}, keyless);
    try std.testing.expectEqual(vocabulary.FailureKind.auth, refused.response.@"error".?.octoii.kind);
    try std.testing.expectEqual(@as(usize, 0), refused.replay.sent.items.len);
}

test "OpenRouter's request: the model by its id, every parameter required unless asked otherwise, automatic caching" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const luna = try catalogueModel(arena, "openai/gpt-6-luna");
    try expectJson(arena,
        \\{"model":"openai/gpt-6-luna","input":"Hi","provider":{"require_parameters":true},"cache_control":{"type":"ephemeral"},"stream":true}
    , try wire(arena, &luna,
        \\{"model":"openrouter/openai/gpt-6-luna","input":"Hi"}
    ));
    try expectJson(arena,
        \\{"require_parameters":false,"sort":"price"}
    , (try wire(arena, &luna,
        \\{"model":"openrouter/openai/gpt-6-luna","input":"Hi","provider":{"require_parameters":false,"sort":"price"}}
    )).object.get("provider").?);
    try expectJson(arena,
        \\{"type":"ephemeral","ttl":"1h"}
    , (try wire(arena, &luna,
        \\{"model":"openrouter/openai/gpt-6-luna","input":"Hi","cache_control":{"type":"ephemeral","ttl":"1h"}}
    )).object.get("cache_control").?);
    const explicit = try wire(arena, &luna,
        \\{"model":"openrouter/openai/gpt-6-luna","input":"Hi","prompt_cache_options":{"mode":"explicit","ttl":"12h"}}
    );
    try std.testing.expectEqual(null, explicit.object.get("cache_control"));
    try expectJson(arena,
        \\[{"type":"additional_tools","role":"developer","tools":[{"type":"function","name":"search"}]},{"role":"user","content":"Search"}]
    , (try wire(arena, &luna,
        \\{"model":"openrouter/openai/gpt-6-luna","input":[{"type":"additional_tools","role":"developer","tools":[{"type":"function","name":"search","parameters":null}]},{"role":"user","content":"Search"}]}
    )).object.get("input").?);
}

test "an effort changed where it stands goes to OpenRouter as it is for a model that takes it, folded into the request's for one that does not" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var model = try catalogueModel(arena, "openai/gpt-6-luna");
    const asked =
        \\{"model":"openrouter/deepseek/deepseek-v4.1-flash","reasoning":{"effort":"high"},"input":[
        \\{"type":"message","role":"user","content":"one"},
        \\{"type":"configuration_update","reasoning":{"effort":"low"}},
        \\{"type":"message","role":"user","content":"two"}]}
    ;
    model.octoii.features = .{ .effort_updates = false };
    const folded = try wire(arena, &model, asked);
    try std.testing.expectEqualStrings("low", folded.object.get("reasoning").?.object.get("effort").?.string);
    try std.testing.expectEqual(@as(usize, 2), folded.object.get("input").?.array.items.len);
    model.octoii.features = .{ .effort_updates = true };
    const kept = try wire(arena, &model, asked);
    try std.testing.expectEqualStrings("high", kept.object.get("reasoning").?.object.get("effort").?.string);
    try std.testing.expectEqualStrings("configuration_update", kept.object.get("input").?.array.items[1].object.get("type").?.string);
}

test "a conversation another provider wrote goes to OpenRouter with its tool removal folded and ids on its items" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const streamed = try fixtures.streamFixture(arena, "crossing-models", options);
    try std.testing.expectEqual(vocabulary.response.ResponseStatus.completed, streamed.response.status);
    const body = try fixtures.sentBody(arena, streamed.replay, 0);
    for ([_][]const u8{ "additional_tools", "reasoning", "provider_metadata", "encrypted_content" }) |absent| try std.testing.expect(!fixtures.holds(body, absent));
    const tools = body.object.get("tools").?.array.items;
    try std.testing.expectEqualStrings("read_file", tools[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("search", tools[1].object.get("name").?.string);
    const input = body.object.get("input").?.array.items;
    try std.testing.expectEqualStrings("msg_1", input[1].object.get("id").?.string);
    try std.testing.expectEqualStrings("completed", input[1].object.get("status").?.string);
    try std.testing.expectEqualStrings("fc_toolu_01A9xQ", input[2].object.get("id").?.string);
}

test "OpenRouter's responses come back as they streamed: reasoning, text, cost, calls, files and searches" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const text = (try fixtures.streamFixture(arena, "text", options));
    const response = text.response;
    try std.testing.expectEqualStrings(flash, response.octoii.?.model.?);
    const reasoning = response.output[0].reasoning;
    try std.testing.expectEqualStrings("We need answer one sentence. Capital France Paris. Need concise.", reasoning.content.?[0].text);
    try std.testing.expectEqualStrings(flash, reasoning.octoii.?.model.?);
    try std.testing.expectEqualStrings("The capital of France is Paris.", (try fixtures.messageText(arena, response.output)).?);
    try std.testing.expectEqual(@as(?f64, 0.000010274), response.usage.?.cost);
    const usage = Usage.ofResponse(response);
    try std.testing.expectEqual(@as(?u64, 42), usage.input);
    try std.testing.expectEqual(@as(?u64, 22), usage.output);
    try std.testing.expectEqual(@as(?u64, 16), usage.reasoning);
    // A response of the Responses API is one request: the tokens its context took are the input its usage counts.
    try std.testing.expectEqual(@as(?u64, 42), response.octoii.?.context_tokens);

    const call = (try fixtures.streamFixture(arena, "function-call", options)).response.output[0].function_call;
    try std.testing.expectEqualStrings("chatcmpl-tool-a34382f81852033c", call.call_id);
    try std.testing.expectEqualStrings("{\"city\": \"Paris\"}", call.arguments);
    const answered = (try fixtures.streamFixture(arena, "function-call-output", options)).response;
    try std.testing.expect(std.mem.indexOf(u8, (try fixtures.messageText(arena, answered.output)).?, "18°C and sunny") != null);

    const files = try fixtures.streamFixture(arena, "files", options);
    const body = try fixtures.sentBody(arena, files.replay, 0);
    try std.testing.expect(fixtures.holds(body, "input_image") and fixtures.holds(body, "input_file"));
    try std.testing.expect(std.mem.indexOf(u8, (try fixtures.messageText(arena, files.response.output)).?, "The meeting is on Friday.") != null);

    const search = (try fixtures.streamFixture(arena, "web-search", options)).response;
    var searches: std.ArrayList(vocabulary.items.OpenRouterWebSearchCall) = .empty;
    for (search.output) |item| if (item == .openrouter_web_search) try searches.append(arena, item.openrouter_web_search);
    try std.testing.expectEqual(@as(usize, 2), searches.items.len);
    try std.testing.expectEqual(vocabulary.items.HostedToolStatus.completed, searches.items[0].status);
    try std.testing.expectEqualStrings("OpenRouter Responses API", searches.items[0].action.?.query);
    try std.testing.expectEqual(@as(?u64, 2), Usage.ofResponse(search).web_searches);
}

/// The failure the fixture `name` ends with.
fn failureOf(arena: std.mem.Allocator, name: []const u8) !vocabulary.response.ResponseError {
    const streamed = try fixtures.streamFixture(arena, name, options);
    try std.testing.expectEqual(vocabulary.response.ResponseStatus.failed, streamed.response.status);
    return streamed.response.@"error".?;
}

test "OpenRouter's failures are classified by their status, error type and budget, carrying a routed provider's words" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const auth = try failureOf(arena, "unauthorized");
    try std.testing.expectEqual(vocabulary.FailureKind.auth, auth.octoii.kind);
    try std.testing.expectEqualStrings("No auth credentials found", auth.message);
    const terms = try failureOf(arena, "terms-of-service");
    try std.testing.expectEqual(vocabulary.FailureKind.forbidden, terms.octoii.kind);
    try std.testing.expectEqualStrings("The request is prohibited due to a violation of provider Terms Of Service.", terms.message);
    const refused = try failureOf(arena, "provider-refused");
    try std.testing.expectEqual(vocabulary.FailureKind.invalid_request, refused.octoii.kind);
    try std.testing.expectEqualStrings("Provider returned error (Meta: failed to parse PDF at input[0].content[2]: invalid PDF input: PdfiumError('Failed to load document (PDFium: Data format error).'))", refused.message);
    try std.testing.expectEqual(vocabulary.FailureKind.quota, (try failureOf(arena, "payment-required")).octoii.kind);
    const budget = try failureOf(arena, "budget-spent");
    try std.testing.expectEqual(vocabulary.FailureKind.quota, budget.octoii.kind);
    try std.testing.expectEqual(@as(?u16, 403), budget.octoii.status);
    const limited = try failureOf(arena, "rate-limited");
    try std.testing.expectEqual(vocabulary.FailureKind.rate_limit, limited.octoii.kind);
    try std.testing.expectEqual(@as(?u64, 60_000), limited.octoii.retry_after_ms);
    try std.testing.expectEqualStrings("rate_limit_exceeded", limited.code);
    const unavailable = try failureOf(arena, "unavailable");
    try std.testing.expectEqual(vocabulary.FailureKind.server, unavailable.octoii.kind);
    try std.testing.expectEqual(@as(?u64, 90_000), unavailable.octoii.retry_after_ms);
    const only = try failureOf(arena, "error-only");
    try std.testing.expectEqual(vocabulary.FailureKind.rate_limit, only.octoii.kind);
    try std.testing.expectEqualStrings("rate_limit_exceeded", only.code);
    const overflow = try failureOf(arena, "context-overflow");
    try std.testing.expectEqual(vocabulary.FailureKind.context_overflow, overflow.octoii.kind);
    try std.testing.expect(!overflow.octoii.retryable);
}

test "a failure in OpenRouter's stream is classified by its error type, keeping what came before it" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const streamed = try fixtures.streamFixture(arena, "mid-stream-error", options);
    const before = streamed.events[streamed.events.len - 2].@"error";
    try std.testing.expectEqualStrings("server_error", before.code);
    try std.testing.expectEqual(vocabulary.FailureKind.server, before.octoii.kind);
    const failed = streamed.response;
    try std.testing.expectEqual(vocabulary.response.ErrorType.provider_unavailable, failed.error_type.?);
    try std.testing.expectEqual(@as(?f64, 0.0000024), failed.usage.?.cost);
    const message = failed.output[0].output_message;
    try std.testing.expectEqual(.incomplete, message.status.?);
    try std.testing.expectEqualStrings("Hello! How", message.content.parts[0].output_text.text);
}

test "a failure in the stream passed on from a provider carries its words" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const exchanges = try foundation.json.decode([]const foundation.replay.Exchange, arena,
        \\[{"request":{"method":"POST","url":"https://openrouter.ai/api/v1/responses","body":{"model":"openai/gpt-6-luna","input":"Hello",
        \\  "provider":{"require_parameters":true},"cache_control":{"type":"ephemeral"},"stream":true}},
        \\ "response":{"status":200,"headers":{"content-type":"text/event-stream"},"chunks":[
        \\  "data: {\"type\":\"response.error\",\"error\":{\"code\":\"invalid_prompt\",\"message\":\"Provider returned error\",\"metadata\":{\"raw\":\"{\\\"error\\\":{\\\"message\\\":\\\"The image is not valid.\\\"}}\",\"provider_name\":\"Meta\"}},\"sequence_number\":0}\n\ndata: [DONE]\n\n"]}}]
    );
    const streamed = try fixtures.stream(arena, .{ .model = "openrouter/openai/gpt-6-luna", .input = .{ .text = "Hello" } }, exchanges, options);
    try std.testing.expectEqual(@as(?[]const u8, null), streamed.replay.mismatch);
    const failed = streamed.response.@"error".?;
    try std.testing.expectEqual(vocabulary.FailureKind.invalid_request, failed.octoii.kind);
    try std.testing.expectEqualStrings("Provider returned error (Meta: The image is not valid.)", failed.message);
}

test "OpenRouter's responses keep the cost it reports, and are priced from the catalogue where it reports none" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const fixture = try fixtures.load(arena, "openrouter", "files");
    const unreported = try arena.dupe(foundation.replay.Exchange, fixture.exchanges);
    for (unreported) |*exchange| {
        const chunks = try arena.dupe(foundation.replay.Chunk, exchange.response.chunks);
        for (chunks) |*chunk| if (chunk.* == .text) {
            chunk.* = .{ .text = try std.mem.replaceOwned(u8, arena, chunk.text, "\"cost\":0.0057825,", "") };
            try std.testing.expect(std.mem.indexOf(u8, chunk.text, "\"cost\":") == null);
        };
        exchange.response.chunks = chunks;
    }
    const priced = try fixtures.stream(arena, fixture.request, unreported, options);
    // Muse Spark 1.3 at OpenRouter: $1.25 a million tokens read, $4.25 a million written.
    try std.testing.expectApproxEqAbs(@as(f64, 2535 * 0.00000125 + 615 * 0.00000425), priced.response.usage.?.cost.?, 1e-12);
    const search = (try fixtures.streamFixture(arena, "web-search", options)).response;
    try std.testing.expectEqual(@as(?f64, 0.016416095), search.usage.?.cost);
}
