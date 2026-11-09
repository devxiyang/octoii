//! `ollama`: the driver of a server of Ollama's, on this machine unless its provider says where, which needs no
//! credential. It serves the text kind through its Chat Completions server. Its models are those it lists at
//! `/api/tags` whose capabilities, as `/api/show` says, hold `completion`: reading images where they hold `vision`,
//! their window their architecture's `context_length`.
const std = @import("std");
const seam = @import("../driver.zig");
const Call = seam.Call;
const Error = @import("../failure.zig").Error;
const ModelFacts = @import("../catalogue/facts.zig").ModelFacts;
const chat = @import("../wire/chat_completions.zig");
const listings = @import("../wire/listings.zig");
const server = @import("chat_completions.zig");

/// Ollama's address on this machine, unless its provider gives another.
pub const base_url = "http://127.0.0.1:11434";

pub const driver: seam.Driver = .{
    .id = "ollama",
    .name = "Ollama",
    .text = chat.text(server.Settings, server.dialect(base_url, "/v1/chat/completions")),
    .list = list,
    .status = status,
};

/// Its listing of models, of which only the names are read.
const Tags = struct { models: []const struct { name: []const u8, model: []const u8 } };

/// What it says of one model: what it does, and its architecture's facts.
const Shown = struct { capabilities: ?[]const []const u8 = null, model_info: ?std.json.Value = null };

fn list(call: *Call) Error![]const ModelFacts {
    const tags = try tagsOf(call) orelse return &.{};
    var listed: std.ArrayList(ModelFacts) = .empty;
    for (tags.models) |each| if (try shownFacts(call, each.name, each.model)) |facts| try listed.append(call.arena, facts);
    return listed.items;
}

fn status(call: *Call) Error!seam.Status {
    const answered = try tagsOf(call) != null;
    return listings.status(call, answered, try urlOf(call, "/api/tags"));
}

fn tagsOf(call: *Call) Error!?Tags {
    return listings.answer(Tags, call, .{ .url = try urlOf(call, "/api/tags") });
}

/// The facts of the text model `model` is, from what the server says of it; null for one that is not, or whose
/// details cannot be read.
fn shownFacts(call: *Call, name: []const u8, model: []const u8) Error!?ModelFacts {
    const shown = try listings.answer(Shown, call, .{
        .method = .POST,
        .url = try urlOf(call, "/api/show"),
        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .body = try @import("foundation").json.encode(call.arena, .{ .model = model }),
    }) orelse return null;
    const capabilities = shown.capabilities orelse &.{};
    if (!holds(capabilities, "completion")) return null;
    return listings.localModel(.{ .id = model, .name = name, .context_length = contextLength(shown.model_info), .reads_images = holds(capabilities, "vision") });
}

fn holds(capabilities: []const []const u8, capability: []const u8) bool {
    for (capabilities) |each| if (std.mem.eql(u8, each, capability)) return true;
    return false;
}

/// The window the model's facts give under the name of its architecture, `general.architecture`.
fn contextLength(info: ?std.json.Value) ?u64 {
    const facts = info orelse return null;
    if (facts != .object) return null;
    const architecture = facts.object.get("general.architecture") orelse return null;
    if (architecture != .string) return null;
    var key_buffer: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buffer, "{s}.context_length", .{architecture.string}) catch return null;
    const length = facts.object.get(key) orelse return null;
    return if (length == .integer and length.integer > 0) @intCast(length.integer) else null;
}

fn urlOf(call: *Call, path: []const u8) Error![]const u8 {
    return call.arena.print("{s}{s}", .{ call.baseUrl(base_url), path });
}
