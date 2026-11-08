//! Signing in to an MCP server: discovery from a challenge or the well-known addresses, the client chosen and
//! registered, the authorization request and its callback, and the tokens exchanged, refreshed and revoked.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const foundation = @import("foundation");
const http = foundation.http;
const oauth = @import("oauth.zig");
const failure_ = @import("failure.zig");
const Slot = failure_.Slot;

const mcp_url = "https://mcp.example/mcp";
const issuer = "https://auth.example";
const redirect = "http://127.0.0.1:4100/callback";

/// The metadata documents a test publishes, by address; every other address answers 404.
const Documents = struct {
    arena: Allocator,
    documents: []const struct { []const u8, []const u8 },
    asked: std.ArrayList([]const u8) = .empty,

    fn network(documents: *Documents) http.Http {
        return .{ .context = documents, .vtable = &.{ .send = send } };
    }

    fn send(context: *anyopaque, request: http.Request) http.SendError!http.Response {
        const documents: *Documents = @ptrCast(@alignCast(context));
        try documents.asked.append(documents.arena, try documents.arena.dupe(u8, request.url));
        const body = for (documents.documents) |document| {
            if (std.mem.eql(u8, document[0], request.url)) break document[1];
        } else null;
        const chunks = try documents.arena.dupe([]const u8, &.{body orelse "Not found"});
        const reader = try documents.arena.create(foundation.replay.ChunkReader);
        reader.* = .init(chunks, try documents.arena.alloc(u8, 4096));
        return .{ .status = if (body == null) 404 else 200, .headers = &.{}, .body = &reader.reader, .context = reader, .vtable = &.{ .failure = failure, .close = close } };
    }

    fn failure(_: *anyopaque) http.Error {
        return error.Transport;
    }

    fn close(_: *anyopaque) void {}
};

const resource_document = "{\"resource\":\"https://mcp.example/mcp\",\"authorization_servers\":[\"https://auth.example\"],\"scopes_supported\":[\"tools\",\"read\"]}";

fn serverDocument(arena: Allocator, extra: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"issuer\":\"https://auth.example\",\"authorization_endpoint\":\"https://auth.example/authorize\",\"token_endpoint\":\"https://auth.example/token\",\"code_challenge_methods_supported\":[\"S256\"]{s}}}", .{extra});
}

fn metadata(arena: Allocator, extra: []const u8) !oauth.AuthorizationServerMetadata {
    var slot: Slot = .{ .arena = arena };
    return oauth.parseAuthorizationServerMetadata(&slot, try std.json.parseFromSliceLeaky(Value, arena, try serverDocument(arena, extra), .{}), issuer);
}

test "a Bearer challenge is read, its quoted values unescaped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const challenge = try oauth.parseWwwAuthenticate(a, "Basic realm=\"x\", Bearer resource_metadata=\"https://mcp.example/.well-known/oauth-protected-resource/mcp\", scope=\"tools read\", error=insufficient_scope, error_description=\"needs \\\"read\\\"\"");
    try std.testing.expectEqualStrings("https://mcp.example/.well-known/oauth-protected-resource/mcp", challenge.resource_metadata.?);
    try std.testing.expectEqualStrings("tools read", challenge.scope.?);
    try std.testing.expectEqualStrings("insufficient_scope", challenge.@"error".?);
    try std.testing.expectEqualStrings("needs \"read\"", challenge.error_description.?);
    try std.testing.expectEqual(null, (try oauth.parseWwwAuthenticate(a, "Basic realm=\"x\"")).scope);
}

test "metadata is looked for where the challenge names, else at the path's then the root's well-known address, and an issuer's in the specification's order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const found = try oauth.protectedResourceMetadataUrls(a, mcp_url, .{});
    try std.testing.expectEqualStrings("https://mcp.example/.well-known/oauth-protected-resource/mcp", found[0]);
    try std.testing.expectEqualStrings("https://mcp.example/.well-known/oauth-protected-resource", found[1]);
    try std.testing.expectEqualStrings("https://x/y", (try oauth.protectedResourceMetadataUrls(a, mcp_url, .{ .resource_metadata = "https://x/y" }))[0]);
    const tenant = try oauth.authorizationServerMetadataUrls(a, "https://auth.example/tenant");
    try std.testing.expectEqualStrings("https://auth.example/.well-known/oauth-authorization-server/tenant", tenant[0]);
    try std.testing.expectEqualStrings("https://auth.example/.well-known/openid-configuration/tenant", tenant[1]);
    try std.testing.expectEqualStrings("https://auth.example/tenant/.well-known/openid-configuration", tenant[2]);
    try std.testing.expectEqual(@as(usize, 2), (try oauth.authorizationServerMetadataUrls(a, issuer)).len);
}

test "discovery follows the well-known addresses to an OpenID Connect document, and refuses another issuer or no PKCE" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var documents: Documents = .{ .arena = a, .documents = &.{
        .{ "https://mcp.example/.well-known/oauth-protected-resource", resource_document },
        .{ "https://auth.example/.well-known/openid-configuration", try serverDocument(a, ",\"registration_endpoint\":\"https://auth.example/register\"") },
    } };
    var slot: Slot = .{ .arena = a };
    const found = try oauth.discover(documents.network(), &slot, mcp_url, .{});
    try std.testing.expectEqualStrings("https://auth.example/register", found.server.registration_endpoint.?);
    try std.testing.expectEqual(@as(usize, 4), documents.asked.items.len);
    const other = try std.json.parseFromSliceLeaky(Value, a, "{\"issuer\":\"https://evil.example\"}", .{});
    try std.testing.expectError(error.Failed, oauth.parseAuthorizationServerMetadata(&slot, other, issuer));
    try std.testing.expectEqual(.issuer, slot.failure.?.oauth.kind);
    const plain = try std.json.parseFromSliceLeaky(Value, a, "{\"issuer\":\"https://auth.example\",\"authorization_endpoint\":\"a\",\"token_endpoint\":\"t\",\"code_challenge_methods_supported\":[\"plain\"]}", .{});
    try std.testing.expectError(error.Failed, oauth.parseAuthorizationServerMetadata(&slot, plain, issuer));
    try std.testing.expectEqual(.pkce, slot.failure.?.oauth.kind);
    const elsewhere = try std.json.parseFromSliceLeaky(Value, a, "{\"resource\":\"https://other.example/mcp\",\"authorization_servers\":[\"https://auth.example\"]}", .{});
    try std.testing.expectError(error.Failed, oauth.parseProtectedResourceMetadata(&slot, elsewhere, mcp_url));
}

test "the challenge's scopes are asked for, else the resource's, and scopes are joined for step-up" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const resource: oauth.ProtectedResourceMetadata = .{ .resource = mcp_url, .authorization_servers = &.{issuer}, .scopes_supported = &.{ "tools", "read" } };
    try std.testing.expectEqualStrings("write", (try oauth.selectScope(a, .{ .scope = "write" }, resource)).?);
    try std.testing.expectEqualStrings("tools read", (try oauth.selectScope(a, .{}, resource)).?);
    try std.testing.expectEqual(null, try oauth.selectScope(a, .{}, null));
    try std.testing.expectEqualStrings("tools read write", (try oauth.stepUpScope(a, "tools read", "read write")).?);
}

test "the client is chosen in order: pre-registered, a metadata document the server takes, then dynamic registration" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var slot: Slot = .{ .arena = a };
    const both = try metadata(a, ",\"registration_endpoint\":\"https://auth.example/register\",\"client_id_metadata_document_supported\":true");
    try std.testing.expectEqual(.pre_registered, try oauth.chooseRegistration(&slot, both, true, null));
    try std.testing.expectEqual(.metadata_document, try oauth.chooseRegistration(&slot, both, false, "https://app.example/client.json"));
    try std.testing.expectEqual(.dynamic, try oauth.chooseRegistration(&slot, both, false, "https://app.example/"));
    try std.testing.expectError(error.Failed, oauth.chooseRegistration(&slot, try metadata(a, ""), false, null));
    try std.testing.expectEqual(.client, slot.failure.?.oauth.kind);
}

test "a client registers dynamically with the application type of its redirect URIs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var slot: Slot = .{ .arena = a };
    const server = try metadata(a, ",\"registration_endpoint\":\"https://auth.example/register\"");
    const request = try oauth.registrationRequest(&slot, server, .{ .client_name = "Octoii", .redirect_uris = &.{redirect} });
    try std.testing.expectEqualStrings("https://auth.example/register", request.url);
    try std.testing.expect(std.mem.indexOf(u8, request.body.?, "\"application_type\":\"native\"") != null);
    try std.testing.expectEqual(.web, oauth.applicationType(a, &.{"https://app.example/callback"}));
    const client = try oauth.parseRegistrationResponse(&slot, 201, "{\"client_id\":\"c1\",\"client_secret\":\"s1\"}");
    try std.testing.expectEqualStrings("c1", client.client_id);
    try std.testing.expectError(error.Failed, oauth.parseRegistrationResponse(&slot, 400, "{\"error\":\"invalid_redirect_uri\"}"));
    try std.testing.expectEqualStrings("The client registration was refused (400: invalid_redirect_uri)", slot.failure.?.oauth.message);
}

test "a sign-in's link carries PKCE, state and the resource, the endpoint's own query kept, and its state is 32 bytes in hex" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const state = try oauth.randomState(a, &@as([32]u8, @splat(0xab)));
    try std.testing.expectEqual(@as(usize, 64), state.len);
    var server = try metadata(a, "");
    server.authorization_endpoint = "https://auth.example/authorize?tenant=t1";
    const link = try oauth.authorizationUrl(a, server, .{ .client_id = "c1", .redirect_uri = redirect, .state = "s", .code_challenge = "ch", .resource = mcp_url, .scope = "tools read" });
    try std.testing.expectEqualStrings("https://auth.example/authorize?tenant=t1&response_type=code&client_id=c1&redirect_uri=http%3A%2F%2F127.0.0.1%3A4100%2Fcallback&code_challenge=ch&code_challenge_method=S256&state=s&resource=https%3A%2F%2Fmcp.example%2Fmcp&scope=tools+read", link);
    try std.testing.expectEqualStrings("https://mcp.example", try oauth.canonicalResource(a, "https://mcp.example/"));
    try std.testing.expectEqualStrings("https://mcp.example/mcp?x=1", try oauth.canonicalResource(a, "https://mcp.example/mcp?x=1#part"));
}

test "a callback for another sign-in, or from another issuer, is refused without acting on its error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var slot: Slot = .{ .arena = a };
    const expected: oauth.CallbackExpectation = .{ .state = "s", .issuer = issuer, .iss_parameter_supported = true };
    try std.testing.expectEqualStrings("code1", try oauth.checkCallback(&slot, &.{ .{ "state", "s" }, .{ "iss", issuer }, .{ "code", "code1" } }, expected));
    try std.testing.expectError(error.Failed, oauth.checkCallback(&slot, &.{ .{ "state", "other" }, .{ "error", "access_denied" } }, expected));
    try std.testing.expectEqual(.state, slot.failure.?.oauth.kind);
    try std.testing.expectError(error.Failed, oauth.checkCallback(&slot, &.{ .{ "state", "s" }, .{ "code", "c" } }, expected));
    try std.testing.expectEqual(.callback_issuer, slot.failure.?.oauth.kind);
    try std.testing.expectError(error.Failed, oauth.checkCallback(&slot, &.{ .{ "state", "s" }, .{ "iss", issuer }, .{ "error", "access_denied" }, .{ "error_description", "No" } }, expected));
    try std.testing.expectEqualStrings("access_denied: No", slot.failure.?.oauth.message);
}

test "tokens are exchanged as a public client or with Basic, refreshed keeping a refresh token not rotated, and revoked refresh token first" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var slot: Slot = .{ .arena = a };
    var server = try metadata(a, "");
    const public = try oauth.tokenRequest(a, server, .{ .client_id = "c1" }, .{ .code = "code1", .code_verifier = "v", .redirect_uri = redirect, .resource = mcp_url });
    try std.testing.expectEqualStrings("grant_type=authorization_code&code=code1&code_verifier=v&redirect_uri=http%3A%2F%2F127.0.0.1%3A4100%2Fcallback&resource=https%3A%2F%2Fmcp.example%2Fmcp&client_id=c1", public.body.?);
    const confidential = try oauth.tokenRequest(a, server, .{ .client_id = "c1", .client_secret = "s1" }, .{ .code = "code1", .code_verifier = "v", .redirect_uri = redirect, .resource = mcp_url });
    try std.testing.expectEqualStrings("Basic YzE6czE=", http.find(confidential.headers, "authorization").?);
    const tokens = try oauth.parseTokenResponse(&slot, 200, "{\"access_token\":\"a1\",\"token_type\":\"Bearer\",\"refresh_token\":\"r1\",\"expires_in\":3600}", 1000, null);
    try std.testing.expectEqual(@as(?i64, 3_601_000), tokens.expires_at);
    const refreshed = try oauth.parseTokenResponse(&slot, 200, "{\"access_token\":\"a2\",\"token_type\":\"Bearer\"}", 2000, tokens);
    try std.testing.expectEqualStrings("r1", refreshed.refresh_token.?);
    try std.testing.expectError(error.Failed, oauth.parseTokenResponse(&slot, 400, "{\"error\":\"invalid_grant\"}", 0, null));
    try std.testing.expectEqualStrings("The token endpoint answered 400: invalid_grant", slot.failure.?.oauth.message);
    try std.testing.expectEqual(@as(usize, 0), (try oauth.revocationRequests(a, server, .{ .client_id = "c1" }, tokens)).len);
    server.revocation_endpoint = "https://auth.example/revoke";
    const revoked = try oauth.revocationRequests(a, server, .{ .client_id = "c1" }, tokens);
    try std.testing.expectEqualStrings("token=r1&token_type_hint=refresh_token&client_id=c1", revoked[0].body.?);
    try std.testing.expectEqualStrings("token=a1&token_type_hint=access_token&client_id=c1", revoked[1].body.?);
}
