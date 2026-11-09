//! A fake issuer of sign-ins with ChatGPT, for the tests of its sign-in and refresh: its token endpoint, which answers
//! as a test sets it, and its published key, with which it signs the ID tokens it gives. Every other request goes to
//! the HTTP behind it, its authorization kept.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const http = foundation.http;
const oauth = foundation.oauth;
const sign_in = @import("../drivers/chatgpt/sign_in.zig");

/// The issuer's key, made for these tests alone: its modulus and private exponent.
const issuer_key = .{
    "d4983c9943ae93c5c09d2817c858c3f132b687c22b40e900851a4965c45da74669650d1ad02d281d76234f9105a1337270d1c3c71892b1cb16bcaa0c7bc31841f70e15e9d225fcbcffb9600226f993c593e1d308ebd53674a18353d0e64394611de65b9f44405838132da3f69655b23b309235a60ed4a6c4244ff1260da7eeb5",
    "7b1f2bc14b7c58a2a7799cd5a1371f4b9a26321b96b741fa061c023408f48042fc1904ece971ad90da717acc2f697b8524a7a76dafe28d4b6400a1af172216f255cf12dc0b6ec13a2592133dcb058d2033ff0c5da68a2f83fa32cad2f506dbe817c27e8a864d3372c3a865a43200ede58a9f43fc6f94f385c51d5b243f727d65",
};

/// A key that is not the issuer's, to sign a token the issuer did not.
const other_key = .{
    "c4bf4da38e9322592a043178c5c4953e1f23d59ba6ef6bdb899c0b6c7e1798409b0dcf8f0f53fc95c60cc993c448a48418a069877c4656cca1de4fe1f74e37d8d3148b0f5bccff4a6dff17e1b56fd27578cdd9332a3e93cd0a14533ef62fe78b010241a1b1559675853da47cb40d53b2cfd63e0034ae135c793d06c6b8e8f7e7",
    "5369abb7e0f57e45812bbff1ad1f180afb56ccf42dc529dc2cae4ca5959bd93fe2bceb3782cf1fb23c0225e011029f4525cfb48ded6140e186eae2c1318126e975ed5f624757a5120cdd88e31a6fc61ce493633e798c3d93ae2ac144cf5dcfc82fb71ac61523e09bbf3f2f1b0617664f5c66391660c8f6119ca35654ded23349",
};

/// The ID token the issuer gives: for the person signing in, issued for the client the form names, with the attempt's
/// nonce, unless a test says otherwise.
pub const IdToken = struct {
    audience: ?[]const u8 = null,
    nonce: ?[]const u8 = null,
    subject: []const u8 = "user-4Kq2",
    issued_by: []const u8 = sign_in.issuer,
    /// Seconds from now until it expires.
    expires_in_s: i64 = 3600,
    other_key: bool = false,
};

/// How the token endpoint answers.
pub const Answer = union(enum) {
    /// New tokens: an access token, a refresh token unless `rotated` names one after the sent, the scopes asked for,
    /// and an ID token where one is given; `bare` gives the access token and its expiry alone.
    tokens: struct { id_token: ?IdToken = .{}, rotated: bool = false, bare: bool = false },
    refusal: struct { status: u16, body: []const u8 },
};

pub const Issuer = struct {
    arena: Allocator,
    now_ms: i64,
    answer: Answer = .{ .tokens = .{} },
    /// The attempt's nonce, which a test reads from the address where the person signs in.
    nonce: []const u8 = "",
    /// What every other request goes to.
    rest: ?http.Http = null,
    /// The forms the token endpoint was sent, in order.
    forms: std.ArrayList([]const oauth.Field) = .empty,
    /// The authorization of each request that went to `rest`.
    authorizations: std.ArrayList(?[]const u8) = .empty,

    pub fn network(issuer: *Issuer) http.Http {
        return .{ .context = issuer, .vtable = &.{ .send = send } };
    }

    fn send(context: *anyopaque, request: http.Request) http.SendError!http.Response {
        const issuer: *Issuer = @ptrCast(@alignCast(context));
        const arena = issuer.arena;
        if (std.mem.eql(u8, request.url, sign_in.keys_url)) {
            const modulus = foundation.oauth.testing.hexBytes(arena, issuer_key[0]) catch return error.Transport;
            return answered(arena, 200, try arena.print("{{\"keys\":[{{\"kty\":\"RSA\",\"kid\":\"test-key-1\",\"alg\":\"RS256\",\"use\":\"sig\",\"n\":\"{s}\",\"e\":\"AQAB\"}}]}}", .{try oauth.base64Url(arena, modulus)}));
        }
        if (std.mem.eql(u8, request.url, sign_in.token_url)) {
            const form = try oauth.fields(arena, request.body orelse "");
            try issuer.forms.append(arena, form);
            return switch (issuer.answer) {
                .refusal => |refusal| answered(arena, refusal.status, refusal.body),
                .tokens => |tokens| answered(arena, 200, issuer.tokensFor(form, tokens) catch return error.Transport),
            };
        }
        try issuer.authorizations.append(arena, http.find(request.headers, "authorization"));
        const rest = issuer.rest orelse return error.Transport;
        return rest.send(request);
    }

    fn tokensFor(issuer: *Issuer, form: []const oauth.Field, tokens: @FieldType(Answer, "tokens")) ![]const u8 {
        const arena = issuer.arena;
        if (tokens.bare) return "{\"access_token\":\"access-new\",\"expires_in\":3600}";
        const refresh = if (tokens.rotated) try arena.print("{s}-rotated", .{oauth.valueOf(form, "refresh_token") orelse ""}) else "refresh-new";
        const id_token: ?[]const u8 = if (tokens.id_token) |claims| try issuer.signed(claims, oauth.valueOf(form, "client_id") orelse "") else null;
        return foundation.json.encode(arena, .{
            .access_token = "access-new",
            .refresh_token = refresh,
            .token_type = "Bearer",
            .expires_in = 3600,
            .scope = try std.mem.join(arena, " ", &sign_in.scopes),
            .id_token = id_token,
        });
    }

    /// An ID token of `given`, signed by the issuer's key or the other.
    fn signed(issuer: *Issuer, given: IdToken, client_id: []const u8) ![]const u8 {
        const arena = issuer.arena;
        const now_s = @divFloor(issuer.now_ms, 1000);
        const claims = try foundation.json.encode(arena, .{
            .iss = given.issued_by,
            .aud = &[_][]const u8{given.audience orelse client_id},
            .sub = given.subject,
            .email = "person@example.com",
            .nonce = given.nonce orelse issuer.nonce,
            .exp = now_s + given.expires_in_s,
            .iat = now_s,
        });
        const key = if (given.other_key) other_key else issuer_key;
        const testing = foundation.oauth.testing;
        return testing.signedToken(arena, "{\"alg\":\"RS256\",\"kid\":\"test-key-1\",\"typ\":\"JWT\"}", claims, try testing.hexBytes(arena, key[0]), try testing.hexBytes(arena, key[1]));
    }
};

fn answered(arena: Allocator, status: u16, body: []const u8) http.SendError!http.Response {
    const reader = try arena.create(foundation.replay.ChunkReader);
    reader.* = .init(try arena.dupe([]const u8, &.{body}), try arena.alloc(u8, 4096));
    const headers = try arena.dupe(http.Header, &.{.{ .name = "content-type", .value = "application/json" }});
    return .{ .status = status, .headers = headers, .body = &reader.reader, .context = reader, .vtable = &.{ .failure = failure, .close = close } };
}

fn failure(_: *anyopaque) http.Error {
    return error.Transport;
}

fn close(_: *anyopaque) void {}
