//! `claude`: Claude through the person's own Claude Code, by the agent gateway the host runs — which answers
//! Anthropic's Messages API on a channel the host holds, `gateway://claude/v1`, Claude Code thinking and the host's
//! tools acting. It needs no credential of its own: the person signs in to Claude Code itself. Its models are those
//! Claude Code offers, as the gateway lists them; what they use is the person's plan's, so they cost nothing here.
//! Each request names its conversation, by which the gateway keeps the conversation's session of Claude Code, and lets
//! it go once the conversation ended. An account the person added is another login of Claude Code's, kept apart by the
//! gateway under the account's id, at `gateway://claude/accounts/{id}/v1`.
const std = @import("std");
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const seam = @import("../driver.zig");
const Call = seam.Call;
const Error = @import("../failure.zig").Error;
const ModelFacts = @import("../catalogue/facts.zig").ModelFacts;
const Model = @import("../catalogue/model.zig").Model;
const listings = @import("../wire/listings.zig");
const http = @import("../wire/http.zig");
const anthropic = @import("anthropic.zig");

/// Where the agent gateway answers for Claude, on the host's channel to it.
pub const base_url = "gateway://claude/v1";

pub const driver: seam.Driver = .{ .id = "claude", .name = "Claude", .text = text, .list = list, .status = status, .forget = forget, .instance = instance };

/// An added account, at its own address on the gateway.
fn instance(arena: std.mem.Allocator, account: []const u8, base: seam.Settings) std.mem.Allocator.Error!seam.Settings {
    return .{ .base_url = try arena.print("gateway://claude/accounts/{f}/v1", .{std.fmt.alt(std.Uri.Component{ .raw = account }, .formatEscaped)}), .headers = base.headers };
}

/// The header that names the conversation a request is of: its `prompt_cache_key`.
pub const conversation_header = "conversation-id";

fn text(call: *Call, model: *const Model, request: *const vocabulary.ResponsesRequest) Error!seam.TextSource {
    const key = request.prompt_cache_key orelse return anthropic.textAt(call, model, request, base_url, &.{});
    const conversation = [_]foundation.http.Header{.{ .name = conversation_header, .value = key }};
    return anthropic.textAt(call, model, request, base_url, &conversation);
}

/// Has the gateway let go of the conversation's session, as the conversation ended.
fn forget(call: *Call, conversation: []const u8) Error!void {
    const url = try call.arena.print("{s}/conversations/{f}", .{ call.baseUrl(base_url), std.fmt.alt(std.Uri.Component{ .raw = conversation }, .formatEscaped) });
    const response = try http.send(call, .{ .method = .DELETE, .url = url });
    if (response.status < 200 or response.status >= 300) return call.fail(try http.failureOf(call, response, null));
    response.close();
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

/// Who Claude Code is signed in as, as the gateway tells: an email, the plan it is on where it says, and how much of
/// each of the plan's limits is used.
const Account = struct { email: []const u8, subscription_type: ?[]const u8 = null, limits: []const seam.Limit = &.{} };

/// The most of the gateway's account read.
const account_bytes_max = 64 << 10;

/// Connected where Claude Code is signed in on this computer, as the gateway tells: as whom, on which plan, and how
/// much of each of its limits is used; else what the gateway says is wrong — Claude Code not there, or not signed in.
fn status(call: *Call) Error!seam.Status {
    const url = try call.arena.print("{s}/account", .{call.baseUrl(base_url)});
    const response = try http.send(call, .{ .url = url });
    if (response.status < 200 or response.status >= 300) return call.fail(try http.failureOf(call, response, anthropic.details));
    defer response.close();
    const body = response.body.allocRemaining(call.arena, .limited(account_bytes_max)) catch return http.readFailure(call, response);
    const account = try http.parse(Account, call, body, "account");
    const plan = account.subscription_type orelse return .{ .connected = true, .account = account.email, .limits = account.limits };
    return .{ .connected = true, .account = try call.arena.print("{s} ({s})", .{ account.email, plan }), .limits = account.limits };
}

fn modelsUrl(call: *Call) Error![]const u8 {
    return call.arena.print("{s}/models", .{call.baseUrl(base_url)});
}
