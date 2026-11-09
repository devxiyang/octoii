//! ChatGPT's driver: its requests and failures against its recorded exchanges, its refresh and its sign-in against a
//! fake issuer.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const oauth = foundation.oauth;
const vocabulary = @import("vocabulary");
const FailureKind = vocabulary.FailureKind;
const seam = @import("../driver.zig");
const Models = @import("../Models.zig");
const fixtures = @import("../testing/fixtures.zig");
const TestHost = @import("../testing/host.zig").Host;
const now_ms = @import("../testing/host.zig").now_ms;
const issuer_ = @import("../testing/issuer.zig");
const Issuer = issuer_.Issuer;
const chatgpt = @import("chatgpt.zig");
const sign_in = chatgpt.sign_in;
const signed_in = @import("../wire/signed_in.zig");

/// The client the issuer registered for the person at their first sign-in.
const client = "oaiapp_9f2c4e1a";

/// This host's id, chosen at its first sign-in.
const host_id = "urn:uuid:00010203-0405-4607-8809-0a0b0c0d0e0f";

const redirect_uri = "http://127.0.0.1:1455/auth/callback";

/// A sign-in whose tokens are good for an hour more, expiring `in_ms` from now unless said, with `scopes`.
fn signedIn(in_ms: i64, scopes: []const []const u8) seam.Credential {
    return .{ .oauth = .{
        .issuer = sign_in.issuer,
        .client_id = client,
        .host_id = host_id,
        .subject = "user-4Kq2",
        .email = "person@example.com",
        .tokens = .{ .access = "access-1", .refresh = "refresh-1", .expires_at_ms = now_ms + in_ms, .scopes = scopes },
    } };
}

const options: fixtures.Options = .{ .driver = &chatgpt.driver, .key = null, .credential = signedIn(3_600_000, &sign_in.scopes) };

/// `Models` over ChatGPT, its host keeping `credential` and its HTTP the issuer's, the API behind it.
fn modelsWith(arena: Allocator, credential: ?seam.Credential, issuer: *Issuer) !struct { models: *Models, host: *TestHost } {
    const host = try arena.create(TestHost);
    host.* = .{ .saved = if (credential) |given| .{ .provider = "chatgpt", .credential = given } else null };
    const providers = try arena.dupe(seam.Provider, &.{.{ .id = "chatgpt", .name = "ChatGPT", .driver = &chatgpt.driver }});
    return .{ .models = try Models.init(arena, .{ .providers = providers, .host = host.host(issuer.network()) }), .host = host };
}

fn expectForm(arena: Allocator, expected: []const oauth.Field, actual: []const oauth.Field) !void {
    try fixtures.expectJson(arena, try foundation.json.encode(arena, expected), try foundation.json.encode(arena, actual));
}

test "ChatGPT signs in and serves the catalogue's models with the sign-in's access token, as a stream" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    try std.testing.expectEqualStrings("chatgpt", chatgpt.driver.catalogue.?);
    try std.testing.expect(chatgpt.driver.sign_in != null);
    const streamed = try fixtures.streamFixture(arena, "text", options);
    try std.testing.expect(streamed.events[1] == .metadata);
    const sent = streamed.replay.sent.items[0];
    try std.testing.expectEqualStrings("https://api.openai.com/v1/responses", sent.url);
    try std.testing.expectEqualStrings("Bearer access-1", foundation.http.find(sent.headers, "authorization").?);
    try std.testing.expectEqualStrings("text/event-stream", foundation.http.find(sent.headers, "accept").?);
    try std.testing.expectEqualStrings("Hello! How can I help?", (try fixtures.messageText(arena, streamed.response.output)).?);
}

/// The recorded stream of `text`, with `chunk` sent after its first event.
fn withChunk(arena: Allocator, chunk: []const u8) !struct { fixture: fixtures.Fixture, exchanges: []foundation.replay.Exchange } {
    const fixture = try fixtures.load(arena, "chatgpt", "text");
    const exchanges = try arena.dupe(foundation.replay.Exchange, fixture.exchanges);
    const recorded = exchanges[0].response.chunks;
    const chunks = try arena.alloc(foundation.replay.Chunk, recorded.len + 1);
    chunks[0] = recorded[0];
    chunks[1] = .{ .text = chunk };
    @memcpy(chunks[2..], recorded[1..]);
    exchanges[0].response.chunks = chunks;
    return .{ .fixture = fixture, .exchanges = exchanges };
}

test "an event of a type the vocabulary lacks is passed over, once noted, and the answer comes whole" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    const unlisted = "event: response.from_the_future\ndata: {\"type\":\"response.from_the_future\",\"sequence_number\":1}\n\n";
    const given = try withChunk(arena, unlisted);
    const streamed = try fixtures.stream(arena, given.fixture.request, given.exchanges, options);
    try std.testing.expectEqual(@as(usize, 1), streamed.unlisted);
    try std.testing.expectEqual(vocabulary.response.ResponseStatus.completed, streamed.response.status);
    try std.testing.expectEqualStrings("Hello! How can I help?", (try fixtures.messageText(arena, streamed.response.output)).?);
}

test "an event of a type the vocabulary has that does not fit it fails the response" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    const misshapen = "event: response.in_progress\ndata: {\"type\":\"response.in_progress\",\"sequence_number\":1}\n\n";
    const given = try withChunk(arena, misshapen);
    const streamed = try fixtures.stream(arena, given.fixture.request, given.exchanges, options);
    try std.testing.expectEqual(FailureKind.invalid_response, streamed.response.@"error".?.octoii.kind);
}

test "ChatGPT fails as auth before anything is sent where the host is not signed in, or its tokens may not use the plan" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const fixture = try fixtures.load(arena, "chatgpt", "text");
    var none = options;
    none.credential = null;
    const unsigned = try fixtures.stream(arena, fixture.request, &.{}, none);
    try std.testing.expectEqual(FailureKind.auth, unsigned.response.@"error".?.octoii.kind);
    try std.testing.expectEqual(@as(usize, 0), unsigned.replay.sent.items.len);
    var unplanned = options;
    unplanned.credential = signedIn(3_600_000, &.{ "openid", "email" });
    const refused = try fixtures.stream(arena, fixture.request, &.{}, unplanned);
    try std.testing.expectEqual(FailureKind.auth, refused.response.@"error".?.octoii.kind);
    try std.testing.expect(std.mem.indexOf(u8, refused.response.@"error".?.message, sign_in.plan_scope) != null);
    try std.testing.expectEqual(@as(usize, 0), refused.replay.sent.items.len);
}

test "every recorded stream of ChatGPT's is sent as recorded, with no caching marks, identifiers nor system messages" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    for (try fixtures.textNames(arena, "chatgpt")) |name| {
        errdefer std.debug.print("chatgpt/{s}\n", .{name});
        const streamed = try fixtures.streamFixture(arena, name, options);
        const body = try fixtures.sentBody(arena, streamed.replay, 0);
        for ([_][]const u8{ "octoii", "prompt_cache_breakpoint", "prompt_cache_options", "metadata", "safety_identifier", "user" }) |key| try std.testing.expect(!fixtures.holds(body, key));
        try std.testing.expect(std.mem.indexOf(u8, streamed.replay.sent.items[0].body.?, "\"role\":\"system\"") == null);
        try std.testing.expectEqual(true, body.object.get("stream").?.bool);
        try std.testing.expectEqual(false, body.object.get("store").?.bool);
    }
}

test "ChatGPT's request: its input as items, custom tools and namespaces as OpenAI takes them" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const luna = try fixtures.catalogueModel(arena, "chatgpt", "gpt-6-luna");
    const plain = try std.json.parseFromSliceLeaky(std.json.Value, arena, try chatgpt.wireRequest(arena, &luna, try fixtures.decoded(arena, "{\"model\":\"chatgpt/gpt-6-luna\",\"input\":\"Hi\"}")), .{});
    try fixtures.expectJson(arena, "[{\"type\":\"message\",\"role\":\"user\",\"content\":\"Hi\"}]", try foundation.json.encode(arena, plain.object.get("input").?));
    const tools =
        \\[{"type":"custom","name":"apply_patch","format":{"type":"text"}},{"type":"namespace","name":"files","description":"Files","tools":[{"type":"function","name":"read"}]}]
    ;
    const declared = try std.json.parseFromSliceLeaky(std.json.Value, arena, try chatgpt.wireRequest(arena, &luna, try fixtures.decoded(arena, "{\"model\":\"chatgpt/gpt-6-luna\",\"input\":\"Hi\",\"tools\":" ++ tools ++ "}")), .{});
    try fixtures.expectJson(arena, tools, try foundation.json.encode(arena, declared.object.get("tools").?));
}

test "ChatGPT is sent what the plan does not offer as OpenAI would be, and the plan's own refusal comes back" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var unlisted = options;
    unlisted.models = &.{.{ .id = "gpt-6-luna-unlisted" }};
    const asked = [_]struct { []const u8, []const u8 }{
        .{ "\"max_output_tokens\":100", "max_output_tokens" },
        .{ "\"temperature\":0.2", "temperature" },
        .{ "\"top_p\":0.9", "top_p" },
        .{ "\"top_logprobs\":2", "top_logprobs" },
        .{ "\"truncation\":\"disabled\"", "truncation" },
        .{ "\"max_tool_calls\":3", "max_tool_calls" },
        .{ "\"service_tier\":\"priority\"", "service_tier" },
        .{ "\"tools\":[{\"type\":\"openrouter:tool_search\"},{\"type\":\"function\",\"name\":\"f\",\"parameters\":null}]", "tools" },
    };
    for (asked) |case| {
        const refusal = try arena.print("{{\"error\":{{\"type\":\"invalid_request_error\",\"code\":\"subscription_sharing_unsupported_capability\",\"message\":\"Not available.\",\"param\":\"{s}\"}}}}", .{case[1]});
        const answered = try fixtures.answeredWith(arena, try fixtures.decoded(arena, try fixtures.requestWith(arena, "chatgpt/gpt-6-luna-unlisted", case[0])), .{ .arena = arena, .chunks = try arena.dupe([]const u8, &.{refusal}), .status = 400, .content_type = "application/json" }, unlisted);
        const failure = answered.response.@"error".?;
        try std.testing.expectEqual(FailureKind.invalid_request, failure.octoii.kind);
        try std.testing.expectEqualStrings("subscription_sharing_unsupported_capability", failure.code);
        try std.testing.expectEqual(@as(usize, 1), answered.sent.len);
        const body = try std.json.parseFromSliceLeaky(std.json.Value, arena, answered.sent[0].body.?, .{});
        try std.testing.expect(body.object.get(case[1]) != null);
    }
}

test "ChatGPT's failures are classified by the plan's codes, else as OpenAI's" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const limited = try fixtures.failureOf(arena, "usage-limit", options);
    try std.testing.expectEqual(FailureKind.quota, limited.octoii.kind);
    try std.testing.expectEqual(@as(?u16, 429), limited.octoii.status);
    try std.testing.expectEqualStrings("subscription_sharing_usage_limit_exceeded", limited.code);
    const in_stream = try fixtures.streamFixture(arena, "usage-limit-in-stream", options);
    try std.testing.expectEqual(FailureKind.quota, in_stream.response.@"error".?.octoii.kind);
    try std.testing.expectEqualStrings("subscription_sharing_usage_limit_exceeded", in_stream.response.@"error".?.code);
    try std.testing.expectEqual(vocabulary.items.ItemStatus.incomplete, in_stream.response.output[0].output_message.status.?);
    try std.testing.expectEqualStrings("Sure, here", (try fixtures.messageText(arena, in_stream.response.output)).?);
    const unavailable = try fixtures.failureOf(arena, "usage-unavailable", options);
    try std.testing.expectEqual(FailureKind.server, unavailable.octoii.kind);
    try std.testing.expect(unavailable.octoii.retryable);
    try std.testing.expectEqual(@as(?u16, 503), unavailable.octoii.status);
    const ineligible = try fixtures.failureOf(arena, "not-eligible", options);
    try std.testing.expectEqual(FailureKind.forbidden, ineligible.octoii.kind);
    try std.testing.expectEqualStrings("subscription_sharing_user_not_eligible", ineligible.code);
    const unsupported = try fixtures.failureOf(arena, "unsupported-capability", options);
    try std.testing.expectEqual(FailureKind.invalid_request, unsupported.octoii.kind);
    try std.testing.expect(std.mem.indexOf(u8, unsupported.message, "(include)") != null);
    const admission = try fixtures.failureOf(arena, "admission-unavailable", options);
    try std.testing.expectEqual(FailureKind.server, admission.octoii.kind);
    try std.testing.expectEqualStrings("Service temporarily unavailable.", admission.message);
    const forbidden = try fixtures.failureOf(arena, "admission-forbidden", options);
    try std.testing.expectEqual(FailureKind.forbidden, forbidden.octoii.kind);
    try std.testing.expectEqual(@as(?u16, 403), forbidden.octoii.status);
}

test "ChatGPT refreshes tokens about to expire before sending, keeping the rotated refresh token and the scopes" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const fixture = try fixtures.load(arena, "chatgpt", "text");
    var replay: foundation.replay.Replay = .init(arena, fixture.exchanges);
    var issuer: Issuer = .{ .arena = arena, .now_ms = now_ms, .answer = .{ .tokens = .{ .id_token = null, .rotated = true } }, .rest = replay.http() };
    const made = try modelsWith(arena, signedIn(signed_in.refresh_margin_ms / 2, &sign_in.scopes), &issuer);
    try std.testing.expectEqual(vocabulary.response.ResponseStatus.completed, (try made.models.create(arena, fixture.request)).status);
    try std.testing.expectEqual(@as(usize, 1), issuer.forms.items.len);
    try expectForm(arena, &.{ .{ "grant_type", "refresh_token" }, .{ "refresh_token", "refresh-1" }, .{ "client_id", client }, .{ "resource", "https://api.openai.com/v1" } }, issuer.forms.items[0]);
    try std.testing.expectEqualStrings("Bearer access-new", issuer.authorizations.items[0].?);
    const tokens = made.host.saved.?.credential.oauth.tokens.?;
    try std.testing.expectEqualStrings("access-new", tokens.access);
    try std.testing.expectEqualStrings("refresh-1-rotated", tokens.refresh.?);
    try std.testing.expectEqual(now_ms + 3_600_000, tokens.expires_at_ms);
    try fixtures.expectJson(arena, try foundation.json.encode(arena, sign_in.scopes), try foundation.json.encode(arena, tokens.scopes));
}

test "ChatGPT refreshes once when the plan refuses the token, and sends the request once more" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const fixture = try fixtures.load(arena, "chatgpt", "text");
    var refused = fixture.exchanges[0];
    refused.response = .{ .status = 401, .headers = refused.response.headers, .chunks = try arena.dupe(foundation.replay.Chunk, &.{.{ .text = "{\"detail\":\"Unauthorized\"}" }}) };
    var replay: foundation.replay.Replay = .init(arena, try std.mem.concat(arena, foundation.replay.Exchange, &.{ &.{refused}, fixture.exchanges }));
    var issuer: Issuer = .{ .arena = arena, .now_ms = now_ms, .answer = .{ .tokens = .{ .bare = true } }, .rest = replay.http() };
    const made = try modelsWith(arena, signedIn(3_600_000, &sign_in.scopes), &issuer);
    try std.testing.expectEqual(vocabulary.response.ResponseStatus.completed, (try made.models.create(arena, fixture.request)).status);
    try std.testing.expectEqual(@as(usize, 1), issuer.forms.items.len);
    try std.testing.expectEqual(@as(usize, 2), issuer.authorizations.items.len);
    try std.testing.expectEqualStrings("Bearer access-1", issuer.authorizations.items[0].?);
    try std.testing.expectEqualStrings("Bearer access-new", issuer.authorizations.items[1].?);
    try std.testing.expectEqualStrings("refresh-1", made.host.saved.?.credential.oauth.tokens.?.refresh.?);
}

test "ChatGPT's refresh fails as auth where the refresh token is spent, and by its status otherwise" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const fixture = try fixtures.load(arena, "chatgpt", "text");
    var spent: Issuer = .{ .arena = arena, .now_ms = now_ms, .answer = .{ .refusal = .{ .status = 400, .body = "{\"error\":\"invalid_grant\",\"error_description\":\"Refresh token reused\"}" } } };
    const failed = (try (try modelsWith(arena, signedIn(0, &sign_in.scopes), &spent)).models.create(arena, fixture.request)).@"error".?;
    try std.testing.expectEqual(FailureKind.auth, failed.octoii.kind);
    try std.testing.expectEqualStrings("invalid_grant", failed.code);
    try std.testing.expect(std.mem.indexOf(u8, failed.message, "sign in again") != null);
    try std.testing.expectEqual(@as(usize, 0), spent.authorizations.items.len);
    var down: Issuer = .{ .arena = arena, .now_ms = now_ms, .answer = .{ .refusal = .{ .status = 503, .body = "{\"error\":\"temporarily_unavailable\"}" } } };
    const unavailable = (try (try modelsWith(arena, signedIn(0, &sign_in.scopes), &down)).models.create(arena, fixture.request)).@"error".?;
    try std.testing.expectEqual(FailureKind.server, unavailable.octoii.kind);
    try std.testing.expect(unavailable.octoii.retryable);
}

/// A sign-in begun at `issuer` over a host keeping `credential`, the issuer told the attempt's nonce.
fn begun(arena: Allocator, issuer: *Issuer, credential: ?seam.Credential, redirect: []const u8) !struct { models: *Models, host: *TestHost, sign_in: seam.SignIn, query: []const oauth.Field } {
    const made = try modelsWith(arena, credential, issuer);
    const started = try made.models.signIn(arena, "chatgpt", .{ .redirect_uri = redirect, .agent_name_hint = "Octoii" });
    if (started == .failed) {
        std.debug.print("{s}\n", .{started.failed.message});
        return error.TestUnexpectedFailure;
    }
    const query = try oauth.fields(arena, oauth.queryOf(started.started.url).?);
    issuer.nonce = oauth.valueOf(query, "nonce").?;
    return .{ .models = made.models, .host = made.host, .sign_in = started.started, .query = query };
}

fn callback(arena: Allocator, given: []const oauth.Field) ![]const u8 {
    return arena.print("{s}?{s}", .{ redirect_uri, try oauth.formEncoded(arena, given) });
}

test "a first sign-in with ChatGPT registers the app, checks the ID token and keeps the issued client" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var issuer: Issuer = .{ .arena = arena, .now_ms = now_ms };
    const attempt = try begun(arena, &issuer, null, redirect_uri);
    try std.testing.expect(std.mem.startsWith(u8, attempt.sign_in.url, "https://auth.openai.com/api/accounts/authorize?"));
    const asked = attempt.query;
    for ([_]oauth.Field{
        .{ "response_type", "code" },
        .{ "client_id", "dynamic_agent_client" },
        .{ "redirect_uri", redirect_uri },
        .{ "scope", try std.mem.join(arena, " ", &sign_in.scopes) },
        .{ "resource", "https://api.openai.com/v1" },
        .{ "code_challenge_method", "S256" },
        .{ "agent_name_hint", "Octoii" },
    }) |field| try std.testing.expectEqualStrings(field[1], oauth.valueOf(asked, field[0]).?);
    const host = oauth.valueOf(asked, "ext_agent_host_id").?;
    try std.testing.expect(std.mem.startsWith(u8, host, "urn:uuid:") and host.len == "urn:uuid:".len + 36);
    for ([_][]const u8{ "state", "nonce", "code_challenge" }) |secret| try std.testing.expect(oauth.valueOf(asked, secret).?.len > 20);
    const failed = try attempt.models.finishSignIn(arena, "chatgpt", attempt.sign_in, try callback(arena, &.{ .{ "code", "code-1" }, .{ "state", oauth.valueOf(asked, "state").? }, .{ "client_id", client } }));
    if (failed) |failure| std.debug.print("{s}\n", .{failure.message});
    try std.testing.expectEqual(null, failed);
    const form = issuer.forms.items[0];
    try std.testing.expectEqualStrings("authorization_code", oauth.valueOf(form, "grant_type").?);
    try std.testing.expectEqualStrings("code-1", oauth.valueOf(form, "code").?);
    try std.testing.expect(oauth.valueOf(form, "code_verifier").?.len >= 43);
    try std.testing.expectEqualStrings(client, oauth.valueOf(form, "client_id").?);
    try fixtures.expectJson(arena, try foundation.json.encode(arena, seam.Credential{ .oauth = .{
        .issuer = sign_in.issuer,
        .client_id = client,
        .host_id = host,
        .subject = "user-4Kq2",
        .email = "person@example.com",
        .tokens = .{ .access = "access-new", .refresh = "refresh-new", .expires_at_ms = now_ms + 3_600_000, .scopes = &sign_in.scopes },
    } }), try foundation.json.encode(arena, attempt.host.saved.?.credential));
}

test "a sign-in with ChatGPT keeps its own copy of the redirect address, for the exchange after its caller is done" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var issuer: Issuer = .{ .arena = arena, .now_ms = now_ms };
    const given = try arena.dupe(u8, redirect_uri);
    const attempt = try begun(arena, &issuer, signedIn(3_600_000, &sign_in.scopes), given);
    @memset(given, ' ');
    const address = try callback(arena, &.{ .{ "code", "code-1" }, .{ "state", oauth.valueOf(attempt.query, "state").? } });
    try std.testing.expectEqual(null, try attempt.models.finishSignIn(arena, "chatgpt", attempt.sign_in, address));
    try std.testing.expectEqualStrings(redirect_uri, oauth.valueOf(issuer.forms.items[0], "redirect_uri").?);
}

test "signing in with ChatGPT again reuses the issued client and the host's id, offering no name" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var issuer: Issuer = .{ .arena = arena, .now_ms = now_ms };
    const attempt = try begun(arena, &issuer, signedIn(3_600_000, &sign_in.scopes), "http://127.0.0.1:61022/auth/callback");
    try std.testing.expectEqualStrings(client, oauth.valueOf(attempt.query, "client_id").?);
    try std.testing.expectEqualStrings(host_id, oauth.valueOf(attempt.query, "ext_agent_host_id").?);
    try std.testing.expectEqual(null, oauth.valueOf(attempt.query, "agent_name_hint"));
    const redirect = try arena.print("http://127.0.0.1:61022/auth/callback?code=code-2&state={s}", .{oauth.valueOf(attempt.query, "state").?});
    try std.testing.expectEqual(null, try attempt.models.finishSignIn(arena, "chatgpt", attempt.sign_in, redirect));
    const kept = attempt.host.saved.?.credential.oauth;
    try std.testing.expectEqualStrings(client, kept.client_id);
    try std.testing.expectEqualStrings(host_id, kept.host_id.?);
    try std.testing.expectEqualStrings("access-new", kept.tokens.?.access);
}

/// The failure a sign-in ends with, the issuer answering as `answer` and the callback holding the code, the attempt's
/// state unless `state` is given, and `client_id` unless null; the credential kept checked to be `kept`.
fn failedSignIn(arena: Allocator, earlier: ?seam.Credential, answer: issuer_.Answer, state: ?[]const u8, client_id: ?[]const u8) ![]const u8 {
    const issuer = try arena.create(Issuer);
    issuer.* = .{ .arena = arena, .now_ms = now_ms, .answer = answer };
    const attempt = try begun(arena, issuer, earlier, redirect_uri);
    var given: std.ArrayList(oauth.Field) = .empty;
    try given.appendSlice(arena, &.{ .{ "code", "code-1" }, .{ "state", state orelse oauth.valueOf(attempt.query, "state").? } });
    if (client_id) |named| try given.append(arena, .{ "client_id", named });
    const failure = (try attempt.models.finishSignIn(arena, "chatgpt", attempt.sign_in, try callback(arena, given.items))) orelse return error.TestExpectedFailure;
    try std.testing.expectEqual(FailureKind.auth, failure.kind);
    const kept = if (attempt.host.saved) |saved| try foundation.json.encode(arena, saved.credential) else "null";
    try std.testing.expectEqualStrings(if (earlier) |credential| try foundation.json.encode(arena, credential) else "null", kept);
    return failure.message;
}

fn expectContains(text: []const u8, words: []const u8) !void {
    if (std.mem.indexOf(u8, text, words) != null) return;
    std.debug.print("{s}: {s}\n", .{ words, text });
    return error.TestUnexpectedMessage;
}

test "a first sign-in whose code is refused keeps the client it registered, unconnected, and the next goes on as it" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var issuer: Issuer = .{ .arena = arena, .now_ms = now_ms, .answer = .{ .refusal = .{ .status = 400, .body = "{\"error\":\"invalid_grant\"}" } } };
    const first = try begun(arena, &issuer, null, redirect_uri);
    const address = try callback(arena, &.{ .{ "code", "code-1" }, .{ "state", oauth.valueOf(first.query, "state").? }, .{ "client_id", client } });
    try expectContains((try first.models.finishSignIn(arena, "chatgpt", first.sign_in, address)).?.message, "no longer valid");
    const kept = first.host.saved.?.credential;
    try std.testing.expectEqualStrings(client, kept.oauth.client_id);
    try std.testing.expectEqualStrings(oauth.valueOf(first.query, "ext_agent_host_id").?, kept.oauth.host_id.?);
    try std.testing.expect(kept.oauth.tokens == null and !kept.usable());
    const next = try begun(arena, &issuer, kept, redirect_uri);
    try std.testing.expectEqualStrings(client, oauth.valueOf(next.query, "client_id").?);
    try std.testing.expectEqualStrings(oauth.valueOf(first.query, "ext_agent_host_id").?, oauth.valueOf(next.query, "ext_agent_host_id").?);
    try std.testing.expect(oauth.valueOf(next.query, "agent_name_hint") == null);
}

test "a sign-in with ChatGPT that cannot finish fails as auth, saying why, and keeps nothing" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var issuer: Issuer = .{ .arena = arena, .now_ms = now_ms };
    const declined = try begun(arena, &issuer, null, redirect_uri);
    try expectContains((try declined.models.finishSignIn(arena, "chatgpt", declined.sign_in, redirect_uri ++ "?error=access_denied&state=x")).?.message, "declined");
    try expectContains(try failedSignIn(arena, null, .{ .tokens = .{} }, "another", client), "not of this sign-in attempt");
    try expectContains(try failedSignIn(arena, null, .{ .tokens = .{} }, null, null), "registration gave no client");
    try expectContains(try failedSignIn(arena, signedIn(3_600_000, &sign_in.scopes), .{ .refusal = .{ .status = 400, .body = "{\"error\":\"invalid_grant\"}" } }, null, null), "no longer valid");
    try expectContains(try failedSignIn(arena, signedIn(3_600_000, &sign_in.scopes), .{ .refusal = .{ .status = 400, .body = "{\"error\":\"invalid_grant\",\"error_description\":\"the verifier does not match\"}" } }, null, null), "the issuer said invalid_grant: the verifier does not match");
    try expectContains(try failedSignIn(arena, signedIn(3_600_000, &sign_in.scopes), .{ .refusal = .{ .status = 400, .body = "{\"error\":{\"code\":\"token_expired\",\"message\":\"the code expired\"}}" } }, null, null), "the issuer said token_expired: the code expired");
    try expectContains(try failedSignIn(arena, null, .{ .tokens = .{ .id_token = .{ .other_key = true } } }, null, client), "signature");
    try expectContains(try failedSignIn(arena, null, .{ .tokens = .{ .id_token = .{ .nonce = "another nonce" } } }, null, client), "nonce");
    try expectContains(try failedSignIn(arena, null, .{ .tokens = .{ .id_token = .{ .audience = "oaiapp_other" } } }, null, client), "not issued for the client");
    try expectContains(try failedSignIn(arena, null, .{ .tokens = .{ .id_token = .{ .issued_by = "https://issuer.example" } } }, null, client), "issued by");
    try expectContains(try failedSignIn(arena, null, .{ .tokens = .{ .id_token = .{ .expires_in_s = -1 } } }, null, client), "expired");
    try expectContains(try failedSignIn(arena, null, .{ .tokens = .{ .id_token = null } }, null, client), "no ID token");
    const earlier = signedIn(3_600_000, &sign_in.scopes);
    try expectContains(try failedSignIn(arena, earlier, .{ .tokens = .{} }, null, "oaiapp_other"), "returned the client oaiapp_other");
    try expectContains(try failedSignIn(arena, earlier, .{ .tokens = .{ .id_token = .{ .subject = "user-other" } } }, null, null), "another ChatGPT account");
}

test "a sign-in with ChatGPT refuses a redirect address the issuer does not take, before anything is asked" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var issuer: Issuer = .{ .arena = arena, .now_ms = now_ms };
    const made = try modelsWith(arena, null, &issuer);
    for ([_][]const u8{ "http://localhost:1455/auth/callback", "https://127.0.0.1:1455/auth/callback", "http://127.0.0.1:1455/callback" }) |redirect| {
        const started = try made.models.signIn(arena, "chatgpt", .{ .redirect_uri = redirect, .agent_name_hint = "Octoii" });
        try std.testing.expectEqual(FailureKind.invalid_request, started.failed.kind);
    }
    try std.testing.expectEqual(@as(usize, 0), issuer.forms.items.len);
}
