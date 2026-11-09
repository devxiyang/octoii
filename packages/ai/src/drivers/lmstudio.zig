//! `lmstudio`: the driver of a server of LM Studio's, on this machine unless its provider says where, which needs no
//! credential. It serves the text kind through its Chat Completions server. Its models are those of type `llm` its
//! REST API lists at `/api/v1/models`: reading images where their capabilities say `vision`, their window the least of
//! their loaded instances', else their largest.
const std = @import("std");
const seam = @import("../driver.zig");
const Call = seam.Call;
const Error = @import("../failure.zig").Error;
const ModelFacts = @import("../catalogue/facts.zig").ModelFacts;
const chat = @import("../wire/chat_completions.zig");
const listings = @import("../wire/listings.zig");
const server = @import("chat_completions.zig");

/// LM Studio's address on this machine, unless its provider gives another.
pub const base_url = "http://127.0.0.1:1234";

pub const driver: seam.Driver = .{
    .id = "lmstudio",
    .name = "LM Studio",
    .text = chat.text(server.Settings, server.dialect(base_url, "/v1/chat/completions")),
    .list = list,
    .status = status,
};

/// One model of its listing, as far as it is read.
const Listed = struct {
    type: []const u8,
    key: []const u8,
    display_name: []const u8,
    max_context_length: ?u64 = null,
    loaded_instances: []const struct { config: struct { context_length: u64 } },
    capabilities: ?struct { vision: bool } = null,

    /// Its window: the least of its loaded instances', as a loaded model serves no more, else the largest it takes.
    fn contextLength(listed: Listed) ?u64 {
        var least: ?u64 = null;
        for (listed.loaded_instances) |instance| least = @min(least orelse instance.config.context_length, instance.config.context_length);
        return least orelse listed.max_context_length;
    }
};

const Listing = struct { models: []const Listed };

fn list(call: *Call) Error![]const ModelFacts {
    const listing = try listingOf(call) orelse return &.{};
    var listed: std.ArrayList(ModelFacts) = .empty;
    for (listing.models) |each| {
        if (!std.mem.eql(u8, each.type, "llm")) continue;
        const reads_images = if (each.capabilities) |capabilities| capabilities.vision else false;
        try listed.append(call.arena, listings.localModel(.{ .id = each.key, .name = each.display_name, .context_length = each.contextLength(), .reads_images = reads_images }));
    }
    return listed.items;
}

fn status(call: *Call) Error!seam.Status {
    const answered = try listingOf(call) != null;
    return listings.status(call, answered, try modelsUrl(call));
}

fn listingOf(call: *Call) Error!?Listing {
    return listings.answer(Listing, call, .{ .url = try modelsUrl(call) });
}

fn modelsUrl(call: *Call) Error![]const u8 {
    return call.arena.print("{s}/api/v1/models", .{call.baseUrl(base_url)});
}
