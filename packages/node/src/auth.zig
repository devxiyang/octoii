//! A client's access, as the ways it reaches the node carry it: on the loopback, the credential a request presents — a
//! browser's in its session cookie, a program's as a bearer token — and its page's origin, a page of another origin
//! refused, as a browser lets any page send one to any address; in a tunnel session, the key the device's session
//! showed, as an SSH server knows a client by its key. A client pairs by the credential of a link: redeemed for a
//! session held as it holds sessions — on the loopback in an HttpOnly cookie its page cannot read, sent to this node's
//! own pages alone; in a tunnel session by the device's key.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Principal = @import("siphon").protocol.Access.Principal;
const Access = @import("Access.zig");
const Request = @import("Request.zig");

/// Where a client redeems a link for its session.
pub const session_path = "/api/auth/session";

/// The name of the cookie a browser holds its session in at the node of `port`: a browser keeps one set of cookies for
/// a host whatever its port, so each port's node names its own.
pub fn cookieName(arena: Allocator, port: u16) ![]const u8 {
    return arena.print("octoii_session_{d}", .{port});
}

/// Who a request's client is, as the way it came tells, read before its body, which takes its fields' memory over.
pub const Client = struct {
    /// The session it holds, where it presents one that works.
    principal: ?Principal = null,
    /// Whether it comes from one of the node's own pages, or from a program, which names no origin; a device in a
    /// tunnel session speaks for itself.
    same_origin: bool = true,
    /// The browser or program it says it is.
    agent: ?[]const u8 = null,
    /// How a session redeemed for it is held.
    holder: Access.Holder,
};

/// Who `request`'s client is, copied into `arena`: on the loopback, by its bearer token, else its session cookie
/// `cookie`, and its origin; in a tunnel session, by its device's key.
pub fn clientOf(arena: Allocator, request: *const Request, access: Access, cookie: []const u8) !Client {
    const told = try toldBy(arena, request, cookie);
    switch (request.over) {
        .loopback => {
            const principal = if (told.credential) |credential| try access.authenticate(arena, credential) else null;
            return .{ .principal = principal, .same_origin = told.same_origin, .agent = told.agent, .holder = .cookie };
        },
        .tunnel => |tunneled| {
            const device = try arena.dupe(u8, tunneled.device);
            return .{ .principal = try access.authenticateKey(arena, device), .agent = told.agent, .holder = .{ .key = device } };
        },
    }
}

/// What a request's fields tell of its client.
const Told = struct {
    /// The credential it presents: its bearer token, else its session cookie.
    credential: ?[]const u8 = null,
    same_origin: bool = true,
    agent: ?[]const u8 = null,
};

/// What `request`'s fields tell of its client, copied into `arena`; `cookie` names the session cookie.
fn toldBy(arena: Allocator, request: *const Request, cookie: []const u8) !Told {
    var told: Told = .{};
    var origin: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var bearer: ?[]const u8 = null;
    var kept: ?[]const u8 = null;
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "origin")) {
            origin = header.value;
        } else if (std.ascii.eqlIgnoreCase(header.name, "host")) {
            host = header.value;
        } else if (std.ascii.eqlIgnoreCase(header.name, "user-agent")) {
            told.agent = try arena.dupe(u8, header.value[0..@min(header.value.len, agent_bytes_max)]);
        } else if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
            if (std.ascii.startsWithIgnoreCase(header.value, "bearer ")) bearer = std.mem.trim(u8, header.value["bearer ".len..], " ");
        } else if (std.ascii.eqlIgnoreCase(header.name, "cookie")) {
            if (cookieIn(header.value, cookie)) |value| kept = value;
        }
    }
    if (bearer orelse kept) |credential| told.credential = try arena.dupe(u8, credential);
    told.same_origin = origin == null or (host != null and originOf(origin.?, host.?));
    return told;
}

/// The longest browser or program a session is labelled by.
const agent_bytes_max = 200;

/// The value of the cookie `name` in a `Cookie` header's `value`.
fn cookieIn(value: []const u8, name: []const u8) ?[]const u8 {
    var pairs = std.mem.splitScalar(u8, value, ';');
    while (pairs.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, " ");
        const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        if (std.mem.eql(u8, trimmed[0..equals], name)) return trimmed[equals + 1 ..];
    }
    return null;
}

/// Whether the page of `origin` is the node's own, at the address `host` its request was sent to.
fn originOf(origin: []const u8, host: []const u8) bool {
    for ([_][]const u8{ "http://", "https://" }) |scheme| {
        if (std.mem.startsWith(u8, origin, scheme)) return std.mem.eql(u8, origin[scheme.len..], host);
    }
    return false;
}

/// Answers a client that pairs: the credential of a link it sends redeemed for a session held as it holds sessions —
/// a browser's kept in the cookie `cookie`, HttpOnly, sent to this node's own pages alone, for as long as the session
/// lasts; a device's by its key; refused for a page of another origin, a body of another shape, or a credential that
/// pairs nothing.
pub fn answerSession(arena: Allocator, request: *Request, access: Access, client: Client, cookie: []const u8) !void {
    if (request.method() != .POST) return answerJson(request, .method_not_allowed, "{\"code\":\"method\",\"message\":\"A client pairs with a POST.\"}", null);
    if (!client.same_origin) return answerJson(request, .forbidden, "{\"code\":\"origin\",\"message\":\"A page of another origin pairs nothing here.\"}", null);
    var buffer: [512]u8 = undefined;
    const body = (try request.reader(&buffer)).allocRemaining(arena, .limited(body_bytes_max)) catch
        return answerJson(request, .bad_request, "{\"code\":\"invalid\",\"message\":\"The body is not a pairing's.\"}", null);
    const given = std.json.parseFromSliceLeaky(struct { credential: []const u8 }, arena, body, .{}) catch
        return answerJson(request, .bad_request, "{\"code\":\"invalid\",\"message\":\"The body is not a pairing's.\"}", null);
    const made = try access.redeem(arena, std.mem.trim(u8, given.credential, " \t\r\n"), client.holder, client.agent) orelse
        return answerJson(request, .unauthorized, "{\"code\":\"invalid-credential\",\"message\":\"The pairing link is unknown, spent or expired.\"}", null);
    const answer = try arena.print("{{\"authenticated\":true,\"session\":\"{s}\",\"expires_at\":{d}}}", .{ made.id, made.expires_at });
    return switch (client.holder) {
        .cookie => answerJson(request, .ok, answer, try arena.print("{s}={s}; HttpOnly; SameSite=Strict; Path=/; Max-Age={d}", .{ cookie, made.credential, @divTrunc(Access.session_ms, std.time.ms_per_s) })),
        .bearer, .key => answerJson(request, .ok, answer, null),
    };
}

/// The largest body a pairing's request may have.
const body_bytes_max = 4 << 10;

/// Answers `request` with the JSON `body`, kept by no cache, the cookie `set` set where there is one.
pub fn answerJson(request: *Request, status: std.http.Status, body: []const u8, set: ?[]const u8) !void {
    const json: std.http.Header = .{ .name = "content-type", .value = "application/json" };
    const no_store: std.http.Header = .{ .name = "cache-control", .value = "no-store" };
    if (set) |cookie| return request.respond(body, .{ .status = status, .extra_headers = &.{ json, no_store, .{ .name = "set-cookie", .value = cookie } } });
    return request.respond(body, .{ .status = status, .extra_headers = &.{ json, no_store } });
}

/// A request read from `sent` on the loopback, its answer written into `answer`.
pub const Sent = struct {
    reader: std.Io.Reader,
    writer: std.Io.Writer,
    http: std.http.Server,
    head: std.http.Server.Request,
    request: Request,

    pub fn init(sent: *Sent, bytes: []const u8, answer: []u8) !void {
        sent.reader = .fixed(bytes);
        sent.writer = .fixed(answer);
        sent.http = .init(&sent.reader, &sent.writer);
        sent.head = try sent.http.receiveHead();
        sent.request = .{ .over = .{ .loopback = .{ .request = &sent.head, .stream = undefined, .io = std.testing.io } } };
    }

    pub fn answered(sent: *Sent) []const u8 {
        return sent.writer.buffered();
    }
};

/// What the node answers to the HTTP request `sent` that pairs, written into `answer`.
fn answerOf(arena: Allocator, access: Access, sent: []const u8, answer: []u8) ![]const u8 {
    var request: Sent = undefined;
    try request.init(sent, answer);
    const client = try clientOf(arena, &request.request, access, "octoii_session_7600");
    try answerSession(arena, &request.request, access, client, "octoii_session_7600");
    return request.answered();
}

test "a request's credential is its bearer token, else its session cookie; a page of another origin is told apart" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var unused: [1]u8 = undefined;
    var request: Sent = undefined;
    try request.init("GET /ws HTTP/1.1\r\nhost: 127.0.0.1:7600\r\norigin: http://127.0.0.1:7600\r\ncookie: other=1; octoii_session_7600=abc.def; x=y\r\nuser-agent: Firefox\r\n\r\n", &unused);
    const told = try toldBy(arena, &request.request, "octoii_session_7600");
    try std.testing.expectEqualStrings("abc.def", told.credential.?);
    try std.testing.expect(told.same_origin);
    try std.testing.expectEqualStrings("Firefox", told.agent.?);
    try std.testing.expect(originOf("http://127.0.0.1:7600", "127.0.0.1:7600"));
    try std.testing.expect(!originOf("http://evil.example", "127.0.0.1:7600"));
    try std.testing.expect(!originOf("null", "127.0.0.1:7600"));
    try std.testing.expectEqualStrings("t", cookieIn("a=b;  octoii_session_1=t", "octoii_session_1").?);
    try std.testing.expect(cookieIn("octoii_session_10=t", "octoii_session_1") == null);
}

test "a page pairs its browser with a link's credential once: a session in an HttpOnly cookie, and nothing for another origin" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const access = try Access.open(std.testing.io, arena, try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena));
    const link = try access.makeLink(arena, null, Access.all_scopes);
    const body = try arena.print("{{\"credential\":\"{s}\"}}", .{link.credential});
    const post = try arena.print("POST /api/auth/session HTTP/1.1\r\nhost: 127.0.0.1:7600\r\norigin: http://127.0.0.1:7600\r\ncontent-type: application/json\r\ncontent-length: {d}\r\n\r\n{s}", .{ body.len, body });
    var buffer: [2048]u8 = undefined;
    const paired = try answerOf(arena, access, post, &buffer);
    try std.testing.expect(std.mem.startsWith(u8, paired, "HTTP/1.1 200 OK\r\n"));
    const set = std.mem.indexOf(u8, paired, "set-cookie: octoii_session_7600=").?;
    try std.testing.expect(std.mem.indexOf(u8, paired[set..], "; HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000\r\n") != null);
    const again = try answerOf(arena, access, post, &buffer);
    try std.testing.expect(std.mem.startsWith(u8, again, "HTTP/1.1 401 Unauthorized\r\n"));
    const foreign = try std.mem.replaceOwned(u8, arena, post, "origin: http://127.0.0.1:7600", "origin: http://evil.example");
    try std.testing.expect(std.mem.startsWith(u8, try answerOf(arena, access, foreign, &buffer), "HTTP/1.1 403 Forbidden\r\n"));
}
