//! `claude`: Claude through the person's own Claude Code, by the agent gateway the host runs — which answers
//! Anthropic's Messages API on a channel the host holds, `gateway://claude/v1`, Claude Code thinking and the host's
//! tools acting. It needs no credential of its own: the person signs in to Claude Code itself. Its models are those
//! Claude Code offers, as the gateway lists them; what they use is the person's plan's, so they cost nothing here.
const std = @import("std");
const vocabulary = @import("vocabulary");
const seam = @import("../driver.zig");
const Call = seam.Call;
const Error = @import("../failure.zig").Error;
const ModelFacts = @import("../catalogue/facts.zig").ModelFacts;
const Model = @import("../catalogue/model.zig").Model;
const listings = @import("../wire/listings.zig");
const anthropic = @import("anthropic.zig");

/// Where the agent gateway answers for Claude, on the host's channel to it.
pub const base_url = "gateway://claude/v1";

pub const driver: seam.Driver = .{ .id = "claude", .name = "Claude", .text = text, .list = list, .status = status };

fn text(call: *Call, model: *const Model, request: *const vocabulary.ResponsesRequest) Error!seam.TextSource {
    return anthropic.textAt(call, model, request, base_url, &.{});
}

/// The gateway's listing of models, as Anthropic's API lists them: each by the name Claude Code takes, and the name a
/// person reads.
const Listing = struct { data: []const struct { id: []const u8, display_name: []const u8 = "" } };

/// The models Claude Code offers, each reading images, its window unknown till the gateway tells it, costing nothing.
fn list(call: *Call) Error![]const ModelFacts {
    const listing = try listings.answer(Listing, call, .{ .url = try modelsUrl(call) }) orelse return &.{};
    const facts = try call.arena.alloc(ModelFacts, listing.data.len);
    for (listing.data, facts) |each, *made| made.* = listings.localModel(.{ .id = each.id, .name = each.display_name, .context_length = null, .reads_images = true });
    return facts;
}

/// Connected where the gateway lists Claude Code's models: Claude Code is there, and the person signed in to it.
fn status(call: *Call) Error!seam.Status {
    const url = try modelsUrl(call);
    return listings.status(call, try listings.answer(Listing, call, .{ .url = url }) != null, url);
}

fn modelsUrl(call: *Call) Error![]const u8 {
    return call.arena.print("{s}/models", .{call.baseUrl(base_url)});
}
