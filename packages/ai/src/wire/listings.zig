//! What the drivers of servers that list their models share: a server's answer read without failing where the server
//! is absent, how its provider stands by whether it answers, and the facts of a model a server on this machine lists,
//! priced at nothing.
const std = @import("std");
const foundation = @import("foundation");
const seam = @import("../driver.zig");
const Call = seam.Call;
const Error = @import("../failure.zig").Error;
const model_ = @import("../catalogue/model.zig");
const ModelFacts = @import("../catalogue/facts.zig").ModelFacts;

/// The largest answer of a server that is read.
const answer_max = 8 << 20;

/// The JSON the server answers `request` with, read as `T`; null where the server does not answer, answers with a
/// failure, or with what is not `T`, as an absent server does.
pub fn answer(comptime T: type, call: *Call, request: foundation.http.Request) Error!?T {
    var sent = request;
    if (sent.wait == null) sent.wait = call.wait;
    // A server that is not running refuses the connection: it has no models, which is no failure.
    const response = call.host.network().send(sent) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer response.close();
    if (response.status < 200 or response.status >= 300) return null;
    const text = response.body.allocRemaining(call.arena, .limited(answer_max)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return foundation.json.decode(T, call.arena, text) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

/// How the provider of a server stands, by whether it answered at `url`.
pub fn status(call: *Call, answered: bool, url: []const u8) Error!seam.Status {
    if (answered) return .{ .connected = true };
    return .{ .connected = false, .problem = try call.arena.print("No server answers with its models at {s}", .{url}) };
}

/// What a server on this machine says of one of its text models.
pub const Local = struct {
    id: []const u8,
    /// The name the server shows; empty, the id stands for it.
    name: []const u8,
    /// Its window, where the server says.
    context_length: ?u64,
    reads_images: bool,
};

/// The facts of a text model of a server on this machine, its prices nothing.
pub fn localModel(given: Local) ModelFacts {
    const inputs: []const model_.InputModality = if (given.reads_images) &.{ .text, .image } else &.{.text};
    return .{
        .id = given.id,
        .name = if (given.name.len == 0) null else given.name,
        .context_length = if (given.context_length) |length| (if (length > 0) length else null) else null,
        .architecture = .{ .input_modalities = inputs, .output_modalities = &.{.text} },
        .pricing = .{ .prompt = "0", .completion = "0" },
        .octoii = .{ .kinds = &.{.text} },
    };
}
