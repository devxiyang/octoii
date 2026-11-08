//! A text request prepared for its model, after its checks: the reasoning effort fitted to the efforts the model
//! takes; what another model wrote for itself left out, and provider metadata only for the model that reads it; a
//! function call's arguments that are not a JSON object sent as an empty one; stored files read into inline data; and
//! every image, file and video inline a data URL of the type it is. Octoii's extensions stay for the driver to read,
//! and none reaches the wire.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vocabulary = @import("vocabulary");
const Request = vocabulary.ResponsesRequest;
const Item = vocabulary.Item;
const ReasoningEffort = vocabulary.items.ReasoningEffort;
const FileExtension = vocabulary.extensions.FileExtension;
const ItemExtension = vocabulary.extensions.ItemExtension;
const Error = @import("../failure.zig").Error;
const driver = @import("../driver.zig");
const Call = driver.Call;
const model_ = @import("../catalogue/model.zig");
const Model = model_.Model;
const Models = @import("../Models.zig");
const files = @import("files.zig");

/// Whose provider metadata the model a request is prepared for reads.
pub const Reading = struct {
    models: *Models,
    provider: *const driver.Provider,
    /// The reference of the model the request is for.
    reference: []const u8,

    fn readsMetadataOf(reading: Reading, writer: []const u8) bool {
        return reading.models.readsMetadataOf(reading.reference, reading.provider, writer);
    }
};

/// The efforts, lowest first.
const efforts = [_]ReasoningEffort{ .none, .minimal, .low, .medium, .high, .xhigh, .max };

/// `given` prepared for `model`.
pub fn request(call: *Call, model: *const Model, given: Request, reading: Reading) Error!Request {
    var prepared = given;
    prepared.reasoning = preparedReasoning(model, given.reasoning);
    if (given.input) |input| switch (input) {
        .text => {},
        .parts => |list| {
            var stored: Stored = .{ .call = call };
            var kept: std.ArrayList(Item) = .empty;
            for (list) |item| {
                const made = try keptItem(call.arena, model, reading, item) orelse continue;
                try kept.append(call.arena, try withFilesRead(&stored, made));
            }
            prepared.input = .{ .parts = kept.items };
        },
    };
    return prepared;
}

/// The request's reasoning settings as `model` is sent them: none where it does not reason, fitted where it says how
/// it reasons, and as asked where whether or how it reasons is unknown.
fn preparedReasoning(model: *const Model, asked: ?vocabulary.request.ReasoningConfig) ?vocabulary.request.ReasoningConfig {
    if (model.reasons() == false) return null;
    const how = model.reasoning orelse return asked;
    var fitted = asked orelse return null;
    const wanted: ?ReasoningEffort = if (fitted.enabled == false) .none else fitted.effort;
    if (fitted.enabled == false) fitted.enabled = null;
    if (wanted) |effort| fitted.effort = fittedEffort(how, effort);
    return fitted;
}

/// An effort as `model` is sent it: none where it does not reason, fitted where it says how it reasons, else as asked.
fn preparedEffort(model: *const Model, asked: ReasoningEffort) ?ReasoningEffort {
    if (model.reasons() == false) return null;
    const how = model.reasoning orelse return asked;
    return fittedEffort(how, asked);
}

/// The effort a model takes nearest to `asked`: the highest it takes at or below it, else the lowest it takes. A model
/// without a list takes every effort, but `none` where it always reasons.
pub fn fittedEffort(how: model_.Reasoning, asked: ReasoningEffort) ReasoningEffort {
    var highest_below: ?ReasoningEffort = null;
    var lowest: ?ReasoningEffort = null;
    for (efforts) |effort| {
        const takes = if (how.supported_efforts) |listed| std.mem.indexOfScalar(ReasoningEffort, listed, effort) != null else effort != .none or !how.mandatory;
        if (!takes) continue;
        if (lowest == null) lowest = effort;
        if (rank(effort) <= rank(asked)) highest_below = effort;
    }
    return highest_below orelse lowest orelse asked;
}

fn rank(effort: ReasoningEffort) usize {
    return std.mem.indexOfScalar(ReasoningEffort, &efforts, effort).?;
}

/// `item` as `model` is sent it, or null where it is another model's own or changes an effort for a model that does
/// not reason.
fn keptItem(arena: Allocator, model: *const Model, reading: Reading, item: Item) Allocator.Error!?Item {
    var kept = item;
    switch (kept) {
        // Only the model that wrote these reads them: their encrypted content and signatures mean nothing to another.
        inline .reasoning, .web_search_call, .openrouter_web_search, .compaction, .context_compaction => |own| {
            const writer = if (own.octoii) |extension| extension.model else null;
            if (writer == null or !std.mem.eql(u8, writer.?, reading.reference)) return null;
        },
        .configuration_update => |*update| update.reasoning.effort = preparedEffort(model, update.reasoning.effort) orelse return null,
        .function_call => |*call| {
            call.arguments = try objectArguments(arena, call.arguments);
            call.octoii = ownExtension(call.octoii, reading);
        },
        inline .custom_tool_call, .tool_search_call, .tool_search_output, .openrouter_tool_search, .armor_blocked, .output_message => |*own| {
            own.octoii = ownExtension(own.octoii, reading);
        },
        else => {},
    }
    return kept;
}

/// A function call's arguments where they are a JSON object, else an empty object, as when the output limit cut
/// them or the model wrote them malformed: a provider may read them as an object.
fn objectArguments(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return "{}",
    };
    return if (value == .object) text else "{}";
}

/// An item's `octoii` without its provider metadata where the model it is sent to does not read the metadata of the
/// model that wrote it.
fn ownExtension(given: ?ItemExtension, reading: Reading) ?ItemExtension {
    const extension = given orelse return null;
    if (extension.provider_metadata == null) return extension;
    if (extension.model) |writer| if (reading.readsMetadataOf(writer)) return extension;
    return .{ .model = extension.model };
}

/// The stored files of one request, each read once.
const Stored = struct {
    call: *Call,
    read: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// The bytes of the stored file `ref`; `invalid_request` where they cannot be read.
    fn bytes(stored: *Stored, ref: []const u8) Error![]const u8 {
        if (stored.read.get(ref)) |known| return known;
        const call = stored.call;
        const host_files = call.host.files orelse return call.failWith(.invalid_request, "The request holds the stored file {s}, and the host gives no stored files", .{ref});
        const got = host_files.read(call.arena, ref) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return call.failWith(.invalid_request, "The stored file {s} cannot be read: {t}", .{ ref, err }),
        };
        try stored.read.put(call.arena, ref, got);
        return got;
    }
};

/// `item` with the stored files of its content read into inline data, and its files inline typed.
fn withFilesRead(stored: *Stored, item: Item) Error!Item {
    var read = item;
    switch (read) {
        .input_message => |*message| message.content = try inlinedAll(stored, message.content),
        inline .function_call_output, .custom_tool_call_output => |*output| output.output = try inlinedAll(stored, output.output),
        else => {},
    }
    return read;
}

fn inlinedAll(stored: *Stored, given: vocabulary.TextOr(vocabulary.InputContent)) Error!vocabulary.TextOr(vocabulary.InputContent) {
    const list = switch (given) {
        .text => return given,
        .parts => |list| list,
    };
    const made = try stored.call.arena.alloc(vocabulary.InputContent, list.len);
    for (list, made) |part, *copy| copy.* = try inlined(stored, part);
    return .{ .parts = made };
}

/// `part` with a stored file's bytes inline in place of its reference, of the type its `octoii`, its first bytes or
/// its name say, its type and name kept under `octoii`; a file inline already a data URL of the type it is.
fn inlined(stored: *Stored, part: vocabulary.InputContent) Error!vocabulary.InputContent {
    const call = stored.call;
    if (part == .input_text) return part;
    const extension = switch (part) {
        .input_text => unreachable,
        inline else => |file| file.octoii,
    };
    const ref = if (extension) |given| given.ref else null;
    if (part == .input_audio) {
        const of = ref orelse return part;
        var audio = part.input_audio;
        audio.input_audio.data = try base64(call.arena, try stored.bytes(of));
        audio.octoii = withoutRef(extension);
        return .{ .input_audio = audio };
    }
    const typed = files.TypedFile.of(part).?;
    const what = try files.described(call.arena, typed);
    const of = ref orelse return contentOf(try files.typedInline(call.arena, typed, try files.checkedType(call, typed, what, null)));
    const bytes = try stored.bytes(of);
    const media_type = try files.checkedType(call, typed, what, .{ .bytes = bytes });
    var octoii = withoutRef(extension);
    octoii.media_type = media_type;
    const url = try std.fmt.allocPrint(call.arena, "data:{s};base64,{s}", .{ media_type, try base64(call.arena, bytes) });
    return switch (part) {
        .input_image => |image| .{ .input_image = .{ .detail = image.detail, .image_url = url, .octoii = octoii } },
        .input_file => |file| .{ .input_file = .{ .file_data = url, .filename = file.filename, .octoii = octoii } },
        .input_video => |video| .{ .input_video = .{ .video_url = url, .processing = video.processing, .octoii = octoii } },
        .input_text, .input_audio => unreachable,
    };
}

fn contentOf(file: files.TypedFile) vocabulary.InputContent {
    return switch (file) {
        .input_image => |image| .{ .input_image = image },
        .input_file => |given| .{ .input_file = given },
        .input_video => |video| .{ .input_video = video },
    };
}

/// A file's `octoii` once its bytes are inline: its media type and name, without the reference they came from.
fn withoutRef(given: ?FileExtension) FileExtension {
    const extension = given orelse return .{};
    return .{ .media_type = extension.media_type, .filename = extension.filename };
}

fn base64(arena: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try arena.alloc(u8, encoder.calcSize(bytes.len));
    return encoder.encode(out, bytes);
}

test "an effort is fitted to the highest the model takes at or below it, else its lowest" {
    const listed: model_.Reasoning = .{ .supported_efforts = &.{ .high, .medium, .low }, .mandatory = true };
    try std.testing.expectEqual(ReasoningEffort.high, fittedEffort(listed, .max));
    try std.testing.expectEqual(ReasoningEffort.medium, fittedEffort(listed, .medium));
    try std.testing.expectEqual(ReasoningEffort.low, fittedEffort(listed, .minimal));
    try std.testing.expectEqual(ReasoningEffort.minimal, fittedEffort(.{ .mandatory = true }, .none));
    try std.testing.expectEqual(ReasoningEffort.none, fittedEffort(.{ .mandatory = false }, .none));
}
