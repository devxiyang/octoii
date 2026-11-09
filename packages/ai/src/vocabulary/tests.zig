//! The vocabulary as a whole: requests, responses and events decoded with checks and encoded canonically.
const std = @import("std");
const foundation = @import("foundation");
const json = foundation.json;
const vocabulary = @import("root.zig");

test "a request decodes typed, passing over what it does not know, and encodes one way" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const given =
        \\{"model":"anthropic/claude-opus-5-5","stream":true,"instructions":"Be brief.","input":[
        \\ {"role":"user","content":"hi"},
        \\ {"type":"message","role":"assistant","content":[{"type":"output_text","text":"hello"}],
        \\  "octoii":{"model":"anthropic/claude-opus-5-5","provider_metadata":{"anthropic": {"signature":"s"}}}},
        \\ {"type":"function_call","call_id":"c1","name":"read","arguments":"{\"path\":\"a\"}"},
        \\ {"type":"function_call_output","call_id":"c1","output":[{"type":"input_text","text":"done"},
        \\  {"type":"input_file","octoii":{"ref":"f1","media_type":"application/pdf"}}]},
        \\ {"type":"reasoning","id":"r1","summary":[{"type":"summary_text","text":"thinking"}],"encrypted_content":"e"},
        \\ {"type":"octoii:tool_removal","names":["read"]}],
        \\ "tools":[{"type":"function","name":"read","strict":null,
        \\  "parameters":{"type":"object","properties":{"path":{"type":"string"}}}}],
        \\ "tool_choice":"auto","reasoning":{"effort":"high"},"temperature":1,"stop":["END"],
        \\ "provider":{"sort":{"by":"price"},"preferred_max_latency":2},"plugins":[{"id":"web","max_results":3}]}
    ;
    const request = try json.decode(vocabulary.ResponsesRequest, arena, given);
    const input = request.input.?.parts;
    try std.testing.expectEqualStrings("hi", input[0].input_message.content.text);
    try std.testing.expectEqualStrings("anthropic/claude-opus-5-5", input[1].output_message.octoii.?.model.?);
    try std.testing.expectEqualStrings("f1", input[3].function_call_output.output.parts[1].input_file.octoii.?.ref.?);
    try std.testing.expectEqual(.auto, request.tool_choice.?.mode);
    try std.testing.expectEqual(@as(f64, 2), request.provider.?.preferred_max_latency.?.median);
    try std.testing.expectEqual(.price, request.provider.?.sort.?.partitioned.by.?);
    try std.testing.expectEqual(@as(u32, 3), request.plugins.?[0].web.max_results.?);

    const canonical =
        \\{"model":"anthropic/claude-opus-5-5","instructions":"Be brief.","input":[
        \\{"role":"user","content":"hi"},
        \\{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hello"}],
        \\"octoii":{"model":"anthropic/claude-opus-5-5","provider_metadata":{"anthropic":{"signature":"s"}}}},
        \\{"type":"function_call","call_id":"c1","name":"read","arguments":"{\"path\":\"a\"}"},
        \\{"type":"function_call_output","call_id":"c1","output":[{"type":"input_text","text":"done"},
        \\{"type":"input_file","octoii":{"ref":"f1","media_type":"application/pdf"}}]},
        \\{"type":"reasoning","id":"r1","summary":[{"type":"summary_text","text":"thinking"}],"encrypted_content":"e"},
        \\{"type":"octoii:tool_removal","names":["read"]}],
        \\"tools":[{"type":"function","name":"read",
        \\"parameters":{"type":"object","properties":{"path":{"type":"string"}}}}],
        \\"tool_choice":"auto","reasoning":{"effort":"high"},"temperature":1,"stop":["END"],
        \\"provider":{"preferred_max_latency":2,"sort":{"by":"price"}},"plugins":[{"id":"web","max_results":3}]}
    ;
    const once = try json.encode(arena, request);
    try std.testing.expectEqualStrings(try std.mem.replaceOwned(u8, arena, canonical, "\n", ""), once);
    try std.testing.expectEqualStrings(once, try json.encode(arena, try json.decode(vocabulary.ResponsesRequest, arena, once)));
}

/// Expects `bytes` to be refused as a `T`.
fn expectRefused(comptime T: type, bytes: []const u8) !void {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    if (json.decode(T, arena_allocator.allocator(), bytes)) |_| return error.TestExpectedRefusal else |_| {}
}

test "an item refuses a type it does not know, content its role does not take, and a file without a source" {
    try expectRefused(vocabulary.Item, "{\"type\":\"image_generation_call\",\"id\":\"x\"}");
    try expectRefused(vocabulary.Item, "{\"role\":\"user\",\"content\":[{\"type\":\"input_hologram\"}]}");
    try expectRefused(vocabulary.Item, "{\"role\":\"user\",\"content\":[{\"type\":\"input_file\",\"filename\":\"a.pdf\"}]}");
    try expectRefused(vocabulary.Item, "{\"role\":\"assistant\",\"content\":[{\"type\":\"input_text\",\"text\":\"x\"}]}");
    try expectRefused(vocabulary.Item, "{\"type\":\"function_call\",\"name\":\"read\",\"arguments\":\"{}\"}");
    try expectRefused(vocabulary.Item, "{\"role\":\"user\",\"content\":[{\"type\":\"input_image\",\"detail\":\"auto\",\"octoii\":{}}]}");
}

test "a stream's events decode, its last carrying the whole response, and its output goes on as items" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const stream =
        \\[{"type":"response.output_text.delta","item_id":"m1","output_index":0,"content_index":0,"delta":"he","logprobs":[],"sequence_number":3},
        \\{"type":"error","code":"overloaded_error","message":"busy","param":null,"sequence_number":4,
        \\ "octoii":{"kind":"server","retryable":true,"retry_after_ms":2000,"status":529}},
        \\{"type":"response.completed","sequence_number":5,"response":{"id":"r","status":"completed","incomplete_details":null,
        \\ "error":null,"output":[{"type":"message","id":"m1","role":"assistant","status":"completed",
        \\ "content":[{"type":"output_text","text":"hello","annotations":[]}]},
        \\ {"type":"function_call","id":"f1","call_id":"c1","name":"read","arguments":"{}","status":"completed"}],
        \\ "usage":{"input_tokens":10,"input_tokens_details":{"cached_tokens":4},"output_tokens":3,
        \\ "output_tokens_details":{"reasoning_tokens":0},"total_tokens":13},"octoii":{"model":"openai/gpt-5","context_tokens":10}}}]
    ;
    const events = try json.decode([]const vocabulary.ResponseStreamEvent, arena, stream);
    try std.testing.expectEqualStrings("he", events[0].output_text_delta.delta);
    try std.testing.expectEqual(.server, events[1].@"error".octoii.kind);
    try std.testing.expectEqual(@as(?u64, 2000), events[1].@"error".octoii.retry_after_ms);
    const response = events[2].completed.response;
    try std.testing.expectEqual(@as(?u64, 6), vocabulary.Usage.ofResponse(response).input);
    const next = vocabulary.Item.ofOutput(response.output[1]);
    try std.testing.expectEqualStrings("c1", next.function_call.call_id);
    const once = try json.encode(arena, events);
    try std.testing.expectEqualStrings(once, try json.encode(arena, try json.decode([]const vocabulary.ResponseStreamEvent, arena, once)));
}

test "a response and a stream's event decode whole or are refused, whatever bytes they are given" {
    try std.testing.fuzz({}, fuzzDecode, .{ .corpus = &.{
        "{\"id\":\"r1\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hi\"}]}]}",
        "{\"type\":\"response.output_text.delta\",\"item_id\":\"m1\",\"output_index\":0,\"content_index\":0,\"delta\":\"Hi\",\"logprobs\":[],\"sequence_number\":2}",
    } });
}

/// Decodes whatever bytes the fuzzer gives as a response and as a stream's event, as a provider's bytes are read: each
/// whole, or refused.
fn fuzzDecode(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [4096]u8 = undefined;
    const bytes = buffer[0..smith.slice(&buffer)];
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    _ = json.decode(vocabulary.Response, arena_allocator.allocator(), bytes) catch {};
    _ = json.decode(vocabulary.ResponseStreamEvent, arena_allocator.allocator(), bytes) catch {};
}
