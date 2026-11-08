//! `chatgpt`: OpenAI's Responses API on the person's ChatGPT plan, reached by signing in with ChatGPT. A request goes as
//! OpenAI's does, as a stream kept nowhere, but for what the plan does not take: its input as items, a system message as
//! a developer one, no caching marks and no identifiers; what the plan does not offer, the plan refuses itself. Its
//! failures are classified by the plan's codes, else as OpenAI's.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vocabulary = @import("vocabulary");
const Request = vocabulary.ResponsesRequest;
const seam = @import("../driver.zig");
const Call = seam.Call;
const failure_ = @import("../failure.zig");
const Error = failure_.Error;
const Kind = failure_.Kind;
const Model = @import("../catalogue/model.zig").Model;
const check = @import("../text/check.zig");
const http = @import("../wire/http.zig");
const responses = @import("../wire/responses.zig");
const signed_in = @import("../wire/signed_in.zig");
const source = @import("../wire/source.zig");
const openai = @import("openai.zig");
pub const sign_in = @import("chatgpt/sign_in.zig");

/// Where the API the plan opens is.
pub const base_url = "https://api.openai.com/v1";

pub const driver: seam.Driver = .{ .id = "chatgpt", .name = "ChatGPT", .catalogue = "chatgpt", .text = text, .sign_in = sign_in.begin };

/// The parts that work only at some providers which OpenAI's API takes.
const parts = [_]check.Part{ .custom_tools, .namespaces, .tool_search, .truncation };

/// The failure kind of each of the plan's own codes.
const plan_kinds = std.StaticStringMap(Kind).initComptime(.{
    .{ "subscription_sharing_usage_limit_exceeded", .quota },
    .{ "subscription_sharing_usage_unavailable", .server },
    .{ "subscription_sharing_user_unavailable", .server },
    .{ "subscription_sharing_user_not_eligible", .forbidden },
    .{ "subscription_sharing_invalid_user", .auth },
    .{ "chatpass_v2_scope_not_authorized", .auth },
    .{ "chatpass_v2_invalid_authorization_context", .auth },
    .{ "subscription_sharing_unsupported_capability", .invalid_request },
    .{ "subscription_sharing_route_not_supported", .invalid_request },
});

/// The failure kind of one of ChatGPT's codes or error types: the plan's own, else OpenAI's.
fn kindOf(code: []const u8) ?Kind {
    return plan_kinds.get(code) orelse openai.kindOf(code);
}

/// The request as it goes to ChatGPT for `model`: as OpenAI's Responses API takes it, its input as items, a system
/// message as a developer one, and without caching marks or identifiers, of which the plan takes none.
pub fn wireRequest(arena: Allocator, model: *const Model, request: Request) Allocator.Error![]const u8 {
    var sent = try responses.withoutExplicitCaching(arena, request);
    sent.metadata = null;
    sent.safety_identifier = null;
    sent.user = null;
    if (sent.input) |input| {
        const items: []vocabulary.Item = switch (input) {
            .text => |words| try arena.dupe(vocabulary.Item, &.{.{ .input_message = .{ .type = .message, .role = .user, .content = .{ .text = words } } }}),
            .parts => |given| try arena.dupe(vocabulary.Item, given),
        };
        for (items) |*item| if (item.* == .input_message and item.input_message.role == .system) {
            item.input_message.role = .developer;
        };
        sent.input = .{ .parts = items };
    }
    return responses.openAiRequest(arena, model, sent, "chatgpt");
}

fn text(call: *Call, model: *const Model, request: *const Request) Error!seam.TextSource {
    // A request goes as it would to OpenAI: what the plan does not offer, it refuses itself, naming the field.
    try check.parts(call, model, request, &parts);
    try responses.checkOpenAi(call, request, "chatgpt");
    try checkPlanScope(call);
    const response = try signed_in.send(call, sign_in.refresh, .{
        .method = .POST,
        .url = try std.fmt.allocPrint(call.arena, "{s}/responses", .{call.baseUrl(base_url)}),
        .headers = &.{ .{ .name = "accept", .value = "text/event-stream" }, .{ .name = "content-type", .value = "application/json" } },
        .body = try wireRequest(call.arena, model, request.*),
    });
    if (response.status < 200 or response.status >= 300) return call.fail(try http.failureOf(call, response, details));
    return source.of(vocabulary.ResponseStreamEvent, call, response, translate);
}

/// Checks that the sign-in's tokens may use the plan, by their scopes; one that holds no tokens fails as it is sent.
fn checkPlanScope(call: *Call) Error!void {
    const credential = try call.credential() orelse return;
    if (credential != .oauth) return;
    const tokens = credential.oauth.tokens orelse return;
    for (tokens.scopes) |scope| if (std.mem.eql(u8, scope, sign_in.plan_scope)) return;
    return call.failWith(.auth, "The sign-in to ChatGPT may not use the plan: its tokens lack the scope {s}; sign in again and allow the use of the plan", .{sign_in.plan_scope});
}

fn details(arena: Allocator, body: []const u8) ?http.Details {
    return responses.openAiDetails(arena, body, kindOf);
}

fn translate(call: *Call, data: []const u8, out: *std.ArrayList(vocabulary.ResponseStreamEvent)) Error!void {
    try out.append(call.arena, try responses.openAiEvent(call, data, kindOf));
}
