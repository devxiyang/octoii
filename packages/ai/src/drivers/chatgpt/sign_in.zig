//! Sign in with ChatGPT: OAuth with PKCE at OpenAI's issuer, for the Responses API on the person's plan. The first
//! sign-in registers the app for the person through the placeholder client, and later ones reuse the client it was
//! issued; each host sends its own stable id. The ID token is checked against the issuer's published keys before the
//! credential is stored, and a refresh replaces the tokens and their scopes together.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const oauth = foundation.oauth;
const seam = @import("../../driver.zig");
const Call = seam.Call;
const failure_ = @import("../../failure.zig");
const Failure = failure_.Failure;
const Error = failure_.Error;
const http = @import("../../wire/http.zig");
const signed_in = @import("../../wire/signed_in.zig");

/// Who issues the tokens of a sign-in with ChatGPT, as its ID tokens name it.
pub const issuer = "https://auth.openai.com";

/// The scope that lets the tokens use the person's plan, without which a request fails as `auth`.
pub const plan_scope = "chatgpt.tokens.use.direct";

/// Where the person signs in.
pub const authorize_url = issuer ++ "/api/accounts/authorize";

/// Where a code or a refresh token is exchanged for tokens.
pub const token_url = issuer ++ "/api/accounts/oauth/token";

/// Where the issuer publishes the keys it signs ID tokens with.
pub const keys_url = issuer ++ "/.well-known/jwks.json";

/// The API the tokens are for, which the issuer names as their resource.
pub const resource = "https://api.openai.com/v1";

/// The placeholder client a first sign-in registers the app through; never the client a credential keeps.
pub const registration_client = "dynamic_agent_client";

/// What a sign-in asks for: who the person is, a refresh token, and the use of the plan.
pub const scopes = [_][]const u8{ "openid", "profile", "email", "offline_access", "resource.invoke", plan_scope };

/// The errors of a refresh by which the issuer says its code or refresh token is no longer good.
const spent_errors = [_][]const u8{ "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused" };

/// What the issuer's token endpoint answers with.
const TokenAnswer = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    id_token: ?[]const u8 = null,
    /// In seconds.
    expires_in: f64,
    /// The scopes granted, separated by spaces; left out, those asked for.
    scope: ?[]const u8 = null,
};

/// What one sign-in attempt keeps until it finishes: its secrets, and the client and host it signs in as.
const Attempt = struct {
    state: []const u8,
    nonce: []const u8,
    pkce: oauth.Pkce,
    host_id: []const u8,
    /// The client issued at an earlier sign-in, reused; null for a first sign-in, which registers one.
    client_id: ?[]const u8,
    /// Who signed in before, whom signing in again must be.
    subject: ?[]const u8,
    redirect_uri: []const u8,
};

/// Begins a sign-in with ChatGPT: the address where the person signs in, and how it finishes; `invalid_request` for a
/// redirect address the issuer does not take.
pub fn begin(call: *Call, options: seam.SignInOptions) Error!seam.SignIn {
    if (!loopbackCallback(options.redirect_uri)) {
        return call.failWith(.invalid_request, "The redirect address {s} is not one the issuer takes: it is http://127.0.0.1:<port>/auth/callback", .{options.redirect_uri});
    }
    const earlier = earlierSignIn(try call.credential());
    var secret: [32]u8 = undefined;
    call.host.randomBytes(&secret);
    const attempt = try call.arena.create(Attempt);
    attempt.* = .{
        .state = try randomText(call),
        .nonce = try randomText(call),
        .pkce = try .of(call.arena, &secret),
        .host_id = (if (earlier) |given| given.host_id else null) orelse try std.fmt.allocPrint(call.arena, "urn:uuid:{s}", .{try call.host.newId(call.arena)}),
        .client_id = if (earlier) |given| given.client_id else null,
        .subject = if (earlier) |given| given.subject else null,
        .redirect_uri = options.redirect_uri,
    };
    return .{ .url = try authorizeUrl(call.arena, attempt, options.agent_name_hint), .attempt = attempt, .finish = finish };
}

/// Whether `uri` is `http://127.0.0.1:<port>/auth/callback`, the redirect address the issuer takes.
fn loopbackCallback(uri: []const u8) bool {
    const prefix = "http://127.0.0.1:";
    const suffix = "/auth/callback";
    if (!std.mem.startsWith(u8, uri, prefix) or !std.mem.endsWith(u8, uri, suffix)) return false;
    const port = uri[prefix.len .. uri.len - suffix.len];
    if (port.len == 0 or port.len > 5) return false;
    for (port) |char| if (!std.ascii.isDigit(char)) return false;
    return true;
}

fn randomText(call: *Call) Allocator.Error![]const u8 {
    var bytes: [16]u8 = undefined;
    call.host.randomBytes(&bytes);
    return oauth.base64Url(call.arena, &bytes);
}

/// The sign-in with ChatGPT the host's store keeps from before, whose client and host a new one reuses.
fn earlierSignIn(credential: ?seam.Credential) ?seam.OAuth {
    const given = credential orelse return null;
    if (given != .oauth or !std.mem.eql(u8, given.oauth.issuer, issuer)) return null;
    return given.oauth;
}

/// Where the person signs in for `attempt`: the app offered under `agent_name_hint` on a first sign-in, which
/// registers it.
fn authorizeUrl(arena: Allocator, attempt: *const Attempt, agent_name_hint: []const u8) Allocator.Error![]const u8 {
    var query: std.ArrayList(oauth.Field) = .empty;
    try query.appendSlice(arena, &.{
        .{ "response_type", "code" },
        .{ "client_id", attempt.client_id orelse registration_client },
        .{ "redirect_uri", attempt.redirect_uri },
        .{ "scope", try std.mem.join(arena, " ", &scopes) },
        .{ "resource", resource },
        .{ "state", attempt.state },
        .{ "nonce", attempt.nonce },
        .{ "code_challenge", attempt.pkce.challenge },
        .{ "code_challenge_method", "S256" },
    });
    if (attempt.client_id == null) try query.append(arena, .{ "agent_name_hint", agent_name_hint });
    try query.append(arena, .{ "ext_agent_host_id", attempt.host_id });
    return std.fmt.allocPrint(arena, "{s}?{s}", .{ authorize_url, try oauth.formEncoded(arena, query.items) });
}

/// Finishes the attempt from the address the person's browser was sent back to: its code exchanged for tokens, the ID
/// token checked, and the credential stored; `auth`, saying why, where it cannot.
fn finish(call: *Call, context: *anyopaque, redirect: []const u8) Error!void {
    const attempt: *const Attempt = @ptrCast(@alignCast(context));
    const query = oauth.queryOf(std.mem.trim(u8, redirect, " \t\r\n")) orelse
        return call.failWith(.auth, "What was given is not the address the browser was sent back to", .{});
    const given = try oauth.fields(call.arena, query);
    if (oauth.valueOf(given, "error")) |refused| {
        if (std.mem.eql(u8, refused, "access_denied")) return call.failWith(.auth, "The person declined to sign in with ChatGPT", .{});
        return call.failWith(.auth, "The sign-in with ChatGPT failed: {s}", .{oauth.valueOf(given, "error_description") orelse refused});
    }
    const state = oauth.valueOf(given, "state") orelse "";
    if (!std.mem.eql(u8, state, attempt.state)) return call.failWith(.auth, "The address is not of this sign-in attempt: its state differs; sign in again", .{});
    const code = oauth.valueOf(given, "code") orelse "";
    if (code.len == 0) return call.failWith(.auth, "The address holds no code: sign in again", .{});
    const client_id = try issuedClient(call, attempt, oauth.valueOf(given, "client_id"));
    const tokens = try tokensFor(call, &.{
        .{ "grant_type", "authorization_code" },
        .{ "code", code },
        .{ "code_verifier", attempt.pkce.verifier },
        .{ "redirect_uri", attempt.redirect_uri },
        .{ "client_id", client_id },
        .{ "resource", resource },
    }, "The code is no longer valid: sign in again");
    const id_token = tokens.id_token orelse return call.failWith(.auth, "The issuer gave no ID token, by which ai knows who signed in", .{});
    const claims = try verifiedClaims(call, id_token, client_id, attempt.nonce);
    if (attempt.subject) |subject| if (!std.mem.eql(u8, subject, claims.sub)) {
        return call.failWith(.auth, "The person signed in to another ChatGPT account than the one signing in again: sign out of it first", .{});
    };
    const Store = struct {
        credential: seam.Credential,

        fn apply(store_context: *anyopaque, _: Allocator, _: ?seam.Credential) Error!?seam.Credential {
            const store: *@This() = @ptrCast(@alignCast(store_context));
            return store.credential;
        }
    };
    var store: Store = .{ .credential = .{ .oauth = .{
        .issuer = issuer,
        .client_id = client_id,
        .host_id = attempt.host_id,
        .subject = claims.sub,
        .email = claims.email,
        .tokens = try storedTokens(call, tokens, null, &scopes),
    } } };
    _ = call.host.credentials.modify(call.arena, call.provider.id, .{ .context = &store, .apply = Store.apply }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return error.Failed,
        error.Unavailable => return call.failWith(.auth, "The host's credentials cannot keep the sign-in to {s}", .{call.provider.id}),
    };
}

/// The client the sign-in goes on as: the one issued before, where the issuer returned no other, or the one the issuer
/// registered now.
fn issuedClient(call: *Call, attempt: *const Attempt, returned: ?[]const u8) Error![]const u8 {
    if (attempt.client_id) |known| {
        if (returned) |other| if (!std.mem.eql(u8, other, known)) {
            return call.failWith(.auth, "The issuer returned the client {s}, not {s} it issued before: sign in again", .{ other, known });
        };
        return known;
    }
    const issued = returned orelse "";
    if (issued.len == 0 or std.mem.eql(u8, issued, registration_client)) {
        return call.failWith(.auth, "The registration gave no client: the issuer returned none to sign in as; sign in again", .{});
    }
    return issued;
}

/// The refresh of a sign-in with ChatGPT: its refresh token exchanged at the issuer for new tokens, which replace the
/// access token, its expiry, the scopes and the refresh token together; `auth` where the issuer says the refresh token
/// is no longer good, else as its status says.
pub fn refresh(call: *Call, credential: seam.OAuth, refresh_token: []const u8) Error!seam.OAuth {
    const tokens = try tokensFor(call, &.{
        .{ "grant_type", "refresh_token" },
        .{ "refresh_token", refresh_token },
        .{ "client_id", credential.client_id },
        .{ "resource", resource },
    }, "The sign-in to ChatGPT is no longer good: sign in again");
    var renewed = credential;
    const asked: []const []const u8 = if (credential.tokens) |given| given.scopes else &scopes;
    renewed.tokens = try storedTokens(call, tokens, refresh_token, asked);
    return renewed;
}

/// The tokens the issuer's token endpoint gives for `form`; `auth` with `spent` where it says the code or refresh token
/// is no longer good.
fn tokensFor(call: *Call, form: []const oauth.Field, spent: []const u8) Error!TokenAnswer {
    const response = try http.send(call, .{
        .method = .POST,
        .url = token_url,
        .headers = &.{ .{ .name = "content-type", .value = "application/x-www-form-urlencoded" }, .{ .name = "accept", .value = "application/json" } },
        .body = try oauth.formEncoded(call.arena, form),
    });
    if (response.status < 200 or response.status >= 300) return call.fail(try tokenFailure(call, response, spent));
    return readJson(TokenAnswer, call, response, "tokens");
}

/// The failure a refusal of the token endpoint stands for: `auth` with `spent` as its message where the issuer says the
/// code or refresh token is no longer good, else as its status says.
fn tokenFailure(call: *Call, response: foundation.http.Response, spent: []const u8) Error!Failure {
    var failure = try http.failureOf(call, response, null);
    const said = std.json.parseFromSliceLeaky(std.json.Value, call.arena, failure.body orelse "", .{}) catch return failure;
    if (said != .object) return failure;
    const raised = said.object.get("error") orelse return failure;
    const code = switch (raised) {
        .string => |text| text,
        .object => |object| if (object.get("code")) |value| (if (value == .string) value.string else return failure) else return failure,
        else => return failure,
    };
    for (spent_errors) |each| if (std.mem.eql(u8, each, code)) {
        failure.kind = .auth;
        failure.retryable = false;
        failure.message = spent;
        failure.code = code;
        return failure;
    };
    return failure;
}

/// The claims of an ID token that a sign-in checks.
const Claims = struct {
    iss: []const u8,
    aud: std.json.Value,
    /// In seconds since the epoch.
    exp: f64,
    nonce: ?[]const u8 = null,
    sub: []const u8,
    email: ?[]const u8 = null,
};

/// The claims of `id_token` once it holds: signed by one of the issuer's published keys with RS256, issued by the
/// issuer for `client_id`, not expired, and carrying the attempt's `nonce`.
fn verifiedClaims(call: *Call, id_token: []const u8, client_id: []const u8, nonce: []const u8) Error!Claims {
    const arena = call.arena;
    const jwt = try oauth.Jwt.parse(arena, id_token) orelse return idTokenFailure(call, "it is not signed with RS256", .{});
    const header = foundation.json.decode(struct { alg: enum { RS256 }, kid: ?[]const u8 = null }, arena, jwt.header) catch
        return idTokenFailure(call, "it is not signed with RS256", .{});
    const claims = foundation.json.decode(Claims, arena, jwt.claims) catch return idTokenFailure(call, "its claims are not those of an ID token", .{});
    const keys = try publishedKeys(call);
    const key = for (keys) |each| {
        if (!std.mem.eql(u8, each.kty, "RSA")) continue;
        if (header.kid) |kid| if (each.kid == null or !std.mem.eql(u8, each.kid.?, kid)) continue;
        break each;
    } else return idTokenFailure(call, "none of the issuer's published keys signed it", .{});
    const modulus = try oauth.fromBase64Url(arena, key.n orelse "") orelse &.{};
    const exponent = try oauth.fromBase64Url(arena, key.e orelse "") orelse &.{};
    if (modulus.len == 0 or exponent.len == 0) return idTokenFailure(call, "none of the issuer's published keys signed it", .{});
    if (!jwt.signedBy(modulus, exponent)) return idTokenFailure(call, "its signature is not the issuer's", .{});
    if (!std.mem.eql(u8, claims.iss, issuer)) return idTokenFailure(call, "it was issued by {s}", .{claims.iss});
    if (!audienceHolds(claims.aud, client_id)) return idTokenFailure(call, "it was not issued for the client {s}", .{client_id});
    if (claims.exp * 1000 <= @as(f64, @floatFromInt(call.nowMs()))) return idTokenFailure(call, "it has expired", .{});
    if (claims.nonce == null or !std.mem.eql(u8, claims.nonce.?, nonce)) return idTokenFailure(call, "it does not carry this attempt's nonce", .{});
    if (claims.sub.len == 0) return idTokenFailure(call, "it names no account", .{});
    return claims;
}

fn audienceHolds(audience: std.json.Value, client_id: []const u8) bool {
    switch (audience) {
        .string => |one| return std.mem.eql(u8, one, client_id),
        .array => |many| for (many.items) |each| {
            if (each == .string and std.mem.eql(u8, each.string, client_id)) return true;
        },
        else => {},
    }
    return false;
}

/// One of the keys the issuer publishes.
const Key = struct { kty: []const u8, kid: ?[]const u8 = null, n: ?[]const u8 = null, e: ?[]const u8 = null };

fn publishedKeys(call: *Call) Error![]const Key {
    const response = try http.send(call, .{ .url = keys_url, .headers = &.{.{ .name = "accept", .value = "application/json" }} });
    if (response.status < 200 or response.status >= 300) return call.fail(try http.failureOf(call, response, null));
    return (try readJson(struct { keys: []const Key }, call, response, "published keys")).keys;
}

fn idTokenFailure(call: *Call, comptime why: []const u8, arguments: anytype) Error {
    return call.failWith(.auth, "The ID token of the sign-in does not hold: " ++ why, arguments);
}

/// The JSON body of `response`, read as `T`; `invalid_response`, naming `what`, where it is not.
fn readJson(comptime T: type, call: *Call, response: foundation.http.Response, what: []const u8) Error!T {
    defer response.close();
    const body = response.body.allocRemaining(call.arena, .limited(1 << 20)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return call.failWith(.transport, "The issuer's answer broke off", .{}),
    };
    return http.parse(T, call, body, what);
}

/// The tokens as the credential keeps them, now: the access token and its expiry, the rotated refresh token, else
/// `refresh_token`, and the scopes granted, else `asked`.
fn storedTokens(call: *Call, tokens: TokenAnswer, refresh_token: ?[]const u8, asked: []const []const u8) Allocator.Error!signed_in.Tokens {
    var granted: std.ArrayList([]const u8) = .empty;
    if (tokens.scope) |scope| {
        var it = std.mem.tokenizeScalar(u8, scope, ' ');
        while (it.next()) |each| try granted.append(call.arena, each);
    } else try granted.appendSlice(call.arena, asked);
    return .{
        .access = tokens.access_token,
        .refresh = tokens.refresh_token orelse refresh_token,
        .expires_at_ms = call.nowMs() + @as(i64, @intFromFloat(tokens.expires_in * 1000)),
        .scopes = granted.items,
    };
}
