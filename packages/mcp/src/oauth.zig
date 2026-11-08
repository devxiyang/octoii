//! OAuth for MCP servers over HTTP, after the current MCP authorization specification (revision 2026-07-28), computed
//! without sending but for discovery: the functions build requests and read answers, and the caller sends them through
//! its HTTP and keeps the client, the tokens and the sign-in that waits where it chooses. Discovery reads a 401's
//! challenge (RFC 6750, RFC 9728), the protected resource metadata it names or the well-known addresses, and the
//! authorization server's metadata (RFC 8414) with its issuer checked; the client is known pre-registered, by a Client
//! ID Metadata Document, or registered now (RFC 7591); the authorization request carries PKCE, `state` and the
//! `resource` (RFC 8707), and its callback's `iss` is checked (RFC 9207); tokens are exchanged, refreshed and revoked
//! (RFC 6749, RFC 7009).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const foundation = @import("foundation");
const http = foundation.http;
const Header = http.Header;
const Field = foundation.oauth.Field;
const protocol = @import("protocol.zig");
const failure_ = @import("failure.zig");
const Slot = failure_.Slot;
const Error = failure_.Error;

/// What a `WWW-Authenticate: Bearer` challenge says.
pub const BearerChallenge = struct {
    resource_metadata: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    error_description: ?[]const u8 = null,
};

pub const ProtectedResourceMetadata = struct {
    resource: []const u8,
    authorization_servers: []const []const u8,
    scopes_supported: ?[]const []const u8 = null,
};

pub const AuthorizationServerMetadata = struct {
    issuer: []const u8,
    authorization_endpoint: []const u8,
    token_endpoint: []const u8,
    code_challenge_methods_supported: []const []const u8,
    registration_endpoint: ?[]const u8 = null,
    revocation_endpoint: ?[]const u8 = null,
    scopes_supported: ?[]const []const u8 = null,
    token_endpoint_auth_methods_supported: ?[]const []const u8 = null,
    client_id_metadata_document_supported: ?bool = null,
    authorization_response_iss_parameter_supported: ?bool = null,
};

/// A client as an authorization server knows it: its id, and its secret and how it authenticates, if confidential.
pub const Client = struct {
    client_id: []const u8,
    client_secret: ?[]const u8 = null,
    token_endpoint_auth_method: ?[]const u8 = null,
    redirect_uris: ?[]const []const u8 = null,
};

/// What a client says of itself, in a registration or its Client ID Metadata Document.
pub const ClientMetadata = struct {
    client_name: []const u8,
    redirect_uris: []const []const u8,
    grant_types: ?[]const []const u8 = null,
    response_types: ?[]const []const u8 = null,
    token_endpoint_auth_method: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    application_type: ?ApplicationType = null,
};

pub const ApplicationType = enum { native, web };

/// Tokens, and `expires_at`, in milliseconds since the epoch, from `expires_in`.
pub const Tokens = struct {
    access_token: []const u8,
    token_type: []const u8,
    refresh_token: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    expires_in: ?f64 = null,
    expires_at: ?i64 = null,
};

/// The challenge of a `WWW-Authenticate` header's Bearer scheme; an empty one where there is none.
pub fn parseWwwAuthenticate(arena: Allocator, header: ?[]const u8) Allocator.Error!BearerChallenge {
    const given = header orelse return .{};
    const start = bearerAt(given) orelse return .{};
    var challenge: BearerChallenge = .{};
    var at = start + "bearer".len;
    while (at < given.len) {
        while (at < given.len and (given[at] == ' ' or given[at] == ',' or given[at] == '\t')) at += 1;
        const name_start = at;
        while (at < given.len and (std.ascii.isAlphanumeric(given[at]) or given[at] == '_' or given[at] == '-')) at += 1;
        const name = given[name_start..at];
        while (at < given.len and given[at] == ' ') at += 1;
        if (name.len == 0 or at >= given.len or given[at] != '=') break;
        at += 1;
        while (at < given.len and given[at] == ' ') at += 1;
        const value = try paramValue(arena, given, &at);
        if (std.ascii.eqlIgnoreCase(name, "resource_metadata")) challenge.resource_metadata = value;
        if (std.ascii.eqlIgnoreCase(name, "scope")) challenge.scope = value;
        if (std.ascii.eqlIgnoreCase(name, "error")) challenge.@"error" = value;
        if (std.ascii.eqlIgnoreCase(name, "error_description")) challenge.error_description = value;
    }
    return challenge;
}

/// Where the scheme `Bearer` begins, at the start or after a space or comma.
fn bearerAt(header: []const u8) ?usize {
    var from: usize = 0;
    while (from + "bearer".len <= header.len) : (from += 1) {
        if (!std.ascii.eqlIgnoreCase(header[from..][0.."bearer".len], "bearer")) continue;
        const before = from == 0 or header[from - 1] == ' ' or header[from - 1] == ',';
        const after = from + "bearer".len == header.len or header[from + "bearer".len] == ' ';
        if (before and after) return from;
    }
    return null;
}

/// A parameter's value at `at`: quoted, its escapes undone, or a token up to a space or a comma.
fn paramValue(arena: Allocator, header: []const u8, at: *usize) Allocator.Error![]const u8 {
    if (at.* < header.len and header[at.*] == '"') {
        var value: std.ArrayList(u8) = .empty;
        at.* += 1;
        while (at.* < header.len and header[at.*] != '"') : (at.* += 1) {
            if (header[at.*] == '\\' and at.* + 1 < header.len) at.* += 1;
            try value.append(arena, header[at.*]);
        }
        at.* += 1;
        return value.items;
    }
    const start = at.*;
    while (at.* < header.len and header[at.*] != ' ' and header[at.*] != ',') at.* += 1;
    return header[start..at.*];
}

/// A URL's parts as the protocol compares them.
const Parts = struct { scheme: []const u8, origin: []const u8, path: []const u8, query: ?[]const u8 };

fn partsOf(arena: Allocator, url: []const u8) ?Parts {
    const uri = std.Uri.parse(url) catch return null;
    const host = componentText(uri.host orelse return null);
    const origin = if (uri.port) |port| std.fmt.allocPrint(arena, "{s}://{s}:{d}", .{ uri.scheme, host, port }) catch return null else std.fmt.allocPrint(arena, "{s}://{s}", .{ uri.scheme, host }) catch return null;
    return .{ .scheme = uri.scheme, .origin = origin, .path = componentText(uri.path), .query = if (uri.query) |query| componentText(query) else null };
}

fn componentText(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw, .percent_encoded => |text| text,
    };
}

fn trimmedPath(path: []const u8) []const u8 {
    return std.mem.trimEnd(u8, path, "/");
}

/// Where the server's protected resource metadata is: what its challenge names, else the path's and the root's
/// well-known addresses.
pub fn protectedResourceMetadataUrls(arena: Allocator, server_url: []const u8, challenge: BearerChallenge) Allocator.Error![]const []const u8 {
    if (challenge.resource_metadata) |named| return arena.dupe([]const u8, &.{named});
    const parts = partsOf(arena, server_url) orelse return &.{};
    const root = try std.fmt.allocPrint(arena, "{s}/.well-known/oauth-protected-resource", .{parts.origin});
    const path = trimmedPath(parts.path);
    if (path.len == 0) return arena.dupe([]const u8, &.{root});
    return arena.dupe([]const u8, &.{ try std.fmt.allocPrint(arena, "{s}{s}", .{ root, path }), root });
}

/// Where an issuer's metadata may be, in the specification's order: for an issuer with a path, the OAuth address with
/// the path inserted, then OpenID Connect's inserted, then appended; for one without, OAuth's then OpenID Connect's.
pub fn authorizationServerMetadataUrls(arena: Allocator, issuer: []const u8) Allocator.Error![]const []const u8 {
    const parts = partsOf(arena, issuer) orelse return &.{};
    const path = trimmedPath(parts.path);
    if (path.len == 0) return arena.dupe([]const u8, &.{
        try std.fmt.allocPrint(arena, "{s}/.well-known/oauth-authorization-server", .{parts.origin}),
        try std.fmt.allocPrint(arena, "{s}/.well-known/openid-configuration", .{parts.origin}),
    });
    return arena.dupe([]const u8, &.{
        try std.fmt.allocPrint(arena, "{s}/.well-known/oauth-authorization-server{s}", .{ parts.origin, path }),
        try std.fmt.allocPrint(arena, "{s}/.well-known/openid-configuration{s}", .{ parts.origin, path }),
        try std.fmt.allocPrint(arena, "{s}{s}/.well-known/openid-configuration", .{ parts.origin, path }),
    });
}

/// Protected resource metadata, which must name the server it was fetched for, or a path above it, and an
/// authorization server.
pub fn parseProtectedResourceMetadata(slot: *Slot, value: Value, server_url: []const u8) Error!ProtectedResourceMetadata {
    if (value != .object) return slot.refused(.metadata, "The protected resource metadata is not an object", .{});
    const resource = textOf(value.object.get("resource")) orelse return slot.refused(.metadata, "The protected resource metadata names no resource", .{});
    const covering = partsOf(slot.arena, resource) orelse return slot.refused(.metadata, "The protected resource metadata names no resource", .{});
    const server = partsOf(slot.arena, server_url) orelse return slot.refused(.metadata, "{s} is no address", .{server_url});
    const path = trimmedPath(covering.path);
    const covers = std.mem.eql(u8, covering.origin, server.origin) and (path.len == 0 or std.mem.eql(u8, server.path, path) or (std.mem.startsWith(u8, server.path, path) and server.path.len > path.len and server.path[path.len] == '/'));
    if (!covers) return slot.refused(.metadata, "The protected resource metadata is for {s}, not {s}", .{ resource, server_url });
    const servers = try strings(slot.arena, value.object.get("authorization_servers"));
    if (servers == null or servers.?.len == 0) return slot.refused(.metadata, "The protected resource metadata names no authorization server", .{});
    return .{ .resource = resource, .authorization_servers = servers.?, .scopes_supported = try strings(slot.arena, value.object.get("scopes_supported")) };
}

/// An authorization server's metadata: its `issuer` exactly the one it was fetched for (RFC 8414 §3.3), and PKCE with
/// S256 offered, else the client does not go on.
pub fn parseAuthorizationServerMetadata(slot: *Slot, value: Value, issuer: []const u8) Error!AuthorizationServerMetadata {
    if (value != .object) return slot.refused(.metadata, "The authorization server metadata is not an object", .{});
    const named = textOf(value.object.get("issuer")) orelse "";
    if (!std.mem.eql(u8, named, issuer)) return slot.refused(.issuer, "The authorization server metadata of {s} names the issuer {s}", .{ issuer, named });
    const authorization = textOf(value.object.get("authorization_endpoint")) orelse return slot.refused(.metadata, "The authorization server {s} names no authorization or token endpoint", .{issuer});
    const token = textOf(value.object.get("token_endpoint")) orelse return slot.refused(.metadata, "The authorization server {s} names no authorization or token endpoint", .{issuer});
    const methods = try strings(slot.arena, value.object.get("code_challenge_methods_supported")) orelse &.{};
    for (methods) |method| {
        if (std.mem.eql(u8, method, "S256")) break;
    } else return slot.refused(.pkce, "The authorization server {s} does not offer PKCE with S256", .{issuer});
    return .{
        .issuer = issuer,
        .authorization_endpoint = authorization,
        .token_endpoint = token,
        .code_challenge_methods_supported = methods,
        .registration_endpoint = textOf(value.object.get("registration_endpoint")),
        .revocation_endpoint = textOf(value.object.get("revocation_endpoint")),
        .scopes_supported = try strings(slot.arena, value.object.get("scopes_supported")),
        .token_endpoint_auth_methods_supported = try strings(slot.arena, value.object.get("token_endpoint_auth_methods_supported")),
        .client_id_metadata_document_supported = flag(value.object.get("client_id_metadata_document_supported")),
        .authorization_response_iss_parameter_supported = flag(value.object.get("authorization_response_iss_parameter_supported")),
    };
}

/// How to sign in to a server: its protected resource metadata and its authorization server's.
pub const Discovered = struct { resource: ProtectedResourceMetadata, server: AuthorizationServerMetadata };

/// Discovers how to sign in to the server at `server_url`, through `network`: its protected resource metadata, from
/// its challenge's address or the well-known ones in turn, and the metadata of the first authorization server it
/// names.
pub fn discover(network: http.Http, slot: *Slot, server_url: []const u8, challenge: BearerChallenge) Error!Discovered {
    const resource_document = try firstDocument(network, slot, try protectedResourceMetadataUrls(slot.arena, server_url, challenge)) orelse {
        return slot.refused(.metadata, "{s} publishes no protected resource metadata", .{server_url});
    };
    const resource = try parseProtectedResourceMetadata(slot, resource_document, server_url);
    const issuer = resource.authorization_servers[0];
    const server_document = try firstDocument(network, slot, try authorizationServerMetadataUrls(slot.arena, issuer)) orelse {
        return slot.refused(.metadata, "The authorization server {s} publishes no metadata", .{issuer});
    };
    return .{ .resource = resource, .server = try parseAuthorizationServerMetadata(slot, server_document, issuer) };
}

/// The first of `urls` that answers with a JSON object.
fn firstDocument(network: http.Http, slot: *Slot, urls: []const []const u8) Error!?Value {
    for (urls) |url| {
        const response = network.send(.{ .url = url, .headers = &.{.{ .name = "accept", .value = "application/json" }} }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer response.close();
        if (response.status < 200 or response.status >= 300) continue;
        const body = response.body.allocRemaining(slot.arena, .limited(1 << 20)) catch continue;
        const document = std.json.parseFromSliceLeaky(Value, slot.arena, body, .{ .allocate = .alloc_always }) catch continue;
        if (document == .object) return document;
    }
    return null;
}

/// The scopes to ask for: the challenge's, else every scope the resource supports, else none.
pub fn selectScope(arena: Allocator, challenge: BearerChallenge, resource: ?ProtectedResourceMetadata) Allocator.Error!?[]const u8 {
    if (challenge.scope) |scope| return scope;
    const supported = (resource orelse return null).scopes_supported orelse return null;
    if (supported.len == 0) return null;
    return try std.mem.join(arena, " ", supported);
}

/// The scopes granted before joined with those a challenge for more asks for, as step-up authorization does.
pub fn stepUpScope(arena: Allocator, granted: ?[]const u8, challenged: ?[]const u8) Allocator.Error!?[]const u8 {
    var scopes: std.ArrayList([]const u8) = .empty;
    for ([_]?[]const u8{ granted, challenged }) |given| {
        var it = std.mem.tokenizeScalar(u8, given orelse continue, ' ');
        while (it.next()) |scope| {
            for (scopes.items) |kept| {
                if (std.mem.eql(u8, kept, scope)) break;
            } else try scopes.append(arena, scope);
        }
    }
    if (scopes.items.len == 0) return null;
    return try std.mem.join(arena, " ", scopes.items);
}

/// How the client is known: given by the person, by its metadata document's address, or registered now.
pub const RegistrationKind = enum { pre_registered, metadata_document, dynamic };

/// Which way to identify the client: a pre-registered client where there is one; a Client ID Metadata Document where
/// the server takes them and the client has one at an https address with a path; dynamic registration where the
/// server offers it.
pub fn chooseRegistration(slot: *Slot, server: AuthorizationServerMetadata, pre_registered: bool, metadata_document: ?[]const u8) Error!RegistrationKind {
    if (pre_registered) return .pre_registered;
    if (server.client_id_metadata_document_supported == true) if (metadata_document) |url| if (partsOf(slot.arena, url)) |parts| {
        if (std.mem.eql(u8, parts.scheme, "https") and trimmedPath(parts.path).len > 0) return .metadata_document;
    };
    if (server.registration_endpoint != null) return .dynamic;
    return slot.refused(.client, "The authorization server {s} takes no metadata document of this client and offers no registration", .{server.issuer});
}

/// `native` for redirect URIs on a loopback address or a private scheme, as a desktop or command-line client has;
/// `web` otherwise.
pub fn applicationType(arena: Allocator, redirect_uris: []const []const u8) ApplicationType {
    for (redirect_uris) |uri| {
        const parsed = std.Uri.parse(uri) catch continue;
        if (!std.mem.eql(u8, parsed.scheme, "https") and !std.mem.eql(u8, parsed.scheme, "http")) return .native;
        const host = componentText(parsed.host orelse continue);
        for ([_][]const u8{ "127.0.0.1", "localhost", "[::1]", "::1" }) |loopback| if (std.mem.eql(u8, host, loopback)) return .native;
    }
    _ = arena;
    return .web;
}

/// The dynamic registration request, its `application_type` that of the redirect URIs unless given.
pub fn registrationRequest(slot: *Slot, server: AuthorizationServerMetadata, metadata: ClientMetadata) Error!http.Request {
    const endpoint = server.registration_endpoint orelse return slot.refused(.client, "The authorization server {s} offers no registration", .{server.issuer});
    var body = metadata;
    body.application_type = metadata.application_type orelse applicationType(slot.arena, metadata.redirect_uris);
    return .{
        .method = .POST,
        .url = endpoint,
        .headers = try slot.arena.dupe(Header, &.{ .{ .name = "content-type", .value = "application/json" }, .{ .name = "accept", .value = "application/json" } }),
        .body = try foundation.json.encode(slot.arena, body),
    };
}

/// The client a registration's answer gives; a refusal says why.
pub fn parseRegistrationResponse(slot: *Slot, status: u16, body: []const u8) Error!Client {
    const value = std.json.parseFromSliceLeaky(Value, slot.arena, body, .{ .allocate = .alloc_always }) catch Value{ .null = {} };
    const id = if (value == .object) textOf(value.object.get("client_id")) else null;
    if (status < 200 or status >= 300 or id == null) {
        return slot.refused(.registration, "The client registration was refused ({d}{s}{s})", .{ status, if (reasonOf(value) != null) ": " else "", reasonOf(value) orelse "" });
    }
    return .{
        .client_id = id.?,
        .client_secret = textOf(value.object.get("client_secret")),
        .token_endpoint_auth_method = textOf(value.object.get("token_endpoint_auth_method")),
        .redirect_uris = try strings(slot.arena, value.object.get("redirect_uris")),
    };
}

/// A random `state`, its bytes in hex.
pub fn randomState(arena: Allocator, random: *const [protocol.oauth_state_bytes]u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{x}", .{random});
}

/// The server's canonical URI, its `resource` indicator: without fragment, and without the slash of an empty path.
pub fn canonicalResource(arena: Allocator, server_url: []const u8) Allocator.Error![]const u8 {
    const parts = partsOf(arena, server_url) orelse return server_url;
    const path = if (std.mem.eql(u8, parts.path, "/")) "" else parts.path;
    if (parts.query) |query| return std.fmt.allocPrint(arena, "{s}{s}?{s}", .{ parts.origin, path, query });
    return std.fmt.allocPrint(arena, "{s}{s}", .{ parts.origin, path });
}

/// What an authorization request carries.
pub const Authorization = struct {
    client_id: []const u8,
    redirect_uri: []const u8,
    state: []const u8,
    code_challenge: []const u8,
    resource: []const u8,
    scope: ?[]const u8 = null,
};

/// The authorization link the person's browser opens: the endpoint's own query kept, the request's fields after it.
pub fn authorizationUrl(arena: Allocator, server: AuthorizationServerMetadata, request: Authorization) Allocator.Error![]const u8 {
    var fields: std.ArrayList(Field) = .empty;
    try fields.appendSlice(arena, &.{
        .{ "response_type", "code" },              .{ "client_id", request.client_id },
        .{ "redirect_uri", request.redirect_uri }, .{ "code_challenge", request.code_challenge },
        .{ "code_challenge_method", "S256" },      .{ "state", request.state },
        .{ "resource", request.resource },
    });
    if (request.scope) |scope| try fields.append(arena, .{ "scope", scope });
    const endpoint = server.authorization_endpoint;
    const fragment_at = std.mem.indexOfScalar(u8, endpoint, '#') orelse endpoint.len;
    const base = endpoint[0..fragment_at];
    const separator: []const u8 = if (std.mem.indexOfScalar(u8, base, '?') == null) "?" else if (base[base.len - 1] == '?' or base[base.len - 1] == '&') "" else "&";
    return std.fmt.allocPrint(arena, "{s}{s}{s}{s}", .{ base, separator, try foundation.oauth.formEncoded(arena, fields.items), endpoint[fragment_at..] });
}

/// What a sign-in waits for its callback to carry.
pub const CallbackExpectation = struct {
    state: []const u8,
    /// The issuer of the checked metadata the sign-in went to.
    issuer: []const u8,
    /// Whether that metadata says the server sends `iss` in its answers.
    iss_parameter_supported: bool,
};

/// The code a callback carries, once its `state` names the sign-in and its `iss` fits the issuer: compared as it is,
/// and required where the server says it sends one. A callback that fails either is refused without its `error` acted
/// on or shown; a fitting one with an `error` ends the sign-in with it.
pub fn checkCallback(slot: *Slot, query: []const Field, expected: CallbackExpectation) Error![]const u8 {
    const value = foundation.oauth.valueOf;
    const state = value(query, "state") orelse "";
    if (!std.mem.eql(u8, state, expected.state)) return slot.refused(.state, "The callback names no sign-in that waits", .{});
    const fits = if (value(query, "iss")) |iss| std.mem.eql(u8, iss, expected.issuer) else !expected.iss_parameter_supported;
    if (!fits) return slot.refused(.callback_issuer, "The callback did not come from the authorization server the sign-in went to", .{});
    if (value(query, "error")) |given| {
        if (value(query, "error_description")) |description| return slot.refused(.denied, "{s}: {s}", .{ given, description });
        return slot.refused(.denied, "{s}", .{given});
    }
    const code = value(query, "code") orelse "";
    if (code.len == 0) return slot.refused(.callback, "The callback carries no code", .{});
    return code;
}

/// What a code is exchanged for tokens with.
pub const Exchange = struct { code: []const u8, code_verifier: []const u8, redirect_uri: []const u8, resource: []const u8 };

/// Exchanges a callback's code for tokens, with the PKCE verifier, the redirect URI and the `resource` the
/// authorization request had.
pub fn tokenRequest(arena: Allocator, server: AuthorizationServerMetadata, client: Client, exchange: Exchange) Allocator.Error!http.Request {
    return formRequest(arena, server.token_endpoint, server, client, &.{
        .{ "grant_type", "authorization_code" },      .{ "code", exchange.code },
        .{ "code_verifier", exchange.code_verifier }, .{ "redirect_uri", exchange.redirect_uri },
        .{ "resource", exchange.resource },
    });
}

/// Refreshes the tokens, for the same `resource`.
pub fn refreshRequest(arena: Allocator, server: AuthorizationServerMetadata, client: Client, refresh_token: []const u8, resource: []const u8, scope: ?[]const u8) Allocator.Error!http.Request {
    var fields: std.ArrayList(Field) = .empty;
    try fields.appendSlice(arena, &.{ .{ "grant_type", "refresh_token" }, .{ "refresh_token", refresh_token }, .{ "resource", resource } });
    if (scope) |given| try fields.append(arena, .{ "scope", given });
    return formRequest(arena, server.token_endpoint, server, client, fields.items);
}

/// The tokens of a token endpoint's answer at `now_ms`; a refusal says why. A refresh that brings no new refresh token
/// keeps `previous`'s.
pub fn parseTokenResponse(slot: *Slot, status: u16, body: []const u8, now_ms: i64, previous: ?Tokens) Error!Tokens {
    const value = std.json.parseFromSliceLeaky(Value, slot.arena, body, .{ .allocate = .alloc_always }) catch Value{ .null = {} };
    const access = if (value == .object) textOf(value.object.get("access_token")) else null;
    const kind = if (value == .object) textOf(value.object.get("token_type")) else null;
    if (status < 200 or status >= 300 or access == null or kind == null) {
        return slot.refused(.token, "The token endpoint answered {d}{s}{s}", .{ status, if (reasonOf(value) != null) ": " else "", reasonOf(value) orelse "" });
    }
    const expires_in: ?f64 = if (value.object.get("expires_in")) |given| switch (given) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => null,
    } else null;
    return .{
        .access_token = access.?,
        .token_type = kind.?,
        .refresh_token = textOf(value.object.get("refresh_token")) orelse if (previous) |kept| kept.refresh_token else null,
        .scope = textOf(value.object.get("scope")),
        .expires_in = expires_in,
        .expires_at = if (expires_in) |seconds| now_ms + @as(i64, @intFromFloat(seconds * 1000)) else null,
    };
}

/// The requests that revoke the tokens at the server's revocation endpoint (RFC 7009): the refresh token, then the
/// access token, each as the client it was issued to; none where the server names no endpoint.
pub fn revocationRequests(arena: Allocator, server: AuthorizationServerMetadata, client: Client, tokens: Tokens) Allocator.Error![]const http.Request {
    const endpoint = server.revocation_endpoint orelse return &.{};
    var made: std.ArrayList(http.Request) = .empty;
    if (tokens.refresh_token) |refresh| try made.append(arena, try formRequest(arena, endpoint, server, client, &.{ .{ "token", refresh }, .{ "token_type_hint", "refresh_token" } }));
    try made.append(arena, try formRequest(arena, endpoint, server, client, &.{ .{ "token", tokens.access_token }, .{ "token_type_hint", "access_token" } }));
    return made.items;
}

/// Whether a revocation succeeded; a server answers 200 for a token it revoked and for one it does not know.
pub fn checkRevocationResponse(slot: *Slot, status: u16) Error!void {
    if (status < 200 or status >= 300) return slot.refused(.token, "The revocation endpoint answered {d}", .{status});
}

/// A form POST to one of the server's endpoints, the client authenticating as it registered: with a secret in Basic
/// authentication or in the form, or as a public client by its id alone.
fn formRequest(arena: Allocator, endpoint: []const u8, server: AuthorizationServerMetadata, client: Client, given: []const Field) Allocator.Error!http.Request {
    var fields: std.ArrayList(Field) = .empty;
    try fields.appendSlice(arena, given);
    var headers: std.ArrayList(Header) = .empty;
    try headers.appendSlice(arena, &.{ .{ .name = "content-type", .value = "application/x-www-form-urlencoded" }, .{ .name = "accept", .value = "application/json" } });
    const method = authenticationMethod(server, client);
    if (std.mem.eql(u8, method, "client_secret_basic") and client.client_secret != null) {
        const pair = try std.fmt.allocPrint(arena, "{s}:{s}", .{ try encodedComponent(arena, client.client_id), try encodedComponent(arena, client.client_secret.?) });
        try headers.append(arena, .{ .name = "authorization", .value = try std.fmt.allocPrint(arena, "Basic {b64}", .{pair}) });
    } else {
        try fields.append(arena, .{ "client_id", client.client_id });
        if (std.mem.eql(u8, method, "client_secret_post") and client.client_secret != null) try fields.append(arena, .{ "client_secret", client.client_secret.? });
    }
    return .{ .method = .POST, .url = endpoint, .headers = headers.items, .body = try foundation.oauth.formEncoded(arena, fields.items) };
}

/// How the client authenticates: as it registered; with a secret, Basic unless the server takes only the form;
/// without, by its id.
fn authenticationMethod(server: AuthorizationServerMetadata, client: Client) []const u8 {
    if (client.token_endpoint_auth_method) |method| return method;
    if (client.client_secret == null) return "none";
    const supported = server.token_endpoint_auth_methods_supported orelse return "client_secret_basic";
    var post = false;
    var basic = false;
    for (supported) |method| {
        if (std.mem.eql(u8, method, "client_secret_post")) post = true;
        if (std.mem.eql(u8, method, "client_secret_basic")) basic = true;
    }
    return if (post and !basic) "client_secret_post" else "client_secret_basic";
}

/// `value` as `encodeURIComponent` writes it, as a Basic credential's parts are written.
fn encodedComponent(arena: Allocator, value: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (value) |char| switch (char) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '!', '~', '*', '\'', '(', ')' => try out.append(arena, char),
        else => try out.print(arena, "%{X:0>2}", .{char}),
    };
    return out.items;
}

fn textOf(value: ?Value) ?[]const u8 {
    const given = value orelse return null;
    return if (given == .string) given.string else null;
}

fn flag(value: ?Value) ?bool {
    const given = value orelse return null;
    return if (given == .bool) given.bool else null;
}

/// The strings of a list, its other members dropped; null where it is no list.
fn strings(arena: Allocator, value: ?Value) Allocator.Error!?[]const []const u8 {
    const given = value orelse return null;
    if (given != .array) return null;
    var kept: std.ArrayList([]const u8) = .empty;
    for (given.array.items) |item| if (item == .string) try kept.append(arena, item.string);
    return kept.items;
}

/// Why an authorization server refused, as its answer says.
fn reasonOf(value: Value) ?[]const u8 {
    if (value != .object) return null;
    return textOf(value.object.get("error_description")) orelse textOf(value.object.get("error"));
}
