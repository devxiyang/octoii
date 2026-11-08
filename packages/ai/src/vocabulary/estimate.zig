//! An estimate of the tokens items take, before a provider counts them: a caller measures a context by the provider's
//! count of the newest response and an estimate of what came after it. No request fails on an estimate: one too long
//! for its model's window is its provider's to refuse.
const std = @import("std");
const foundation = @import("foundation");
const content = @import("content.zig");
const Item = @import("items.zig").Item;

/// The characters an estimated token takes.
pub const characters_per_token = 4;

/// The tokens an estimate gives each file, whatever its size.
pub const file_tokens = 1500;

/// The tokens `text` takes, estimated.
pub fn text(bytes: []const u8) u64 {
    return std.math.divCeil(u64, characters(bytes), characters_per_token) catch unreachable;
}

/// The tokens `list` takes, estimated: its text at `characters_per_token` characters a token, and each file at
/// `file_tokens`. What only the model that wrote it reads, such as encrypted reasoning, is not counted.
pub fn items(list: []const Item) u64 {
    var measure: Measure = .{};
    for (list) |item| measure.add(item);
    const tokens = std.math.divCeil(u64, measure.characters, characters_per_token) catch unreachable;
    return tokens + measure.files * file_tokens;
}

/// What an estimate counts: characters of text, and files.
const Measure = struct {
    characters: u64 = 0,
    files: u64 = 0,

    fn add(measure: *Measure, item: Item) void {
        switch (item) {
            .input_message => |message| measure.addInput(message.content),
            .output_message => |message| measure.addOutput(message.content),
            .function_call_output => |output| measure.addInput(output.output),
            .custom_tool_call_output => |output| measure.addInput(output.output),
            .function_call => |call| measure.addText(call.name, call.arguments),
            .armor_blocked => |call| measure.addText(call.name, call.arguments),
            .custom_tool_call => |call| measure.addText(call.name, call.input),
            .reasoning => |reasoning| {
                for (reasoning.summary orelse &.{}) |part| measure.characters += characters(part.text);
                for (reasoning.content orelse &.{}) |part| measure.characters += characters(part.text);
            },
            .additional_tools => |added| measure.characters += encodedCharacters(added.tools),
            .tool_search_output => |found| measure.characters += encodedCharacters(found.tools),
            .tool_search_call => |call| if (call.arguments) |arguments| {
                measure.characters += characters(arguments.text);
            },
            // The definitions it found are tools the model reads from here on, as a `tool_search_output`'s are.
            .openrouter_tool_search => |search| {
                measure.characters += characters(search.query orelse "");
                for (search.matches orelse &.{}) |match| measure.characters += characters(match.definition.text);
            },
            // The provider's own records, and changes of settings: no text the model reads as written.
            .web_search_call, .openrouter_web_search, .compaction, .context_compaction, .configuration_update, .tool_removal => {},
        }
    }

    fn addText(measure: *Measure, name: []const u8, body: []const u8) void {
        measure.characters += characters(name) + characters(body);
    }

    fn addInput(measure: *Measure, given: content.TextOr(content.InputContent)) void {
        const parts = switch (given) {
            .text => |whole| return measure.addText("", whole),
            .parts => |parts| parts,
        };
        for (parts) |part| switch (part) {
            .input_text => |input| measure.characters += characters(input.text),
            .input_image, .input_file, .input_audio, .input_video => measure.files += 1,
        };
    }

    fn addOutput(measure: *Measure, given: content.TextOr(content.OutputContent)) void {
        const parts = switch (given) {
            .text => |whole| return measure.addText("", whole),
            .parts => |parts| parts,
        };
        for (parts) |part| switch (part) {
            .output_text => |output| measure.characters += characters(output.text),
            .refusal => |refusal| measure.characters += characters(refusal.refusal),
            .output_image => measure.files += 1,
        };
    }
};

/// The characters of UTF-8 text: every byte that begins one.
fn characters(bytes: []const u8) u64 {
    var count: u64 = 0;
    for (bytes) |byte| count += @intFromBool(byte & 0xC0 != 0x80);
    return count;
}

/// The characters of `value`'s canonical encoding, counted as it is written.
fn encodedCharacters(value: anytype) u64 {
    var counter: Counter = .{};
    // The counter's drain never fails, so neither does the writing.
    std.json.Stringify.value(value, foundation.json.options, &counter.writer) catch unreachable;
    return counter.characters;
}

/// A writer that keeps nothing and counts the characters written to it.
const Counter = struct {
    characters: u64 = 0,
    writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const counter: *Counter = @alignCast(@fieldParentPtr("writer", writer));
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            counter.characters += characters(bytes);
            written += bytes.len;
        }
        const pattern = data[data.len - 1];
        counter.characters += characters(pattern) * splat;
        return written + pattern.len * splat;
    }
};

test "text takes a token for every four characters, rounded up, whatever their bytes" {
    try std.testing.expectEqual(@as(u64, 0), text(""));
    try std.testing.expectEqual(@as(u64, 1), text("four"));
    try std.testing.expectEqual(@as(u64, 2), text("fives"));
    try std.testing.expectEqual(@as(u64, 1), text("你好世界"));
}

test "items count their text and their files, and leave out what only their model reads" {
    const parts = [_]content.InputContent{
        .{ .input_text = .{ .text = "look at this" } },
        .{ .input_image = .{ .detail = .auto, .image_url = "https://example.com/a.png" } },
    };
    const list = [_]Item{
        .{ .input_message = .{ .role = .user, .content = .{ .parts = &parts } } },
        .{ .function_call = .{ .call_id = "c", .name = "read", .arguments = "{}" } },
        .{ .reasoning = .{ .id = "r", .summary = &.{.{ .text = "why" }}, .encrypted_content = "secret" } },
        .{ .compaction = .{ .encrypted_content = "secret" } },
    };
    // 12 + 4 + 2 + 3 characters, 21 in all, and one file.
    try std.testing.expectEqual(@as(u64, 6 + file_tokens), items(&list));
}

test "added tools count as their encoding is written" {
    const added = [_]Item{.{ .additional_tools = .{ .role = .developer, .tools = &.{.{ .custom = .{ .name = "x" } }} } }};
    // [{"type":"custom","name":"x"}] is 30 characters.
    try std.testing.expectEqual(@as(u64, 8), items(&added));
}
