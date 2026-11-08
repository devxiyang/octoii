//! OpenAI's driver against its recorded exchanges, and its requests as OpenAI takes them.
const std = @import("std");
const vocabulary = @import("vocabulary");
const openai = @import("openai.zig");
const fixtures = @import("../testing/fixtures.zig");
const bundled = @import("../catalogue/catalogue.zig").bundled;
const Model = @import("../catalogue/model.zig").Model;
const Usage = vocabulary.Usage;

const options: fixtures.Options = .{ .driver = &openai.driver };

fn catalogueModel(arena: std.mem.Allocator, id: []const u8) !Model {
    for (try bundled(arena)) |model| if (std.mem.eql(u8, model.octoii.provider, "openai") and std.mem.eql(u8, model.id, id)) return model;
    return error.NotInCatalogue;
}

fn wire(arena: std.mem.Allocator, model: *const Model, json: []const u8) !std.json.Value {
    const request = try @import("foundation").json.decode(vocabulary.ResponsesRequest, arena, json);
    return std.json.parseFromSliceLeaky(std.json.Value, arena, try openai.wireRequest(arena, model, request), .{});
}

fn expectJson(arena: std.mem.Allocator, expected: []const u8, actual: std.json.Value) !void {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, expected, .{});
    if (!@import("foundation").json.equal(value, actual)) {
        std.debug.print("expected {s}\n   found {s}\n", .{ expected, try @import("foundation").json.encode(arena, actual) });
        return error.TestExpectedEqual;
    }
}

test "every recorded stream of OpenAI's is sent as recorded and holds to the stream's contract, carrying nothing of Octoii's" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const names = try fixtures.textNames(a, "openai");
    try std.testing.expect(names.len >= 14);
    for (names) |name| {
        const streamed = try fixtures.streamFixture(a, name, options);
        for (streamed.replay.sent.items, 0..) |_, index| {
            const body = try fixtures.sentBody(a, streamed.replay, index);
            for ([_][]const u8{ "octoii", "octoii:tool_removal", "signature", "format" }) |absent| try std.testing.expect(!fixtures.holds(body, absent));
            try std.testing.expect(body.object.get("stream").?.bool and !body.object.get("store").?.bool);
        }
    }
}

test "OpenAI is sent the key, asked for a stream, and refused before sending without one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const streamed = try fixtures.streamFixture(a, "text", options);
    const headers = streamed.replay.sent.items[0].headers;
    try std.testing.expectEqualStrings("Bearer test-key", @import("foundation").http.find(headers, "authorization").?);
    try std.testing.expectEqualStrings("text/event-stream", @import("foundation").http.find(headers, "accept").?);
    const fixture = try fixtures.load(a, "openai", "text");
    var keyless = options;
    keyless.key = null;
    const refused = try fixtures.stream(a, fixture.request, &.{}, keyless);
    try std.testing.expectEqual(vocabulary.FailureKind.auth, refused.response.@"error".?.octoii.kind);
    try std.testing.expect(std.mem.indexOf(u8, refused.response.@"error".?.message, "The provider openai has no API key") != null);
    try std.testing.expectEqual(@as(usize, 0), refused.replay.sent.items.len);
}

test "OpenAI is reached at a proxy's address" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const fixture = try fixtures.load(a, "openai", "text");
    const proxied = try a.dupe(@import("foundation").replay.Exchange, fixture.exchanges);
    for (proxied) |*exchange| exchange.request.url = "https://proxy.example/v1/responses";
    var proxy = options;
    proxy.settings = .{ .base_url = "https://proxy.example/v1" };
    const streamed = try fixtures.stream(a, fixture.request, proxied, proxy);
    try std.testing.expectEqual(vocabulary.response.ResponseStatus.completed, streamed.response.status);
}

test "OpenAI's request: caching only where the model takes it, its own reasoning, tools under its names, its own options" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const luna = try catalogueModel(a, "gpt-6-luna");
    var implicit = luna;
    implicit.id = "gpt-implicit";
    implicit.pricing.?.input_cache_write = null;
    const cached =
        \\{"model":"openai/gpt-implicit","prompt_cache_options":{"mode":"explicit","ttl":"12h"},
        \\ "input":[{"role":"user","content":[{"type":"input_text","text":"Hi","prompt_cache_breakpoint":{"mode":"explicit","ttl":"30m"}}]}]}
    ;
    try expectJson(a,
        \\{"model":"gpt-implicit","input":[{"role":"user","content":[{"type":"input_text","text":"Hi"}]}],"stream":true,"store":false}
    , try wire(a, &implicit, cached));
    const kept = try wire(a, &luna, cached);
    try std.testing.expect(kept.object.get("prompt_cache_options") != null);
    try std.testing.expect(fixtures.holds(kept, "prompt_cache_breakpoint"));

    try expectJson(a,
        \\[{"role":"user","content":"Hi"},{"type":"reasoning","id":"rs_2","summary":[],"encrypted_content":"gAAAA"},
        \\ {"type":"message","id":"msg_1","role":"assistant","content":"Hello","phase":"final_answer"},{"role":"user","content":"Again"}]
    , (try wire(a, &luna,
        \\{"model":"openai/gpt-6-luna","input":[{"role":"user","content":"Hi"},
        \\ {"type":"reasoning","id":"rs_1","summary":[],"status":"completed","octoii":{"model":"openai/gpt-6-luna"}},
        \\ {"type":"reasoning","id":"rs_2","summary":[],"encrypted_content":"gAAAA","format":"openai-responses-v1","octoii":{"model":"openai/gpt-6-luna"}},
        \\ {"type":"message","id":"msg_1","role":"assistant","content":"Hello","phase":"final_answer","octoii":{"model":"openai/gpt-6-luna"}},
        \\ {"role":"user","content":"Again"}]}
    )).object.get("input").?);

    try expectJson(a,
        \\[{"type":"function","name":"search","parameters":null},{"type":"function","name":"deploy","parameters":null,"defer_loading":true},{"type":"tool_search"}]
    , (try wire(a, &luna,
        \\{"model":"openai/gpt-6-luna","input":"Hi","tools":[{"type":"function","name":"search","parameters":null},
        \\ {"type":"function","name":"deploy","parameters":null,"defer_loading":true},{"type":"openrouter:tool_search"}]}
    )).object.get("tools").?);

    const own = try wire(a, &luna,
        \\{"model":"openai/gpt-6-luna","input":"Hi","provider":{"options":{"openai":{"prompt_cache_retention":"24h"},"anthropic":{"container":"c"}}}}
    );
    try std.testing.expectEqualStrings("24h", own.object.get("prompt_cache_retention").?.string);
    try std.testing.expect(!fixtures.holds(own, "container") and !fixtures.holds(own, "provider"));

    try expectJson(a,
        \\{"effort":"low","summary":"auto"}
    , (try wire(a, &luna,
        \\{"model":"openai/gpt-6-luna","input":"Hi","reasoning":{"effort":"low","enabled":true,"summary":"auto"}}
    )).object.get("reasoning").?);

    try expectJson(a,
        \\[{"role":"user","content":"Hi"},{"type":"additional_tools","role":"developer","tools":[{"type":"web_search"}]}]
    , (try wire(a, &luna,
        \\{"model":"openai/gpt-6-luna","input":[{"role":"user","content":"Hi"},
        \\ {"type":"additional_tools","role":"developer","tools":[{"type":"openrouter:web_search"}]}]}
    )).object.get("input").?);
}

test "a conversation another model wrote goes to OpenAI with its ids, reasoning and metadata off and its changes folded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const streamed = try fixtures.streamFixture(a, "crossing-models", options);
    try std.testing.expectEqual(vocabulary.response.ResponseStatus.completed, streamed.response.status);
    const body = try fixtures.sentBody(a, streamed.replay, 0);
    for ([_][]const u8{ "provider_metadata", "id", "reasoning_text", "additional_tools", "configuration_update", "cache_control", "trace" }) |absent| {
        try std.testing.expect(!fixtures.holds(body, absent));
    }
    try std.testing.expectEqualStrings("high", body.object.get("reasoning").?.object.get("effort").?.string);
}

test "what OpenAI does not take fails before anything is sent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var unlisted = try catalogueModel(a, "gpt-6-luna");
    unlisted.id = "gpt-6-luna-unlisted";
    unlisted.supported_parameters = null;
    var host = options;
    host.models = &.{@import("../catalogue/facts.zig").asFacts(unlisted)};
    const refused = [_][]const u8{
        \\{"top_k":40}
        ,
        \\{"stop":["END"]}
        ,
        \\{"stop_server_tools_when":[{"type":"step_count_is","step_count":3}]}
        ,
        \\{"deferred_tools":{"protocol":"v1","profile":"portable","validation":"runtime","search":{"type":"bm25"}}}
        ,
        \\{"service_tier":"flex"}
        ,
        \\{"tools":[{"type":"web_search","max_results":5}]}
        ,
        \\{"tools":[{"type":"web_search","filters":{"blocked_domains":["example.com"]}}]}
        ,
        \\{"tools":[{"type":"openrouter:web_search","parameters":{"engine":"exa"}}]}
        ,
        \\{"tools":[{"type":"openrouter:tool_search","parameters":{"max_results":3}},{"type":"function","name":"f","parameters":null}]}
        ,
        \\{"tools":[{"type":"function","name":"later","parameters":null,"async":true}]}
        ,
        \\{"models":["openai/gpt-6-sol"]}
        ,
        \\{"modalities":["text","image"]}
    };
    for (refused) |fields| {
        const json = try std.fmt.allocPrint(a, "{{\"model\":\"openai/gpt-6-luna-unlisted\",\"input\":\"Hi\",{s}", .{fields[1..]});
        const request = try @import("foundation").json.decode(vocabulary.ResponsesRequest, a, json);
        const streamed = try fixtures.stream(a, request, &.{}, host);
        try std.testing.expectEqual(vocabulary.FailureKind.invalid_request, streamed.response.@"error".?.octoii.kind);
        try std.testing.expectEqual(@as(usize, 0), streamed.replay.sent.items.len);
    }
    const top_k = try fixtures.stream(a, .{ .model = "openai/gpt-6-luna-unlisted", .input = .{ .text = "Hi" }, .top_k = 40 }, &.{}, host);
    try std.testing.expectEqualStrings("The provider openai does not take top_k: OpenAI's Responses API has no such field", top_k.response.@"error".?.message);
}

test "OpenAI's responses come back as they streamed: reasoning, text, calls, searches and cut answers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = try fixtures.streamFixture(a, "text", options);
    try std.testing.expectEqualStrings("openai/gpt-6-luna", text.response.octoii.?.model.?);
    const reasoning = text.response.output[0].reasoning;
    try std.testing.expectEqualStrings("The user asks for France's capital. It is Paris.", reasoning.summary.?[0].text);
    try std.testing.expectEqualStrings("gAAAAABpBFx3cmVhc29uaW5nLWVuY3J5cHRlZC1ieS1vcGVuYWk=", reasoning.encrypted_content.?);
    try std.testing.expectEqualStrings("The capital of France is Paris.", (try fixtures.messageText(a, text.response.output)).?);
    var deltas: std.ArrayList([]const u8) = .empty;
    for (text.events) |event| if (event == .output_text_delta) try deltas.append(a, event.output_text_delta.delta);
    try std.testing.expectEqualStrings("The capital| of France| is Paris.", try std.mem.join(a, "|", deltas.items));

    const call = (try fixtures.streamFixture(a, "function-call", options)).response.output[1].function_call;
    try std.testing.expectEqualStrings("call_Zp3kLq8vNx2Rt6Yw", call.call_id);
    try std.testing.expectEqualStrings("{\"city\":\"Paris\"}", call.arguments);
    const answered = try fixtures.streamFixture(a, "function-call-output", options);
    try std.testing.expectEqualStrings("It is 18 °C and sunny in Paris.", (try fixtures.messageText(a, answered.response.output)).?);
    // GPT-6 Luna: $0.10 a million read, $0.01 from the cache, $0.125 written into it, $0.50 a million written.
    try fixtures.expectUsage(.{ .input = 16, .cache_read = 1024, .cache_write = 256, .output = 14, .cost = 16 * 0.0000001 + 1024 * 0.00000001 + 256 * 0.000000125 + 14 * 0.0000005 }, Usage.ofResponse(answered.response));

    const search = (try fixtures.streamFixture(a, "web-search", options)).response;
    try std.testing.expectEqualStrings("OpenAI Responses API streaming", search.output[0].web_search_call.action.?.search.query);
    try std.testing.expectEqual(@as(?u64, 1), search.usage.?.server_tool_use_details.?.web_search_requests);
    try fixtures.expectUsage(.{ .input = 8417, .output = 64, .web_searches = 1, .cost = 8417 * 0.0000001 + 64 * 0.0000005 + 0.01 }, Usage.ofResponse(search));

    const cut = (try fixtures.streamFixture(a, "incomplete", options)).response;
    try std.testing.expectEqual(vocabulary.response.ResponseStatus.incomplete, cut.status);
    try std.testing.expectEqualStrings("Once upon a time there was", (try fixtures.messageText(a, cut.output)).?);
}

/// The failure the fixture `name` ends with.
fn failureOf(arena: std.mem.Allocator, name: []const u8) !vocabulary.response.ResponseError {
    const streamed = try fixtures.streamFixture(arena, name, options);
    try std.testing.expectEqual(vocabulary.response.ResponseStatus.failed, streamed.response.status);
    return streamed.response.@"error".?;
}

test "OpenAI's failures are classified by its codes, with the waits it asks for" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const auth = try failureOf(a, "unauthorized");
    try std.testing.expectEqual(vocabulary.FailureKind.auth, auth.octoii.kind);
    try std.testing.expectEqualStrings("invalid_api_key", auth.code);
    try std.testing.expectEqual(@as(?u16, 401), auth.octoii.status);
    const limited = try failureOf(a, "rate-limited");
    try std.testing.expectEqual(vocabulary.FailureKind.rate_limit, limited.octoii.kind);
    try std.testing.expect(limited.octoii.retryable);
    try std.testing.expectEqual(@as(?u64, 2400), limited.octoii.retry_after_ms);
    const quota = try failureOf(a, "quota");
    try std.testing.expectEqual(vocabulary.FailureKind.quota, quota.octoii.kind);
    try std.testing.expect(!quota.octoii.retryable);
    try std.testing.expectEqualStrings("credit_balance_exhausted", quota.code);
    const overflow = try failureOf(a, "context-overflow");
    try std.testing.expectEqual(vocabulary.FailureKind.context_overflow, overflow.octoii.kind);
    try std.testing.expect(std.mem.indexOf(u8, overflow.message, "(input)") != null);
    const overloaded = try failureOf(a, "overloaded");
    try std.testing.expectEqual(vocabulary.FailureKind.server, overloaded.octoii.kind);
    try std.testing.expectEqual(@as(?u64, 1500), overloaded.octoii.retry_after_ms);
    try std.testing.expectEqualStrings("server_is_overloaded", overloaded.code);
    const event = try failureOf(a, "error-event");
    try std.testing.expectEqual(vocabulary.FailureKind.rate_limit, event.octoii.kind);
    try std.testing.expectEqualStrings("rate_limit_exceeded", event.code);
    const policy = try failureOf(a, "policy");
    try std.testing.expectEqual(vocabulary.FailureKind.content_filter, policy.octoii.kind);
    try std.testing.expectEqualStrings("bio_policy", policy.code);
}

test "a response that failed in OpenAI's stream keeps what came before it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const streamed = try fixtures.streamFixture(a, "mid-stream-failure", options);
    const before = streamed.events[streamed.events.len - 2].@"error";
    try std.testing.expectEqualStrings("server_error", before.code);
    try std.testing.expectEqual(vocabulary.FailureKind.server, before.octoii.kind);
    const message = streamed.response.output[0].output_message;
    try std.testing.expectEqual(.incomplete, message.status.?);
    try std.testing.expectEqualStrings("Hello! How", message.content.parts[0].output_text.text);
}

test "OpenAI's tokens written into the cache for 12 hours are counted apart and priced at the hour's price" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const exchanges = try @import("foundation").json.decode([]const @import("foundation").replay.Exchange, a,
        \\[{"request":{"method":"POST","url":"https://api.openai.com/v1/responses","body":{"model":"gpt-6-luna","input":"Hi","stream":true,"store":false}},
        \\ "response":{"status":200,"chunks":[
        \\  "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\",\"object\":\"response\",\"status\":\"in_progress\",\"output\":[],\"error\":null,\"incomplete_details\":null,\"usage\":null},\"sequence_number\":0}\n\n",
        \\  "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"object\":\"response\",\"status\":\"completed\",\"output\":[],\"error\":null,\"incomplete_details\":null,\"usage\":{\"input_tokens\":2048,\"input_tokens_details\":{\"cached_tokens\":0,\"cache_write_tokens\":2048,\"cache_write_tokens_details\":{\"ttl_30m_tokens\":1024,\"ttl_12h_tokens\":1024}},\"output_tokens\":4,\"output_tokens_details\":{\"reasoning_tokens\":0},\"total_tokens\":2052}},\"sequence_number\":1}\n\n"]}}]
    );
    const streamed = try fixtures.stream(a, .{ .model = "openai/gpt-6-luna", .input = .{ .text = "Hi" } }, exchanges, options);
    try std.testing.expectEqual(@as(?[]const u8, null), streamed.replay.mismatch);
    try fixtures.expectUsage(.{ .cache_write = 1024, .cache_write_long = 1024, .output = 4, .cost = 1024 * 0.000000125 + 1024 * 0.00000025 + 4 * 0.0000005 }, Usage.ofResponse(streamed.response));
    try std.testing.expectEqual(@as(?u64, 2048), streamed.response.octoii.?.context_tokens);
}
