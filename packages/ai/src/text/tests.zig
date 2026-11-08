//! The text path end to end, over a fake provider: a request found, checked and prepared, its stream made whole.
const std = @import("std");
const vocabulary = @import("vocabulary");
const Event = vocabulary.ResponseStreamEvent;
const Models = @import("../Models.zig");
const driver = @import("../driver.zig");
const testing_host = @import("../testing/host.zig");
const Fake = @import("../testing/fake.zig").Fake;
const Answer = @import("../testing/fake.zig").Answer;
const contract = @import("../testing/contract.zig");
const Model = @import("../catalogue/model.zig").Model;

/// A reasoning text model of the fake provider's, which reads text, images and files.
const model: Model = .{
    .id = "m",
    .name = "M",
    .architecture = .{ .input_modalities = &.{ .text, .image, .file }, .output_modalities = &.{.text} },
    .reasoning = .{ .supported_efforts = &.{ .high, .low }, .mandatory = false },
    .octoii = .{ .provider = "fake", .kinds = &.{.text} },
};

/// A run of the fake provider: its answers given, a request streamed to its end.
const Run = struct {
    events: []const Event,
    response: vocabulary.Response,
    requests: []const vocabulary.ResponsesRequest,
};

fn run(arena: std.mem.Allocator, answers: []const Answer, request: vocabulary.ResponsesRequest) !Run {
    var fake: Fake = .init(arena, answers);
    var test_host: testing_host.Host = .{ .stored = &.{.{ .ref = "doc", .bytes = "%PDF-1.7 hello" }} };
    const providers = [_]driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{@import("../catalogue/facts.zig").asFacts(model)} }};
    const models = try Models.init(arena, .{ .providers = &providers, .host = test_host.host(undefined) });
    defer models.deinit();
    var stream = models.text(arena, request);
    defer stream.close();
    var events: std.ArrayList(Event) = .empty;
    while (try stream.next()) |event| try events.append(arena, event);
    try std.testing.expectEqual(@as(usize, 0), (try contract.problems(arena, events.items)).len);
    return .{ .events = events.items, .response = stream.response().?, .requests = fake.requests.items };
}

const hello: vocabulary.ResponsesRequest = .{ .model = "fake/m", .input = .{ .text = "hello" } };

fn response(status: vocabulary.response.ResponseStatus) vocabulary.Response {
    return .{ .id = "r", .status = status, .output = &.{} };
}

test "a whole stream comes numbered from 0, its items stamped and its calls' ids made unique" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const first: vocabulary.OutputItem = .{ .function_call = .{ .id = "f1", .call_id = "", .name = "read", .arguments = "{}" } };
    const second: vocabulary.OutputItem = .{ .function_call = .{ .id = "f2", .call_id = "c", .name = "read", .arguments = "{}" } };
    const third: vocabulary.OutputItem = .{ .function_call = .{ .id = "f3", .call_id = "c", .name = "read", .arguments = "{}" } };
    const answers = [_]Answer{.{ .events = &.{
        .{ .created = .{ .response = response(.in_progress), .sequence_number = 7 } },
        .{ .output_item_added = .{ .item = first, .output_index = 0, .sequence_number = 9 } },
        .{ .output_item_done = .{ .item = first, .output_index = 0, .sequence_number = 9 } },
        .{ .output_item_added = .{ .item = second, .output_index = 1, .sequence_number = 9 } },
        .{ .output_item_done = .{ .item = second, .output_index = 1, .sequence_number = 9 } },
        .{ .output_item_added = .{ .item = third, .output_index = 2, .sequence_number = 9 } },
        .{ .output_item_done = .{ .item = third, .output_index = 2, .sequence_number = 9 } },
        .{ .completed = .{ .response = .{ .id = "r", .status = .completed, .output = &.{ first, second, third } }, .sequence_number = 9 } },
    } }};
    const done = try run(a, &answers, hello);
    try std.testing.expectEqual(@as(usize, 8), done.events.len);
    const output = done.response.output;
    try @import("../testing/fixtures.zig").expectMinted(output[0].function_call.call_id);
    try std.testing.expectEqualStrings("c", output[1].function_call.call_id);
    try std.testing.expect(!std.mem.eql(u8, output[2].function_call.call_id, "c"));
    try std.testing.expectEqualStrings(output[2].function_call.call_id, done.events[6].output_item_done.item.function_call.call_id);
    try std.testing.expectEqualStrings("fake/m", output[0].function_call.octoii.?.model.?);
    try std.testing.expectEqualStrings("fake/m", done.response.octoii.?.model.?);
}

test "a stream that stops early ends its open items and fails as transport, carrying what it began" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const message: vocabulary.OutputItem = .{ .output_message = .{ .id = "m1", .content = .{ .parts = &.{} } } };
    const answers = [_]Answer{.{ .events = &.{
        .{ .created = .{ .response = response(.in_progress), .sequence_number = 0 } },
        .{ .output_item_added = .{ .item = message, .output_index = 0, .sequence_number = 1 } },
        .{ .content_part_added = .{ .item_id = "m1", .output_index = 0, .sequence_number = 2, .content_index = 0, .part = .{ .output_text = .{ .text = "" } } } },
        .{ .output_text_delta = .{ .item_id = "m1", .output_index = 0, .sequence_number = 3, .content_index = 0, .delta = "par", .logprobs = &.{} } },
        .{ .output_text_delta = .{ .item_id = "m1", .output_index = 0, .sequence_number = 4, .content_index = 0, .delta = "tial", .logprobs = &.{} } },
    } }};
    const done = try run(a, &answers, hello);
    try std.testing.expectEqual(vocabulary.response.ResponseStatus.failed, done.response.status);
    try std.testing.expectEqual(vocabulary.FailureKind.transport, done.response.@"error".?.octoii.kind);
    const ended = done.response.output[0].output_message;
    try std.testing.expectEqual(.incomplete, ended.status.?);
    try std.testing.expectEqualStrings("partial", ended.content.parts[0].output_text.text);
}

test "an error the provider sends is the failure, whatever follows it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const answers = [_]Answer{.{ .events = &.{
        .{ .@"error" = .{ .code = "overloaded_error", .message = "busy", .octoii = .{ .kind = .server, .retryable = true, .status = 529 }, .sequence_number = 0 } },
        .{ .completed = .{ .response = response(.completed), .sequence_number = 1 } },
    } }};
    const done = try run(a, &answers, hello);
    const failed = done.response.@"error".?;
    try std.testing.expectEqualStrings("overloaded_error", failed.code);
    try std.testing.expectEqual(vocabulary.FailureKind.server, failed.octoii.kind);
}

test "a provider that fails as it streams ends the response with its failure" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const answers = [_]Answer{.{
        .events = &.{.{ .created = .{ .response = response(.in_progress), .sequence_number = 0 } }},
        .failure = .{ .kind = .rate_limit, .message = "slow down", .retryable = true, .retry_after_ms = 2000 },
    }};
    const done = try run(a, &answers, hello);
    try std.testing.expectEqual(@as(?u64, 2000), done.response.@"error".?.octoii.retry_after_ms);
    try std.testing.expectEqualStrings("r", done.response.id);
}

test "a stream its caller cut off ends incomplete, cancelled, with what came and no error: cut short, not failed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const begun: vocabulary.OutputItem = .{ .output_message = .{ .id = "m1", .content = .{ .parts = &.{} } } };
    const answers = [_]Answer{.{
        .events = &.{
            .{ .created = .{ .response = response(.in_progress), .sequence_number = 0 } },
            .{ .output_item_added = .{ .item = begun, .output_index = 0, .sequence_number = 1 } },
            .{ .content_part_added = .{ .item_id = "m1", .output_index = 0, .content_index = 0, .part = .{ .output_text = .{ .text = "" } }, .sequence_number = 2 } },
            .{ .output_text_delta = .{ .item_id = "m1", .output_index = 0, .content_index = 0, .delta = "Once upon", .logprobs = &.{}, .sequence_number = 3 } },
        },
        .failure = .{ .kind = .aborted, .message = "The request was aborted", .retryable = false },
    }};
    const done = try run(a, &answers, hello);
    try std.testing.expect(done.events[done.events.len - 1] == .incomplete);
    try std.testing.expectEqual(vocabulary.response.ResponseStatus.incomplete, done.response.status);
    try std.testing.expectEqual(.cancelled, done.response.incomplete_details.?.reason.?);
    try std.testing.expect(done.response.@"error" == null);
    const message = done.response.output[0].output_message;
    try std.testing.expectEqualStrings("Once upon", message.content.parts[0].output_text.text);
}

test "a request its model refuses fails before anything is sent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const unanswered = [_]vocabulary.Item{.{ .function_call = .{ .call_id = "c1", .name = "read", .arguments = "{}" } }};
    const done = try run(a, &.{}, .{ .model = "fake/m", .input = .{ .parts = &unanswered } });
    try std.testing.expectEqual(@as(usize, 0), done.requests.len);
    try std.testing.expectEqual(vocabulary.FailureKind.invalid_request, done.response.@"error".?.octoii.kind);
    try std.testing.expect(std.mem.indexOf(u8, done.response.@"error".?.message, "c1") != null);
    const elsewhere = try run(a, &.{}, .{ .model = "nowhere/m", .input = .{ .text = "hello" } });
    try std.testing.expectEqualStrings("No provider serves the model nowhere/m", elsewhere.response.@"error".?.message);
}

test "a request is prepared: its effort fitted, another model's reasoning left out, a stored file read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const parts = [_]vocabulary.InputContent{.{ .input_file = .{ .filename = "doc.pdf", .octoii = .{ .ref = "doc" } } }};
    const items = [_]vocabulary.Item{
        .{ .reasoning = .{ .id = "r0", .encrypted_content = "theirs", .octoii = .{ .model = "other/x" } } },
        .{ .reasoning = .{ .id = "r1", .encrypted_content = "mine", .octoii = .{ .model = "fake/m" } } },
        .{ .input_message = .{ .role = .user, .content = .{ .parts = &parts } } },
    };
    const answers = [_]Answer{.{ .events = &.{.{ .completed = .{ .response = response(.completed), .sequence_number = 0 } }} }};
    const done = try run(a, &answers, .{ .model = "fake/m", .input = .{ .parts = &items }, .reasoning = .{ .effort = .medium } });
    const sent = done.requests[0];
    try std.testing.expectEqual(vocabulary.items.ReasoningEffort.low, sent.reasoning.?.effort.?);
    const input = sent.input.?.parts;
    try std.testing.expectEqual(@as(usize, 2), input.len);
    try std.testing.expectEqualStrings("r1", input[0].reasoning.id);
    const file = input[1].input_message.content.parts[0].input_file;
    try std.testing.expectEqualStrings("data:application/pdf;base64,JVBERi0xLjcgaGVsbG8=", file.file_data.?);
    try std.testing.expectEqual(null, file.octoii.?.ref);
}

test "the directory serves a listing's models with their catalogue's facts, the person's joining those it lacks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ModelFacts = @import("../catalogue/facts.zig").ModelFacts;
    const calls = struct {
        fn list(_: *driver.Call) @import("../failure.zig").Error![]const ModelFacts {
            return &.{.{ .id = "listed", .name = "Listed", .context_length = 32_000 }};
        }
        fn text(call: *driver.Call, _: *const Model, _: *const vocabulary.ResponsesRequest) @import("../failure.zig").Error!driver.TextSource {
            return call.failWith(.invalid_request, "unsent", .{});
        }
    };
    const local: driver.Driver = .{ .id = "local", .name = "Local", .list = calls.list, .text = calls.text };
    const person = [_]ModelFacts{ .{ .id = "listed", .name = "Mine" }, .{ .id = "added", .context_length = 8000 } };
    var test_host: testing_host.Host = .{};
    const providers = [_]driver.Provider{.{ .id = "local", .name = "Local", .driver = &local, .models = &person }};
    const models = try Models.init(a, .{ .providers = &providers, .host = test_host.host(undefined) });
    defer models.deinit();
    // Before a refresh, a listing provider serves the person's models alone.
    try std.testing.expectEqual(@as(usize, 2), (try models.list(a, .text)).len);
    try models.refresh();
    const listed = (try models.find(a, "local/listed")).?.model;
    try std.testing.expectEqualStrings("Listed", listed.name);
    try std.testing.expectEqual(@as(?u64, 32_000), listed.context_length);
    try std.testing.expectEqual(@as(?u64, 8000), (try models.find(a, "local/added")).?.model.context_length);
    try std.testing.expectEqualStrings("local/listed", (try models.shadowed(a))[0]);
    const unlisted = (try models.find(a, "local/elsewhere")).?.model;
    try std.testing.expectEqual(@as(?u64, 200_000), unlisted.context_length);
    try std.testing.expectEqual(@as(usize, 2), (try models.list(a, .text)).len);
}

/// Makes a handle of the fake provider's models with `gpa`, then lets it go.
fn initModels(gpa: std.mem.Allocator) !void {
    var fake: Fake = .init(gpa, &.{});
    var test_host: testing_host.Host = .{};
    const providers = [_]driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{@import("../catalogue/facts.zig").asFacts(model)} }};
    const models = try Models.init(gpa, .{ .providers = &providers, .host = test_host.host(undefined) });
    models.deinit();
}

test "a handle of models frees what it took where an allocation fails as it is made" {
    try @import("foundation").testing.checkAllAllocationFailures(initModels, .{});
}
