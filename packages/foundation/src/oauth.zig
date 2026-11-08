//! What a sign-in by OAuth is made of: base64url, a PKCE verifier and its challenge, a form or a query encoded and a
//! query read, and a JWT taken apart and its RS256 signature checked against a published key's modulus and exponent.
const std = @import("std");
const Allocator = std.mem.Allocator;

const url_encoder = std.base64.url_safe_no_pad.Encoder;
const url_decoder = std.base64.url_safe_no_pad.Decoder;

/// `bytes` as base64url without padding, in `arena`.
pub fn base64Url(arena: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
    const out = try arena.alloc(u8, url_encoder.calcSize(bytes.len));
    return url_encoder.encode(out, bytes);
}

/// The bytes base64url `text` holds, with or without its padding, in `arena`; null where it is none.
pub fn fromBase64Url(arena: Allocator, text: []const u8) Allocator.Error!?[]u8 {
    const bare = std.mem.trimEnd(u8, text, "=");
    const size = url_decoder.calcSizeForSlice(bare) catch return null;
    const out = try arena.alloc(u8, size);
    url_decoder.decode(out, bare) catch return null;
    return out;
}

/// A PKCE verifier and its S256 challenge.
pub const Pkce = struct {
    verifier: []const u8,
    challenge: []const u8,

    /// The verifier of `secret`, random bytes, and its challenge.
    pub fn of(arena: Allocator, secret: *const [32]u8) Allocator.Error!Pkce {
        const verifier = try base64Url(arena, secret);
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
        return .{ .verifier = verifier, .challenge = try base64Url(arena, &digest) };
    }
};

/// A name and its value, of a form or a query.
pub const Field = struct { []const u8, []const u8 };

/// `fields` as `application/x-www-form-urlencoded`, as a query is written too.
pub fn formEncoded(arena: Allocator, given: []const Field) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (given, 0..) |field, index| {
        if (index > 0) try out.append(arena, '&');
        try escape(arena, &out, field[0]);
        try out.append(arena, '=');
        try escape(arena, &out, field[1]);
    }
    return out.items;
}

fn escape(arena: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    for (text) |char| switch (char) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '*' => try out.append(arena, char),
        ' ' => try out.append(arena, '+'),
        else => try out.print(arena, "%{X:0>2}", .{char}),
    };
}

/// The fields of a query or a form, each decoded, in the order they stand.
pub fn fields(arena: Allocator, query: []const u8) Allocator.Error![]const Field {
    var made: std.ArrayList(Field) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimStart(u8, query, "?"), '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        try made.append(arena, .{ try unescaped(arena, pair[0..equals]), try unescaped(arena, if (equals < pair.len) pair[equals + 1 ..] else "") });
    }
    return made.items;
}

fn unescaped(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    const copy = try arena.dupe(u8, text);
    std.mem.replaceScalar(u8, copy, '+', ' ');
    return std.Uri.percentDecodeInPlace(copy);
}

/// The value of the first field named `name`; null where none is.
pub fn valueOf(given: []const Field, name: []const u8) ?[]const u8 {
    for (given) |field| if (std.mem.eql(u8, field[0], name)) return field[1];
    return null;
}

/// The query of `url`, without its `?` and its fragment; null where it is no absolute address.
pub fn queryOf(url: []const u8) ?[]const u8 {
    const uri = std.Uri.parse(url) catch return null;
    const query = uri.query orelse return "";
    return switch (query) {
        .raw => |raw| raw,
        .percent_encoded => |encoded| encoded,
    };
}

/// A JWT's three parts: what its signature signs, its header and claims as JSON text, and its signature's bytes.
pub const Jwt = struct {
    signed: []const u8,
    header: []const u8,
    claims: []const u8,
    signature: []const u8,

    /// The parts of `token`; null where it is no JWT.
    pub fn parse(arena: Allocator, token: []const u8) Allocator.Error!?Jwt {
        var it = std.mem.splitScalar(u8, token, '.');
        const header = it.next() orelse return null;
        const claims = it.next() orelse return null;
        const signature = it.next() orelse return null;
        if (it.next() != null) return null;
        return .{
            .signed = token[0 .. header.len + 1 + claims.len],
            .header = try fromBase64Url(arena, header) orelse return null,
            .claims = try fromBase64Url(arena, claims) orelse return null,
            .signature = try fromBase64Url(arena, signature) orelse &.{},
        };
    }

    /// Whether the key of `modulus` and `exponent`, each big-endian bytes, signed the token with RS256.
    pub fn signedBy(jwt: Jwt, modulus: []const u8, exponent: []const u8) bool {
        const rsa = std.crypto.Certificate.rsa;
        const n = std.mem.trimStart(u8, modulus, &.{0});
        if (jwt.signature.len != n.len) return false;
        switch (n.len) {
            inline 128, 256, 384, 512 => |length| {
                const key = rsa.PublicKey.fromBytes(exponent, n) catch return false;
                rsa.PKCS1v1_5Signature.verify(length, jwt.signature[0..length], jwt.signed, key, std.crypto.hash.sha2.Sha256) catch return false;
                return true;
            },
            else => return false,
        }
    }
};

/// What tests sign tokens with: an RSA key's modulus and private exponent, big-endian.
pub const testing = struct {
    /// The JWT of `header` and `claims`, JSON text, signed with RS256 by the key of `modulus` and `private_exponent`.
    pub fn signedToken(arena: Allocator, header: []const u8, claims: []const u8, modulus: []const u8, private_exponent: []const u8) ![]const u8 {
        const signed = try std.fmt.allocPrint(arena, "{s}.{s}", .{ try base64Url(arena, header), try base64Url(arena, claims) });
        const Modulus = std.crypto.ff.Modulus(4096);
        const n = try Modulus.fromBytes(modulus, .big);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(signed, &digest, .{});
        // EMSA-PKCS1-v1_5: 00 01 ff… 00, the DigestInfo of SHA-256, then the digest.
        const info = [_]u8{ 0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20 };
        const encoded = try arena.alloc(u8, modulus.len);
        @memset(encoded, 0xff);
        encoded[0] = 0;
        encoded[1] = 1;
        encoded[modulus.len - info.len - digest.len - 1] = 0;
        @memcpy(encoded[modulus.len - info.len - digest.len ..][0..info.len], &info);
        @memcpy(encoded[modulus.len - digest.len ..], &digest);
        const signature = try n.powWithEncodedExponent(try Modulus.Fe.fromBytes(n, encoded, .big), private_exponent, .big);
        const bytes = try arena.alloc(u8, modulus.len);
        try signature.toBytes(bytes, .big);
        return std.fmt.allocPrint(arena, "{s}.{s}", .{ signed, try base64Url(arena, bytes) });
    }

    /// The bytes of hexadecimal `text`, in `arena`.
    pub fn hexBytes(arena: Allocator, text: []const u8) ![]const u8 {
        const out = try arena.alloc(u8, text.len / 2);
        return std.fmt.hexToBytes(out, text);
    }
};

test "base64url, a PKCE challenge, and a form read back as it was written" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("-_8", try base64Url(a, &.{ 0xfb, 0xff }));
    try std.testing.expectEqualSlices(u8, &.{ 0xfb, 0xff }, (try fromBase64Url(a, "-_8=")).?);
    // RFC 7636's example.
    const secret = [32]u8{ 116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186, 22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88, 83, 132, 141, 121 };
    const pkce: Pkce = try .of(a, &secret);
    try std.testing.expectEqualStrings("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", pkce.verifier);
    try std.testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", pkce.challenge);
    const form = try formEncoded(a, &.{ .{ "scope", "openid email" }, .{ "redirect_uri", "http://127.0.0.1:1455/auth/callback" } });
    try std.testing.expectEqualStrings("scope=openid+email&redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback", form);
    const read = try fields(a, form);
    try std.testing.expectEqualStrings("http://127.0.0.1:1455/auth/callback", valueOf(read, "redirect_uri").?);
    try std.testing.expectEqualStrings("code=c&state=s", queryOf("http://127.0.0.1:1455/auth/callback?code=c&state=s#x").?);
}

test "a JWT's RS256 signature holds for the key that signed it alone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const n = try testing.hexBytes(a, "d4983c9943ae93c5c09d2817c858c3f132b687c22b40e900851a4965c45da74669650d1ad02d281d76234f9105a1337270d1c3c71892b1cb16bcaa0c7bc31841f70e15e9d225fcbcffb9600226f993c593e1d308ebd53674a18353d0e64394611de65b9f44405838132da3f69655b23b309235a60ed4a6c4244ff1260da7eeb5");
    const d = try testing.hexBytes(a, "7b1f2bc14b7c58a2a7799cd5a1371f4b9a26321b96b741fa061c023408f48042fc1904ece971ad90da717acc2f697b8524a7a76dafe28d4b6400a1af172216f255cf12dc0b6ec13a2592133dcb058d2033ff0c5da68a2f83fa32cad2f506dbe817c27e8a864d3372c3a865a43200ede58a9f43fc6f94f385c51d5b243f727d65");
    const token = try testing.signedToken(a, "{\"alg\":\"RS256\"}", "{\"sub\":\"me\"}", n, d);
    const jwt = (try Jwt.parse(a, token)).?;
    try std.testing.expectEqualStrings("{\"sub\":\"me\"}", jwt.claims);
    try std.testing.expect(jwt.signedBy(n, &.{ 1, 0, 1 }));
    const other = try testing.hexBytes(a, "c4bf4da38e9322592a043178c5c4953e1f23d59ba6ef6bdb899c0b6c7e1798409b0dcf8f0f53fc95c60cc993c448a48418a069877c4656cca1de4fe1f74e37d8d3148b0f5bccff4a6dff17e1b56fd27578cdd9332a3e93cd0a14533ef62fe78b010241a1b1559675853da47cb40d53b2cfd63e0034ae135c793d06c6b8e8f7e7");
    try std.testing.expect(!jwt.signedBy(other, &.{ 1, 0, 1 }));
    try std.testing.expectEqual(null, try Jwt.parse(a, "not.a"));
}
