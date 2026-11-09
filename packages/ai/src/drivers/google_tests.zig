//! Google's driver, the Interactions API, against its recorded exchanges and what its requests become on the wire.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const Usage = vocabulary.Usage;
const FailureKind = vocabulary.FailureKind;
const seam = @import("../driver.zig");
const Failure = @import("../failure.zig").Failure;
const fixtures = @import("../testing/fixtures.zig");
const TestHost = @import("../testing/host.zig").Host;
const google = @import("google.zig");

const options: fixtures.Options = .{ .driver = &google.driver, .key = "AIzaSy-test" };

const flash = "google/gemini-3.8-flash";

/// What a request becomes on the wire, without `store` and `stream`, which every request goes with; or the failure
/// it fails with before anything is sent.
const Wired = union(enum) { body: Value, failure: Failure };

/// The interaction `fields` ask the catalogue's `id` for, made directly, its files fetched from the test's file server.
fn wired(arena: Allocator, fields: []const u8, id: []const u8) !Wired {
    const model = try fixtures.catalogueModel(arena, "google", id);
    const file_server = try arena.create(fixtures.Answering);
    file_server.* = .{ .arena = arena, .chunks = &.{} };
    const test_host = try arena.create(TestHost);
    test_host.* = .{ .keys = &.{.{ .provider = "google", .key = "AIzaSy-test" }} };
    const host = try arena.create(seam.Host);
    host.* = test_host.host(file_server.http());
    const provider = try arena.create(seam.Provider);
    provider.* = .{ .id = "google", .name = "Google", .driver = &google.driver };
    var call: seam.Call = .{ .arena = arena, .provider = provider, .host = host };
    const request = try fixtures.decoded(arena, try fixtures.requestWith(arena, try arena.print("google/{s}", .{id}), fields));
    const body = google.wireRequest(&call, &model, &request) catch |err| switch (err) {
        error.Failed => return .{ .failure = call.failure.? },
        else => return err,
    };
    var value = try std.json.parseFromSliceLeaky(Value, arena, body, .{});
    _ = value.object.orderedRemove("store");
    _ = value.object.orderedRemove("stream");
    return .{ .body = value };
}

fn bodyOf(arena: Allocator, fields: []const u8) !Value {
    const made = try wired(arena, fields, "gemini-3.8-flash");
    if (made == .failure) {
        std.debug.print("failed: {s}\n", .{made.failure.message});
        return error.TestUnexpectedFailure;
    }
    return made.body;
}

fn refusedWith(arena: Allocator, fields: []const u8, id: []const u8, words: []const u8) !void {
    const made = try wired(arena, fields, id);
    if (made != .failure) {
        std.debug.print("not refused: {s}\n", .{fields});
        return error.TestExpectedFailure;
    }
    try std.testing.expectEqual(FailureKind.invalid_request, made.failure.kind);
    if (std.mem.indexOf(u8, made.failure.message, words) == null) {
        std.debug.print("{s}: {s}\n", .{ words, made.failure.message });
        return error.TestUnexpectedMessage;
    }
}

fn expectMember(arena: Allocator, body: Value, key: []const u8, expected: []const u8) !void {
    const member = body.object.get(key) orelse {
        std.debug.print("no {s} in {s}\n", .{ key, try foundation.json.encode(arena, body) });
        return error.TestExpectedEqual;
    };
    try fixtures.expectJson(arena, expected, try foundation.json.encode(arena, member));
}

/// The server-sent events of an interaction that answers `text` and ends as `status`, with `usage`.
fn answeredWith(arena: Allocator, text: []const u8, status: []const u8, usage: []const u8) ![]const u8 {
    return arena.print(
        \\event: interaction.created
        \\data: {{"event_type":"interaction.created","interaction":{{"id":"v1_test","status":"in_progress"}}}}
        \\
        \\event: step.start
        \\data: {{"event_type":"step.start","index":0,"step":{{"type":"model_output","content":[{{"type":"text","text":"{s}"}}]}}}}
        \\
        \\event: step.stop
        \\data: {{"event_type":"step.stop","index":0}}
        \\
        \\event: interaction.completed
        \\data: {{"event_type":"interaction.completed","interaction":{{"id":"v1_test","status":"{s}","usage":{s}}}}}
        \\
        \\
    , .{ text, status, usage });
}

const small_usage = "{\"total_input_tokens\":4,\"total_output_tokens\":2,\"total_tokens\":6}";

/// What `request` streams through Models when Google answers with `events`.
fn answering(arena: Allocator, request: []const u8, events: []const u8) !fixtures.Answered {
    return fixtures.answered(arena, try fixtures.decoded(arena, request), try arena.dupe([]const u8, &.{events}), options);
}

fn sentBody(arena: Allocator, answered: fixtures.Answered) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, answered.sent[answered.sent.len - 1].body.?, .{});
}

test "every recorded text stream of Google's is sent as recorded, kept nowhere, carrying nothing of ai's" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const names = try fixtures.textNames(arena, "google");
    try std.testing.expectEqual(@as(usize, 19), names.len);
    for (names) |name| {
        errdefer std.debug.print("google/{s}\n", .{name});
        const streamed = try fixtures.streamFixture(arena, name, options);
        const body = try fixtures.sentBody(arena, streamed.replay, 0);
        try std.testing.expectEqual(false, body.object.get("store").?.bool);
        try std.testing.expectEqual(true, body.object.get("stream").?.bool);
        for ([_][]const u8{ "octoii", "provider_metadata", "background", "previous_interaction_id", "contents", "systemInstruction" }) |key| try std.testing.expect(!fixtures.holds(body, key));
        const sent = streamed.replay.sent.items[0];
        try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com/v1beta/interactions", sent.url);
        try std.testing.expectEqualStrings("AIzaSy-test", foundation.http.find(sent.headers, "x-goog-api-key").?);
        try std.testing.expectEqualStrings("text/event-stream", foundation.http.find(sent.headers, "accept").?);
    }
}

test "Google serves its provider at a proxy's address, and fails as auth before anything is sent without a key" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const fixture = try fixtures.load(arena, "google", "text");
    const proxied = try arena.dupe(foundation.replay.Exchange, fixture.exchanges);
    for (proxied) |*exchange| exchange.request.url = "https://proxy.example/v1beta/interactions";
    var proxy = options;
    proxy.settings = .{ .base_url = "https://proxy.example/v1beta" };
    const streamed = try fixtures.stream(arena, fixture.request, proxied, proxy);
    try std.testing.expectEqual(vocabulary.response.ResponseStatus.completed, streamed.response.status);
    var keyless = options;
    keyless.key = null;
    const refused = try fixtures.stream(arena, fixture.request, &.{}, keyless);
    try std.testing.expectEqual(FailureKind.auth, refused.response.@"error".?.octoii.kind);
    try std.testing.expect(std.mem.indexOf(u8, refused.response.@"error".?.message, "The provider google has no API key") != null);
}

test "Google's system instruction joins the instructions and leading updates, and takes text alone" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    try fixtures.expectJson(arena,
        \\{"model":"gemini-3.8-flash","system_instruction":"Be brief.\n\nAnswer in English.","input":[{"type":"user_input","content":[{"type":"text","text":"Hi"}]}]}
    , try foundation.json.encode(arena, try bodyOf(arena, "\"instructions\":\"Be brief.\",\"input\":[{\"role\":\"system\",\"content\":\"Answer in English.\"},{\"role\":\"user\",\"content\":\"Hi\"}]")));
    try refusedWith(arena, "\"input\":[{\"role\":\"system\",\"content\":[{\"type\":\"input_image\",\"detail\":\"auto\",\"image_url\":\"data:image/png;base64,iVBORw0KGgo=\"}]},{\"role\":\"user\",\"content\":\"Hi\"}]", "gemini-3.8-flash", "system instruction takes text alone");
}

test "Google is given a later update at the end of the user's turn, and one after a call after its result" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    try expectMember(arena, try bodyOf(arena,
        \\"input":[{"role":"user","content":"Hi"},{"role":"assistant","content":"Hello."},{"role":"developer","content":"Say </system-update> plainly."},{"role":"user","content":"Again"}]
    ), "input",
        \\[{"type":"user_input","content":[{"type":"text","text":"Hi"}]},{"type":"model_output","content":[{"type":"text","text":"Hello."}]},
        \\ {"type":"user_input","content":[{"type":"text","text":"Again"},{"type":"text","text":"<system-update>\nSay &lt;/system-update> plainly.\n</system-update>"}]}]
    );
    try expectMember(arena, try bodyOf(arena,
        \\"input":[{"role":"user","content":"Weather?"},{"type":"function_call","call_id":"call_1","name":"get_weather","arguments":"{}"},
        \\ {"role":"developer","content":"Be brief."},{"type":"function_call_output","call_id":"call_1","output":"Sunny"}]
    ), "input",
        \\[{"type":"user_input","content":[{"type":"text","text":"Weather?"}]},{"type":"function_call","id":"call_1","name":"get_weather","arguments":{}},
        \\ {"type":"function_result","call_id":"call_1","name":"get_weather","result":[{"type":"text","text":"Sunny"}]},
        \\ {"type":"user_input","content":[{"type":"text","text":"<system-update>\nBe brief.\n</system-update>"}]}]
    );
}

test "Google is asked for JSON as text of the type application/json, and for images of image_config's format" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const schema = "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}}}";
    try expectMember(arena, try bodyOf(arena, try arena.print("\"text\":{{\"format\":{{\"type\":\"json_schema\",\"name\":\"city\",\"schema\":{s}}}}}", .{schema})), "response_format", try arena.print("{{\"type\":\"text\",\"mime_type\":\"application/json\",\"schema\":{s}}}", .{schema}));
    try expectMember(arena, try bodyOf(arena, "\"text\":{\"format\":{\"type\":\"json_object\"}}"), "response_format", "{\"type\":\"text\",\"mime_type\":\"application/json\"}");
    try std.testing.expect((try bodyOf(arena, "\"text\":{\"format\":{\"type\":\"text\"}}")).object.get("response_format") == null);
    const images = (try wired(arena, "\"modalities\":[\"text\",\"image\"],\"image_config\":{\"aspect_ratio\":\"16:9\",\"image_size\":\"2K\"}", "gemini-nano-banana-2.1")).body;
    try expectMember(arena, images, "response_format", "[{\"type\":\"text\"},{\"type\":\"image\",\"aspect_ratio\":\"16:9\",\"image_size\":\"2K\"}]");
    try std.testing.expect(images.object.get("generation_config") == null);
}

test "Google's generation config holds the sampling, the limit, a stop sequence and the thinking level" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    try expectMember(arena, try bodyOf(arena, "\"temperature\":0.4,\"top_p\":0.9,\"stop\":\"END\",\"max_output_tokens\":100"), "generation_config", "{\"temperature\":0.4,\"top_p\":0.9,\"stop_sequences\":[\"END\"],\"max_output_tokens\":100}");
    try expectMember(arena, try bodyOf(arena, "\"reasoning\":{\"effort\":\"medium\",\"summary\":\"detailed\"}"), "generation_config", "{\"thinking_level\":\"medium\",\"thinking_summaries\":\"auto\"}");
    try expectMember(arena, try bodyOf(arena, "\"reasoning\":{\"effort\":\"none\"}"), "generation_config", "{\"thinking_level\":\"minimal\"}");
    try refusedWith(arena, "\"reasoning\":{\"effort\":\"xhigh\"}", "gemini-3.8-flash", "up to high");
    try refusedWith(arena, "\"reasoning\":{\"max_tokens\":1024}", "gemini-3.8-flash", "reasoning.max_tokens");
    const fitted = try answering(arena, "{\"model\":\"google/gemini-3.8-flash\",\"input\":\"Hi\",\"reasoning\":{\"effort\":\"minimal\"}}", try answeredWith(arena, "Hello.", "completed", small_usage));
    try expectMember(arena, (try sentBody(arena, fitted)).object.get("generation_config").?, "thinking_level", "\"low\"");
}

test "Google chooses tools as the tool choice says, validated where a function is strict" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const weather = "{\"type\":\"function\",\"name\":\"get_weather\",\"parameters\":{\"type\":\"object\"}";
    const allowed = "[{\"type\":\"function\",\"name\":\"get_weather\"}]";
    const cases = [_]struct { []const u8, []const u8, ?[]const u8 }{
        .{ "}", "\"auto\"", "\"auto\"" },
        .{ "}", "\"none\"", "\"none\"" },
        .{ "}", "\"required\"", "\"any\"" },
        .{ "}", "{\"type\":\"function\",\"name\":\"get_weather\"}", "{\"allowed_tools\":{\"mode\":\"any\",\"tools\":[\"get_weather\"]}}" },
        .{ "}", "{\"type\":\"allowed_tools\",\"mode\":\"auto\",\"tools\":" ++ allowed ++ "}", "{\"allowed_tools\":{\"mode\":\"auto\",\"tools\":[\"get_weather\"]}}" },
        .{ "}", "{\"type\":\"allowed_tools\",\"mode\":\"required\",\"tools\":" ++ allowed ++ "}", "{\"allowed_tools\":{\"mode\":\"any\",\"tools\":[\"get_weather\"]}}" },
        .{ ",\"strict\":true}", "", "\"validated\"" },
        .{ ",\"strict\":true}", "\"auto\"", "\"validated\"" },
        .{ ",\"strict\":true}", "{\"type\":\"allowed_tools\",\"mode\":\"auto\",\"tools\":" ++ allowed ++ "}", "{\"allowed_tools\":{\"mode\":\"validated\",\"tools\":[\"get_weather\"]}}" },
        .{ "}", "", null },
    };
    for (cases) |case| {
        const choice = if (case[1].len == 0) "" else try arena.print(",\"tool_choice\":{s}", .{case[1]});
        const body = try bodyOf(arena, try arena.print("\"tools\":[{s}{s}]{s}", .{ weather, case[0], choice }));
        const config = body.object.get("generation_config");
        if (case[2]) |expected| try expectMember(arena, config.?, "tool_choice", expected) else try std.testing.expect(config == null);
    }
}

test "Google declares functions and web search as Google Search, and refuses what it does not offer" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    try expectMember(arena, try bodyOf(arena, "\"tools\":[{\"type\":\"function\",\"name\":\"get_weather\",\"description\":\"The weather\",\"parameters\":{\"type\":\"object\"}},{\"type\":\"web_search\"}]"), "tools",
        \\[{"type":"function","name":"get_weather","description":"The weather","parameters":{"type":"object"}},{"type":"google_search"}]
    );
    const refused = [_]struct { []const u8, []const u8 }{
        .{ "\"tools\":[{\"type\":\"function\",\"name\":\"now\",\"parameters\":null,\"output_schema\":{\"type\":\"string\"}}]", "an output_schema of now" },
        .{ "\"tools\":[{\"type\":\"web_search\",\"search_context_size\":\"high\"}]", "Google's web search takes no settings" },
        .{ "\"top_k\":20", "top_k" },
        .{ "\"frequency_penalty\":0.5", "frequency_penalty" },
        .{ "\"presence_penalty\":0.5", "presence_penalty" },
        .{ "\"parallel_tool_calls\":false", "parallel_tool_calls" },
        .{ "\"max_tool_calls\":3", "max_tool_calls" },
        .{ "\"stop_server_tools_when\":[{\"type\":\"step_count_is\",\"step_count\":2}]", "stop_server_tools_when" },
        .{ "\"service_tier\":\"flex\"", "service_tier flex" },
        .{ "\"reasoning\":{\"mode\":\"pro\"}", "reasoning.mode pro" },
        .{ "\"reasoning\":{\"context\":\"all_turns\"}", "reasoning.context all_turns" },
        .{ "\"tools\":[{\"type\":\"function\",\"name\":\"run\",\"parameters\":null,\"allowed_callers\":[\"programmatic\"]}]", "programmatic callers of run" },
        .{ "\"modalities\":[\"text\",\"image\"]", "images in its output" },
        .{ "\"input\":[{\"type\":\"custom_tool_call\",\"call_id\":\"c\",\"name\":\"patch\",\"input\":\"x\"},{\"type\":\"custom_tool_call_output\",\"call_id\":\"c\",\"output\":\"ok\"}]", "no custom tools" },
        .{ "\"input\":[{\"type\":\"function_call_output\",\"call_id\":\"call_x\",\"output\":\"ok\"}]", "answers no function call" },
    };
    for (refused) |case| try refusedWith(arena, case[0], "gemini-3.8-flash", case[1]);
    try refusedWith(arena, "\"modalities\":[\"text\",\"image\"],\"image_config\":{\"quality\":\"high\"}", "gemini-nano-banana-2.1", "image_config.quality");
    try std.testing.expectEqual(FailureKind.invalid_request, (try fixtures.refusal(arena, "{\"model\":\"google/gemini-3.8-flash\",\"input\":\"Hi\",\"service_tier\":\"priority\"}", options)).octoii.kind);
}

test "Google is sent no caching fields nor identifiers, and its own options member by member, stored nowhere" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    try fixtures.expectJson(arena,
        \\{"model":"gemini-3.8-flash","input":[{"type":"user_input","content":[{"type":"text","text":"Hi"}]}]}
    , try foundation.json.encode(arena, try bodyOf(arena,
        \\"prompt_cache_key":"conversation-1","cache_control":{"type":"ephemeral","ttl":"1h"},"session_id":"s-1","metadata":{"team":"a"},
        \\"safety_identifier":"person-1","user":"person-1","include":["reasoning.encrypted_content"],"service_tier":"default"
    )));
    const answered = try answering(arena,
        \\{"model":"google/gemini-3.8-flash","input":"Hi","max_output_tokens":200,
        \\ "provider":{"options":{"google":{"safety_settings":[{"type":"harassment","threshold":"block_only_high"}],"generation_config":{"seed":7},"store":true}}}}
    , try answeredWith(arena, "Hello.", "completed", small_usage));
    const body = try sentBody(arena, answered);
    try expectMember(arena, body, "safety_settings", "[{\"type\":\"harassment\",\"threshold\":\"block_only_high\"}]");
    try expectMember(arena, body, "generation_config", "{\"max_output_tokens\":200,\"seed\":7}");
    try expectMember(arena, body, "store", "false");
    try expectMember(arena, body, "stream", "true");
}

test "Google is given a function's text and images as its result, and is refused a PDF, audio or video there" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const call = "{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"screenshot\",\"arguments\":\"{}\"}";
    try expectMember(arena, try bodyOf(arena, try arena.print(
        \\"input":[{{"role":"user","content":"Look"}},{s},{{"type":"function_call_output","call_id":"call_1","output":[{{"type":"input_text","text":"Taken"}},
        \\ {{"type":"input_image","detail":"auto","image_url":"data:image/png;base64,iVBORw0KGgo="}}]}}]
    , .{call})), "input",
        \\[{"type":"user_input","content":[{"type":"text","text":"Look"}]},{"type":"function_call","id":"call_1","name":"screenshot","arguments":{}},
        \\ {"type":"function_result","call_id":"call_1","name":"screenshot","result":[{"type":"text","text":"Taken"},{"type":"image","data":"iVBORw0KGgo=","mime_type":"image/png"}]}]
    );
    const refused = [_][]const u8{
        "{\"type\":\"input_audio\",\"input_audio\":{\"data\":\"UklGRg==\",\"format\":\"wav\"}}",
        "{\"type\":\"input_file\",\"file_data\":\"data:application/pdf;base64,JVBERi0=\"}",
        "{\"type\":\"input_video\",\"video_url\":\"https://www.youtube.com/watch?v=9hE5-98ZeCg\"}",
    };
    for (refused) |part| try refusedWith(arena, try arena.print("\"input\":[{{\"role\":\"user\",\"content\":\"Look\"}},{s},{{\"type\":\"function_call_output\",\"call_id\":\"call_1\",\"output\":[{s}]}}]", .{ call, part }), "gemini-3.8-flash", "function's result");
}

test "Google fetches a PDF and a video itself, ai a text file, and reads audio inline and an original image at ultra high" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    try expectMember(arena, try bodyOf(arena,
        \\"input":[{"role":"user","content":[{"type":"input_file","file_url":"https://example.com/brief.pdf"},
        \\ {"type":"input_video","video_url":"https://www.youtube.com/watch?v=9hE5-98ZeCg"},{"type":"input_file","file_url":"https://files.example.com/table"}]}]
    ), "input",
        \\[{"type":"user_input","content":[{"type":"document","uri":"https://example.com/brief.pdf","mime_type":"application/pdf"},
        \\ {"type":"video","uri":"https://www.youtube.com/watch?v=9hE5-98ZeCg"},{"type":"text","text":"<file name=\"table\">\nParis: 18 \u00b0C\n</file>"}]}]
    );
    try expectMember(arena, try bodyOf(arena,
        \\"input":[{"role":"user","content":[{"type":"input_audio","input_audio":{"data":"SUQz","format":"mp3"}},
        \\ {"type":"input_image","detail":"original","image_url":"https://example.com/plan.png"}]}]
    ), "input",
        \\[{"type":"user_input","content":[{"type":"audio","data":"SUQz","mime_type":"audio/mp3"},
        \\ {"type":"image","uri":"https://example.com/plan.png","mime_type":"image/png","resolution":"ultra_high"}]}]
    );
}

test "Google's responses: a thought as reasoning, the output as a message, thoughts counted as output and priced" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const text = try fixtures.streamFixture(arena, "text", options);
    const response = text.response;
    try std.testing.expectEqualStrings("v1_ChdpbnRlcmFjdGlvbi10ZXN0LTEyMzQ", response.id);
    try std.testing.expectEqualStrings(flash, response.octoii.?.model.?);
    try std.testing.expectEqual(@as(?u64, 14), response.octoii.?.context_tokens);
    const reasoning = response.output[0].reasoning;
    try std.testing.expectEqualStrings("The user asks for the capital of France, which is Paris.", reasoning.summary.?[0].text);
    try std.testing.expectEqualStrings("EpoGCpcGAXLI2nxThoughtSignatureParis", reasoning.signature.?);
    try std.testing.expectEqual(vocabulary.items.ReasoningFormat.@"google-gemini-v1", reasoning.format.?);
    try std.testing.expectEqual(null, response.output[1].output_message.octoii.?.provider_metadata);
    try std.testing.expectEqualStrings("The capital of France is Paris.", (try fixtures.messageText(arena, response.output)).?);
    var deltas: std.ArrayList([]const u8) = .empty;
    for (text.events) |event| if (event == .output_text_delta) try deltas.append(arena, event.output_text_delta.delta);
    try fixtures.expectJson(arena, "[\"The capital of France\",\" is Paris.\"]", try foundation.json.encode(arena, deltas.items));
    try std.testing.expectEqual(@as(u64, 33), response.usage.?.output_tokens);
    try std.testing.expectEqual(@as(u64, 47), response.usage.?.total_tokens);
    // Gemini 3.8 Flash: $0.75 a million tokens read, $3.75 a million written.
    try fixtures.expectUsage(.{ .input = 14, .output = 33, .reasoning = 26, .cost = 14 * 0.00000075 + 33 * 0.00000375 }, Usage.ofResponse(response));
}

test "Google's function calls have call_ids of their own, Gemini's ids kept, and go back by them" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const called = try fixtures.streamFixture(arena, "function-call", options);
    const output = called.response.output;
    try std.testing.expectEqualStrings("EpYDCpMDAXLI2nyParallelCallSignature", output[0].reasoning.signature.?);
    try std.testing.expectEqualStrings("{\"city\":\"Paris\"}", output[1].function_call.arguments);
    try std.testing.expectEqualStrings("{\"google\":{\"id\":\"8f2kq1zd\"}}", output[1].function_call.octoii.?.provider_metadata.?.text);
    try std.testing.expectEqualStrings("{\"city\":\"London\"}", output[2].function_call.arguments);
    try std.testing.expect(!std.mem.eql(u8, output[1].function_call.call_id, output[2].function_call.call_id));
    try fixtures.expectMinted(output[1].function_call.call_id);
    var deltas: std.ArrayList([]const u8) = .empty;
    for (called.events) |event| if (event == .function_call_arguments_delta) try deltas.append(arena, event.function_call_arguments_delta.delta);
    try fixtures.expectJson(arena, "[\"{\\\"city\\\":\",\"\\\"Paris\\\"}\",\"{\\\"city\\\":\\\"London\\\"}\"]", try foundation.json.encode(arena, deltas.items));
    const answered = (try fixtures.streamFixture(arena, "function-call-output", options)).response;
    try std.testing.expectEqualStrings("It is 18 \u{b0}C and sunny in Paris. London's weather could not be fetched.", (try fixtures.messageText(arena, answered.output)).?);
    // Another Gemini model is given the calls by their own ids, without the first one's ids and thoughts.
    const fixture = try fixtures.load(arena, "google", "function-call-output");
    var other = fixture.request;
    other.model = "google/gemini-3.6-flash";
    const crossed = try fixtures.answered(arena, other, try arena.dupe([]const u8, &.{try answeredWith(arena, "Done.", "completed", small_usage)}), options);
    const sent = crossed.sent[0].body.?;
    try std.testing.expect(std.mem.indexOf(u8, sent, "8f2kq1zd") == null and std.mem.indexOf(u8, sent, "EpYDCpMDAXLI2nyParallelCallSignature") == null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"id\":\"call_paris\"") != null and std.mem.indexOf(u8, sent, "\"call_id\":\"call_london\"") != null);
}

test "Google's thought goes back with its summary and signature to the model that wrote it" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const response = (try fixtures.streamFixture(arena, "text", options)).response;
    var items: std.ArrayList(vocabulary.Item) = .empty;
    try items.append(arena, .{ .input_message = .{ .role = .user, .content = .{ .text = "What is the capital of France?" } } });
    for (response.output) |item| try items.append(arena, .ofOutput(item));
    try items.append(arena, .{ .input_message = .{ .role = .user, .content = .{ .text = "And Spain?" } } });
    const fixture = try fixtures.load(arena, "google", "text");
    var request = fixture.request;
    request.input = .{ .parts = items.items };
    const answered = try fixtures.answered(arena, request, try arena.dupe([]const u8, &.{try answeredWith(arena, "Madrid.", "completed", small_usage)}), options);
    try expectMember(arena, try sentBody(arena, answered), "input",
        \\[{"type":"user_input","content":[{"type":"text","text":"What is the capital of France?"}]},
        \\ {"type":"thought","signature":"EpoGCpcGAXLI2nxThoughtSignatureParis","summary":[{"type":"text","text":"The user asks for the capital of France, which is Paris."}]},
        \\ {"type":"model_output","content":[{"type":"text","text":"The capital of France is Paris."}]},
        \\ {"type":"user_input","content":[{"type":"text","text":"And Spain?"}]}]
    );
}

test "Google's search is one web search call with its signatures, cited in characters, and goes back only to its model" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const response = (try fixtures.streamFixture(arena, "web-search", options)).response;
    const search = response.output[0].web_search_call;
    try std.testing.expectEqual(.completed, search.status);
    try fixtures.expectJson(arena, "{\"type\":\"search\",\"query\":\"UEFA Euro 2024 winner\",\"queries\":[\"UEFA Euro 2024 winner\",\"who won euro 2024\"]}", try foundation.json.encode(arena, search.action.?));
    try fixtures.expectJson(arena,
        \\{"google":{"id":"mkutnkgn","signature":"EtoBCtUBSearchCallSignature","result_signature":"EtoBCtUBSearchResultSignature","search_suggestions":"<!-- HTML and CSS for the search widget: who won euro 2024 -->"}}
    , search.octoii.?.provider_metadata.?.text);
    try std.testing.expectEqualStrings("CoMDAXLI2nynSearchThoughtSignature", response.output[1].reasoning.signature.?);
    const text = response.output[2].output_message.content.parts[0].output_text;
    try std.testing.expectEqualStrings("Spain won Euro 2024, defeating England 2\u{2013}1 in the final.", text.text);
    const annotations = text.annotations.?;
    try std.testing.expectEqual(@as(usize, 3), annotations.len);
    try std.testing.expectEqual(@as(u32, 20), annotations[0].url_citation.end_index);
    try std.testing.expectEqual(@as(u32, 21), annotations[1].url_citation.start_index);
    try std.testing.expectEqual(@as(u32, 56), annotations[2].url_citation.end_index);
    try std.testing.expectEqualStrings("uefa.com", annotations[2].url_citation.title);
    // Two searches at $14 a thousand, and the tools' tokens read as input.
    try fixtures.expectUsage(.{ .input = 421, .output = 55, .reasoning = 40, .web_searches = 2, .cost = 421 * 0.00000075 + 55 * 0.00000375 + 2 * 0.014 }, Usage.ofResponse(response));
    var items: std.ArrayList(vocabulary.Item) = .empty;
    try items.append(arena, .{ .input_message = .{ .role = .user, .content = .{ .text = "Who won Euro 2024?" } } });
    for (response.output) |item| try items.append(arena, .ofOutput(item));
    try items.append(arena, .{ .input_message = .{ .role = .user, .content = .{ .text = "And in 2020?" } } });
    const tools = try arena.dupe(vocabulary.Tool, &.{.{ .web_search = .{} }});
    const own = try fixtures.answered(arena, .{ .model = flash, .input = .{ .parts = items.items }, .tools = tools }, try arena.dupe([]const u8, &.{try answeredWith(arena, "Italy.", "completed", small_usage)}), options);
    const steps = (try sentBody(arena, own)).object.get("input").?.array.items;
    try fixtures.expectJson(arena, "{\"type\":\"google_search_call\",\"id\":\"mkutnkgn\",\"arguments\":{\"queries\":[\"UEFA Euro 2024 winner\",\"who won euro 2024\"]},\"signature\":\"EtoBCtUBSearchCallSignature\"}", try foundation.json.encode(arena, steps[1]));
    try fixtures.expectJson(arena, "{\"type\":\"google_search_result\",\"call_id\":\"mkutnkgn\",\"result\":[{\"search_suggestions\":\"<!-- HTML and CSS for the search widget: who won euro 2024 -->\"}],\"signature\":\"EtoBCtUBSearchResultSignature\"}", try foundation.json.encode(arena, steps[2]));
    try std.testing.expectEqualStrings("thought", steps[3].object.get("type").?.string);
    const other = try fixtures.answered(arena, .{ .model = "google/gemini-3.6-flash", .input = .{ .parts = items.items }, .tools = tools }, try arena.dupe([]const u8, &.{try answeredWith(arena, "Italy.", "completed", small_usage)}), options);
    for ([_][]const u8{ "google_search_call", "google_search_result", "Signature", "thought" }) |kept| try std.testing.expect(std.mem.indexOf(u8, other.sent[0].body.?, kept) == null);
}

test "Google's responses end as the interaction did: cut off, waiting, with images made, priced by modality" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const crossed = (try fixtures.streamFixture(arena, "crossing-models", options));
    try std.testing.expectEqual(vocabulary.response.ResponseStatus.completed, crossed.response.status);
    const crossed_body = crossed.replay.sent.items[0].body.?;
    for ([_][]const u8{ "anthropic", "ClaudeSignature", "I should call the weather tool." }) |kept| try std.testing.expect(std.mem.indexOf(u8, crossed_body, kept) == null);
    const structured = (try fixtures.streamFixture(arena, "structured-output", options)).response;
    try fixtures.expectJson(arena, "{\"city\":\"Paris\"}", (try fixtures.messageText(arena, structured.output)).?);
    const cut = (try fixtures.streamFixture(arena, "max-tokens", options)).response;
    try std.testing.expectEqual(.max_output_tokens, cut.incomplete_details.?.reason.?);
    try std.testing.expectEqual(vocabulary.items.ItemStatus.completed, cut.output[0].reasoning.status.?);
    try std.testing.expectEqual(vocabulary.items.ItemStatus.incomplete, cut.output[1].output_message.status.?);
    try std.testing.expectEqualStrings("1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13,", (try fixtures.messageText(arena, cut.output)).?);
    const drawn = (try fixtures.streamFixture(arena, "image-output", options)).response;
    const parts = drawn.output[1].output_message.content.parts;
    try std.testing.expectEqualStrings("Here is a cat on a windowsill.", parts[0].output_text.text);
    try std.testing.expect(std.mem.startsWith(u8, parts[1].output_image.image_url, "data:image/png;base64,"));
    // Nano Banana 2.1: $1.50 a million tokens read, $7.50 a million written, $30 a million image tokens made.
    try fixtures.expectUsage(.{ .input = 8, .output = 128, .output_image = 1290, .reasoning = 120, .cost = 8 * 0.0000015 + 128 * 0.0000075 + 1290 * 0.00003 }, Usage.ofResponse(drawn));
    const argon = try answering(arena, "{\"model\":\"google/gemini-4-argon\",\"input\":\"Hi\"}", try answeredWith(arena, "Hello.", "completed", "{\"total_input_tokens\":250000,\"total_output_tokens\":100,\"total_tokens\":250100}"));
    try std.testing.expectApproxEqAbs(250_000 * 0.000002 + 100 * 0.00001, argon.response.usage.?.cost.?, 1e-9);
    const audio = try answering(arena, "{\"model\":\"google/gemini-3.6-flash\",\"input\":\"Hi\"}", try answeredWith(arena, "Hello.", "completed", "{\"total_input_tokens\":1000,\"input_tokens_by_modality\":[{\"modality\":\"text\",\"tokens\":200},{\"modality\":\"audio\",\"tokens\":800}]," ++
        "\"total_cached_tokens\":400,\"cached_tokens_by_modality\":[{\"modality\":\"audio\",\"tokens\":400}],\"total_output_tokens\":10,\"total_tokens\":1010}"));
    const used = Usage.ofResponse(audio.response);
    try std.testing.expectEqual(@as(?u64, 200), used.input);
    try std.testing.expectEqual(@as(?u64, 400), used.input_audio);
    try std.testing.expectEqual(@as(?u64, 400), used.cache_read);
    try std.testing.expectEqual(@as(?u64, 10), used.output);
    try std.testing.expectEqual(vocabulary.response.ResponseStatus.completed, (try answering(arena, "{\"model\":\"google/gemini-3.8-flash\",\"input\":\"Hi\"}", try answeredWith(arena, "Calling.", "requires_action", small_usage))).response.status);
}

test "Google's stream ends at the interaction's completion, done or not, and skips what ai does not read" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const done = try arena.print("{s}event: done\ndata: [DONE]\n\n", .{try answeredWith(arena, "Hello.", "completed", small_usage)});
    try std.testing.expectEqual(vocabulary.response.ResponseStatus.completed, (try answering(arena, "{\"model\":\"google/gemini-3.8-flash\",\"input\":\"Hi\"}", done)).response.status);
    const skipped = try arena.print(
        \\event: interaction.status_update
        \\data: {{"event_type":"interaction.status_update","interaction_id":"v1_test","status":"in_progress"}}
        \\
        \\event: step.start
        \\data: {{"event_type":"step.start","index":0,"step":{{"type":"code_execution_call","id":"c1","arguments":{{"code":"print(1)"}}}}}}
        \\
        \\event: step.delta
        \\data: {{"event_type":"step.delta","index":0,"delta":{{"type":"code_execution_call","arguments":{{"code":"print(1)"}}}}}}
        \\
        \\event: step.stop
        \\data: {{"event_type":"step.stop","index":0}}
        \\
        \\{s}
    , .{try answeredWith(arena, "Hello.", "completed", small_usage)});
    const answered = try answering(arena, "{\"model\":\"google/gemini-3.8-flash\",\"input\":\"Hi\"}", skipped);
    try std.testing.expectEqual(@as(usize, 1), answered.response.output.len);
}

test "Google's failures are classified by its codes, before the stream and within it" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const cases = [_]struct { []const u8, FailureKind, ?u16, []const u8 }{
        .{ "unauthorized", .auth, 401, "authentication" },
        .{ "forbidden", .forbidden, 403, "permission_denied" },
        .{ "rate-limited", .rate_limit, 429, "rate_limit_exceeded" },
        .{ "quota", .quota, 402, "payment_required" },
        .{ "context-overflow", .context_overflow, 400, "invalid_request" },
        .{ "unavailable", .server, 503, "service_unavailable" },
        .{ "prompt-blocked", .content_filter, 400, "safety" },
        .{ "mid-stream-error", .server, null, "api_error" },
        .{ "malformed-function-call", .invalid_response, null, "malformed_function_call" },
    };
    for (cases) |case| {
        errdefer std.debug.print("google/{s}\n", .{case[0]});
        const failure = try fixtures.failureOf(arena, case[0], options);
        try std.testing.expectEqual(case[1], failure.octoii.kind);
        try std.testing.expectEqual(case[2], failure.octoii.status);
        try std.testing.expectEqualStrings(case[3], failure.code);
    }
    try std.testing.expect(std.mem.indexOf(u8, (try fixtures.failureOf(arena, "malformed-function-call", options)).message, "get_weather(city=Paris") != null);
    for ([_]struct { []const u8, []const u8, []const u8 }{ .{ "safety", "prohibited_content", "The scene shows" }, .{ "mid-stream-error", "api_error", "Hello! How" } }) |case| {
        const streamed = try fixtures.streamFixture(arena, case[0], options);
        try std.testing.expectEqualStrings(case[1], streamed.events[streamed.events.len - 2].@"error".code);
        try std.testing.expectEqual(vocabulary.items.ItemStatus.incomplete, streamed.response.output[0].output_message.status.?);
        try std.testing.expectEqualStrings(case[2], (try fixtures.messageText(arena, streamed.response.output)).?);
    }
    for ([_]struct { []const u8, FailureKind }{ .{ "failed", .server }, .{ "cancelled", .server }, .{ "requires_continuation", .invalid_response } }) |case| {
        const ended = try arena.print("event: interaction.completed\ndata: {{\"event_type\":\"interaction.completed\",\"interaction\":{{\"id\":\"v1_test\",\"status\":\"{s}\"}}}}\n\n", .{case[0]});
        const answered = try answering(arena, "{\"model\":\"google/gemini-3.8-flash\",\"input\":\"Hi\"}", ended);
        try std.testing.expectEqual(vocabulary.response.ResponseStatus.failed, answered.response.status);
        try std.testing.expectEqual(case[1], answered.response.@"error".?.octoii.kind);
    }
}
