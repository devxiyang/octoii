//! xAI's, DeepSeek's and Meta's drivers, the Responses API as each serves it, against their recorded exchanges.
const std = @import("std");
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const Usage = vocabulary.Usage;
const fixtures = @import("../testing/fixtures.zig");
const xai = @import("xai.zig");
const deepseek = @import("deepseek.zig");
const meta = @import("meta.zig");

/// Wed, 28 Oct 2026 12:00:00 GMT, when the fixtures were sent.
const fixtures_time: i64 = 1_793_188_800_000;
const xai_options: fixtures.Options = .{ .driver = &xai.driver, .now_ms = fixtures_time };
const deepseek_options: fixtures.Options = .{ .driver = &deepseek.driver, .now_ms = fixtures_time };

const catalogueModel = fixtures.catalogueModel;
const decoded = fixtures.decoded;
const expectJson = fixtures.expectJson;
const requestWith = fixtures.requestWith;
const failureOf = fixtures.failureOf;
const refusal = fixtures.refusal;

test "every recorded text stream of xAI's and DeepSeek's is sent as recorded and holds to the stream's contract" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    for ([_]fixtures.Options{ xai_options, deepseek_options }) |options| {
        const names = try fixtures.textNames(arena, options.driver.id);
        try std.testing.expect(names.len >= 10);
        for (names) |name| {
            const streamed = try fixtures.streamFixture(arena, name, options);
            for (streamed.replay.sent.items, 0..) |sent, index| if (sent.body != null) {
                const body = try fixtures.sentBody(arena, streamed.replay, index);
                try std.testing.expect(!fixtures.holds(body, "octoii"));
            };
        }
    }
}

test "xAI's request: the model by its id, nothing kept, its encrypted reasoning asked for, what changes nothing left out" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const grok = try catalogueModel(arena, "xai", "grok-4.7");
    try expectJson(arena, "{\"model\":\"grok-4.7\",\"input\":\"Hi\",\"store\":false,\"include\":[\"reasoning.encrypted_content\"],\"stream\":true}", try xai.wireRequest(arena, &grok, try decoded(arena, "{\"model\":\"xai/grok-4.7\",\"input\":\"Hi\"}")));
    var plain = grok;
    plain.id = "grok-plain";
    plain.reasoning = null;
    plain.supported_parameters = &.{"tools"};
    try expectJson(arena, "{\"model\":\"grok-plain\",\"input\":\"Hi\",\"store\":false,\"stream\":true}", try xai.wireRequest(arena, &plain, try decoded(arena, "{\"model\":\"xai/grok-plain\",\"input\":\"Hi\"}")));
    try expectJson(arena,
        \\{"model":"grok-4.7","input":"Hi","reasoning":{"effort":"medium"},"prompt_cache_key":"conv_abc123","safety_identifier":"user-1","user":"user-1",
        \\ "service_tier":"priority","max_output_tokens":2000,"temperature":0.7,"store":false,"include":["reasoning.encrypted_content"],"stream":true}
    , try xai.wireRequest(arena, &grok, try decoded(arena,
        \\{"model":"xai/grok-4.7","input":"Hi","reasoning":{"effort":"medium","summary":"detailed","context":"auto","mode":"standard","enabled":true},
        \\ "prompt_cache_key":"conv_abc123","safety_identifier":"user-1","user":"user-1","service_tier":"priority","metadata":{"purpose":"test"},
        \\ "truncation":"disabled","cache_control":{"type":"ephemeral","ttl":"1h"},"prompt_cache_options":{"mode":"explicit","ttl":"12h"},
        \\ "session_id":"session-1","trace":{"trace_id":"trace-1"},"debug":{"echo_upstream_body":true},"max_output_tokens":2000,"temperature":0.7,
        \\ "include":["reasoning.encrypted_content"]}
    )));
    const tools = try std.json.parseFromSliceLeaky(std.json.Value, arena, try xai.wireRequest(arena, &grok, try decoded(arena,
        \\{"model":"xai/grok-4.7","input":"Hi","tools":[{"type":"function","name":"get_weather","description":"The weather now.","parameters":{"type":"object"},"strict":true,"allowed_callers":["direct"]},
        \\ {"type":"web_search_2025_08_26","filters":{"blocked_domains":["example.com"]}}],"provider":{"options":{"xai":{"max_turns":3},"deepseek":{"thinking":false}}}}
    )), .{});
    try std.testing.expectEqual(@as(i64, 3), tools.object.get("max_turns").?.integer);
    try std.testing.expect(tools.object.get("thinking") == null and tools.object.get("provider") == null);
    try expectJson(arena,
        \\[{"type":"function","name":"get_weather","description":"The weather now.","parameters":{"type":"object"},"strict":true},{"type":"web_search","filters":{"excluded_domains":["example.com"]}}]
    , try foundation.json.encode(arena, tools.object.get("tools").?));
}

test "xAI refuses before anything is sent what it would ignore, and reads text files as text" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const refused = [_]struct { []const u8, []const u8 }{
        .{ "\"temperature\":1.5", "temperature above 1" },
        .{ "\"top_p\":0.99", "top_p above 0.95" },
        .{ "\"max_tool_calls\":3", "max_tool_calls" },
        .{ "\"include\":[\"message.input_image.image_url\"]", "include message.input_image.image_url" },
        .{ "\"reasoning\":{\"mode\":\"pro\"}", "reasoning mode pro" },
        .{ "\"service_tier\":\"flex\"", "service tier flex" },
        .{ "\"tools\":[{\"type\":\"openrouter:web_search\"}]", "OpenRouter's web search" },
        .{ "\"tools\":[{\"type\":\"web_search\",\"user_location\":{\"country\":\"FR\"}}]", "user_location" },
        .{ "\"tools\":[{\"type\":\"web_search\",\"filters\":{\"allowed_domains\":[\"a.com\"],\"excluded_domains\":[\"b.com\"]}}]", "both allows and excludes" },
        .{ "\"tools\":[{\"type\":\"custom\",\"name\":\"apply_patch\"}]", "custom tools" },
        .{ "\"truncation\":\"auto\"", "truncation" },
        .{ "\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_image\",\"detail\":\"auto\",\"image_url\":\"data:image/gif;base64,R0lGODlhAQABAAAAACw=\"}]}]", "is image/gif" },
        .{ "\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_file\",\"filename\":\"a.pdf\",\"file_data\":\"data:application/pdf;base64,JVBERi0xLjc=\"}]}]", "document search" },
    };
    for (refused) |case| {
        const failed = try refusal(arena, try requestWith(arena, "xai/grok-4.7", case[0]), xai_options);
        try std.testing.expectEqual(vocabulary.FailureKind.invalid_request, failed.octoii.kind);
        if (std.mem.indexOf(u8, failed.message, case[1]) == null) {
            std.debug.print("{s}: {s}\n", .{ case[0], failed.message });
            return error.TestUnexpectedMessage;
        }
    }
    const text_file = try fixtures.streamFixture(arena, "text-file", xai_options);
    const body = try fixtures.sentBody(arena, text_file.replay, 0);
    try std.testing.expect(!fixtures.holds(body, "input_file") and !fixtures.holds(body, "prompt_cache_breakpoint") and fixtures.holds(body, "input_image"));
}

test "xAI's responses: cost from its ticks, reasoning in the output, the last step's context priced" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const text = (try fixtures.streamFixture(arena, "text", xai_options)).response;
    try std.testing.expectEqual(@as(?u64, 32), text.octoii.?.context_tokens);
    try std.testing.expectEqualStrings("gAAAAAB-xai-encrypted-reasoning-0001", text.output[0].reasoning.encrypted_content.?);
    try std.testing.expectEqualStrings("101 multiplied by 3 is 303.", (try fixtures.messageText(arena, text.output)).?);
    try fixtures.expectUsage(.{ .input = 24, .cache_read = 8, .output = 119, .reasoning = 110, .cost = 0.000766 }, Usage.ofResponse(text));
    const long = (try fixtures.streamFixture(arena, "long-context", xai_options)).response;
    try std.testing.expectEqual(@as(?u64, 215_000), long.octoii.?.context_tokens);
    // Grok 4.7 past 200,000 tokens: $4 a million read, $1 a million read from the cache, $12 a million written.
    try std.testing.expectApproxEqAbs(@as(f64, 230_000 * 0.000004 + 200_000 * 0.000001 + 312 * 0.000012), long.usage.?.cost.?, 1e-9);
    const search = (try fixtures.streamFixture(arena, "web-search", xai_options)).response;
    try std.testing.expectEqualStrings("SpaceXSI", search.output[0].web_search_call.action.?.search.query);
    try fixtures.expectUsage(.{ .web_searches = 1, .input = 2230, .cache_read = 1980, .output = Usage.ofResponse(search).output, .reasoning = Usage.ofResponse(search).reasoning, .cost = 0.001338 }, Usage.ofResponse(search));
    const auth = try failureOf(arena, "unauthorized", xai_options);
    try std.testing.expectEqual(vocabulary.FailureKind.auth, auth.octoii.kind);
    try std.testing.expect(std.mem.indexOf(u8, auth.message, "Incorrect API key provided") != null);
    try std.testing.expectEqual(@as(?u64, 30_000), (try failureOf(arena, "rate-limited", xai_options)).octoii.retry_after_ms);
    try std.testing.expectEqual(vocabulary.FailureKind.context_overflow, (try failureOf(arena, "context-overflow", xai_options)).octoii.kind);
    try std.testing.expectEqual(vocabulary.FailureKind.server, (try failureOf(arena, "server-error", xai_options)).octoii.kind);
    const mid = try fixtures.streamFixture(arena, "mid-stream-error", xai_options);
    try std.testing.expectEqualStrings("internal_error", mid.response.@"error".?.code);
    try std.testing.expectEqualStrings("Hello! How", mid.response.output[0].output_message.content.parts[0].output_text.text);
}

test "DeepSeek's request: the model by its id, developer messages as system ones, what changes nothing left out" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const flash = try catalogueModel(arena, "deepseek", "deepseek-flash");
    try expectJson(arena, "{\"model\":\"deepseek-flash\",\"input\":\"Hi\",\"stream\":true}", try deepseek.wireRequest(arena, &flash, try decoded(arena,
        \\{"model":"deepseek/deepseek-flash","input":"Hi","truncation":"disabled","cache_control":{"type":"ephemeral"},"prompt_cache_options":{"mode":"explicit"},"session_id":"session-1","trace":{"trace_id":"trace-1"},"store":false}
    )));
    const crossing = try fixtures.streamFixture(arena, "crossing-models", deepseek_options);
    const body = try fixtures.sentBody(arena, crossing.replay, 0);
    try std.testing.expect(!fixtures.holds(body, "developer") and !fixtures.holds(body, "additional_tools") and !fixtures.holds(body, "configuration_update"));
    const refused = [_]struct { []const u8, []const u8 }{
        .{ "\"include\":[\"reasoning.encrypted_content\"]", "include reasoning.encrypted_content" },
        .{ "\"service_tier\":\"default\"", "service tier default" },
        .{ "\"tools\":[{\"type\":\"custom\",\"name\":\"edit\"}]", "only as apply_patch" },
        .{ "\"input\":[{\"role\":\"system\",\"content\":[{\"type\":\"input_image\",\"detail\":\"auto\",\"image_url\":\"https://example.com/a.png\"}]}]", "reads images only from users and functions" },
        .{ "\"temperature\":0.5", "ignores temperature while it reasons" },
        .{ "\"top_p\":0.9,\"reasoning\":{\"effort\":\"none\"}", "ignores top_p while it does not reason" },
        .{ "\"truncation\":\"auto\"", "truncation" },
    };
    for (refused) |case| {
        const failed = try refusal(arena, try requestWith(arena, "deepseek/deepseek-flash", case[0]), deepseek_options);
        if (std.mem.indexOf(u8, failed.message, case[1]) == null) {
            std.debug.print("{s}: {s}\n", .{ case[0], failed.message });
            return error.TestUnexpectedMessage;
        }
    }
}

test "DeepSeek's responses: reasoning with its text, off-peak and peak prices, searches counted, its failures classified" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const text = (try fixtures.streamFixture(arena, "text", deepseek_options)).response;
    try std.testing.expectEqualStrings("9.11 and 9.8: compare the tenths. 8 is more than 1, so 9.8 is greater.", text.output[0].reasoning.content.?[0].text);
    try std.testing.expectEqualStrings("9.8 is greater than 9.11.", (try fixtures.messageText(arena, text.output)).?);
    const off_peak = 24 * 0.00000015 + 46 * 0.0000006;
    try std.testing.expectApproxEqAbs(@as(f64, off_peak), text.usage.?.cost.?, 1e-12);
    var peak = deepseek_options;
    // Wed, 28 Oct 2026 02:00:00 GMT, within a weekday's peak window; Sat, 31 Oct 2026 02:00:00 GMT, a weekend's.
    peak.now_ms = 1_793_152_800_000;
    try std.testing.expectApproxEqAbs(@as(f64, 2 * off_peak), (try fixtures.streamFixture(arena, "text", peak)).response.usage.?.cost.?, 1e-12);
    peak.now_ms = 1_793_412_000_000;
    try std.testing.expectApproxEqAbs(@as(f64, off_peak), (try fixtures.streamFixture(arena, "text", peak)).response.usage.?.cost.?, 1e-12);
    const search = (try fixtures.streamFixture(arena, "web-search", deepseek_options)).response;
    try std.testing.expectEqual(@as(?u64, 2), search.usage.?.server_tool_use_details.?.web_search_requests);
    try std.testing.expectApproxEqAbs(@as(f64, 3120 * 0.00000066 + 61 * 0.00000198 + 2 * 0.00075), search.usage.?.cost.?, 1e-12);
    const patch = (try fixtures.streamFixture(arena, "apply-patch", deepseek_options)).response.output[0].custom_tool_call;
    try std.testing.expectEqualStrings("apply_patch", patch.name);
    try std.testing.expect(std.mem.indexOf(u8, patch.input, "+Buy oat milk.") != null);
    try std.testing.expectEqual(vocabulary.FailureKind.quota, (try failureOf(arena, "insufficient-balance", deepseek_options)).octoii.kind);
    try std.testing.expectEqual(vocabulary.FailureKind.invalid_request, (try failureOf(arena, "invalid-parameters", deepseek_options)).octoii.kind);
    const limited = try failureOf(arena, "rate-limited", deepseek_options);
    try std.testing.expectEqual(@as(?u64, 5000), limited.octoii.retry_after_ms);
    try std.testing.expectEqualStrings("rate_limit_exceeded", limited.code);
    try std.testing.expectEqual(vocabulary.FailureKind.context_overflow, (try failureOf(arena, "context-overflow", deepseek_options)).octoii.kind);
    try std.testing.expectEqualStrings("server_error", (try failureOf(arena, "failed-response", deepseek_options)).code);
}

test "Meta's request goes kept nowhere, asking for its reasoning's encrypted content, and its failures are classified" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const options: fixtures.Options = .{ .driver = &meta.driver };
    const down = try fixtures.answeredWith(arena, try decoded(arena, "{\"model\":\"meta/muse-spark-1.3\",\"input\":\"Hi\",\"reasoning\":{\"effort\":\"high\"}}"), .{
        .arena = arena,
        .status = 500,
        .content_type = "application/json",
        .chunks = &.{"{\"error\":{\"message\":\"Down\",\"type\":\"server_error\",\"code\":null}}"},
    }, options);
    try std.testing.expectEqualStrings("https://api.meta.ai/v1/responses", down.sent[0].url);
    try std.testing.expectEqualStrings("Bearer test-key", foundation.http.find(down.sent[0].headers, "authorization").?);
    const body = try std.json.parseFromSliceLeaky(std.json.Value, arena, down.sent[0].body.?, .{});
    try expectJson(arena, "[\"reasoning.encrypted_content\"]", try foundation.json.encode(arena, body.object.get("include").?));
    try std.testing.expect(!body.object.get("store").?.bool);
    const cases = [_]struct { u16, []const u8, vocabulary.FailureKind }{
        .{ 401, "{\"error\":{\"message\":\"Invalid key\",\"type\":\"authentication_error\",\"code\":\"invalid_api_key\"}}", .auth },
        .{ 402, "{\"error\":{\"message\":\"Set up billing\",\"type\":\"billing_error\",\"code\":\"billing_not_configured\"}}", .quota },
        .{ 503, "{\"error\":{\"message\":\"Overloaded\",\"type\":\"server_error\",\"code\":\"service_overloaded\"}}", .server },
        .{ 400, "{\"error\":{\"message\":\"You passed 1200000 input tokens. However, the model's context length is only 1048576 tokens.\",\"type\":\"invalid_request_error\",\"code\":null}}", .context_overflow },
    };
    for (cases) |case| {
        const answered = try fixtures.answeredWith(arena, try decoded(arena, "{\"model\":\"meta/muse-spark-1.3\",\"input\":\"Hi\"}"), .{ .arena = arena, .status = case[0], .content_type = "application/json", .chunks = &.{case[1]} }, options);
        try std.testing.expectEqual(case[2], answered.response.@"error".?.octoii.kind);
    }
    const refused = try refusal(arena, "{\"model\":\"meta/muse-spark-1.3\",\"input\":\"Hi\",\"top_k\":3}", options);
    try std.testing.expectEqual(vocabulary.FailureKind.invalid_request, refused.octoii.kind);
}
