//! `octoii login`: the machine added to its person's account at an accounts service, as RFC 8628 has a device join
//! one — the service asked for a code, which the person confirms in their browser, and polled meanwhile, each poll
//! carrying the machine's proof that it holds its key: its signature of the device code. Once the person confirmed, the
//! service adds the machine to their account by its key and its name, and gives it its address: where the relay of that
//! service serves its home, and devices reach it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Identity = @import("tunnel").Identity;

/// The accounts a machine joins unless another is named.
pub const default_accounts = "https://accounts.octoii.com";

/// The client a machine signs in as.
const client_id = "octoii";

/// What a machine signs, ahead of its device code, to show the key it is added by is its own.
const proof_context = "octoii machine\x00";

/// How much longer a device waits between polls once the service asks it to slow down, in seconds (RFC 8628, 3.5).
const slow_down_s = 5;

/// A device's authorization begun, as the service answered it.
const Started = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    verification_uri_complete: ?[]const u8 = null,
    expires_in: u64,
    interval: u64 = 5,
};

/// What became of the machine's authorization: added to the account, at the address the service gave it; denied — by
/// its person, or as another account's machine — or refused its proof, as the service says why; or not decided in time.
pub const Outcome = union(enum) { added: []const u8, denied: ?[]const u8, refused: ?[]const u8, expired };

/// Adds the machine of `identity`, named `name`, to an account at the accounts service at `accounts`: the code its
/// person confirms told on `out`, then the service polled till they decide.
pub fn login(client: *std.http.Client, arena: Allocator, accounts: []const u8, identity: Identity, name: []const u8, out: *Io.Writer) !Outcome {
    const key = identity.publicKey().text();
    const begun = try post(client, arena, accounts, "/oauth/device_authorization", &.{ .{ "client_id", client_id }, .{ "key", &key }, .{ "name", name } });
    if (begun.status != .ok) return error.Refused;
    const started = try std.json.parseFromSliceLeaky(Started, arena, begun.body, .{ .ignore_unknown_fields = true });
    try out.print("confirm {s} at {s}\n", .{ started.user_code, started.verification_uri_complete orelse started.verification_uri });
    try out.flush();
    const proof = try proofOf(arena, identity, started.device_code);
    var interval = started.interval;
    var waited: u64 = 0;
    while (waited < started.expires_in) {
        try client.io.sleep(.fromSeconds(@intCast(interval)), .awake);
        waited += @max(interval, 1);
        const polled = try post(client, arena, accounts, "/oauth/token", &.{
            .{ "grant_type", "urn:ietf:params:oauth:grant-type:device_code" },
            .{ "client_id", client_id },
            .{ "device_code", started.device_code },
            .{ "proof", proof },
        });
        if (polled.status == .ok) {
            const added = std.json.parseFromSliceLeaky(struct { address: []const u8 }, arena, polled.body, .{ .ignore_unknown_fields = true }) catch return error.Refused;
            _ = relayAt(arena, added.address) catch return error.Refused;
            return .{ .added = added.address };
        }
        const refusal = std.json.parseFromSliceLeaky(struct { @"error": []const u8, error_description: ?[]const u8 = null }, arena, polled.body, .{ .ignore_unknown_fields = true }) catch return error.Refused;
        const told = std.meta.stringToEnum(Refusal, refusal.@"error") orelse return error.Refused;
        switch (told) {
            .authorization_pending => {},
            .slow_down => interval += slow_down_s,
            .access_denied => return .{ .denied = refusal.error_description },
            .expired_token => return .expired,
            .invalid_grant => return .{ .refused = refusal.error_description },
        }
    }
    return .expired;
}

/// The relay at a machine's address, an `https` or `http` origin: a WebSocket at its host, `wss` for `https` and `ws`
/// for `http`, where the relay serves the machine's home.
pub fn relayAt(arena: Allocator, address: []const u8) ![]const u8 {
    const uri = std.Uri.parse(address) catch return error.InvalidAddress;
    const secure = std.mem.eql(u8, uri.scheme, "https");
    if (!secure and !std.mem.eql(u8, uri.scheme, "http")) return error.InvalidAddress;
    if (uri.host == null or !uri.path.isEmpty() or uri.query != null or uri.fragment != null or uri.user != null) return error.InvalidAddress;
    return std.mem.concat(arena, u8, &.{ if (secure) "wss" else "ws", address[uri.scheme.len..] });
}

/// The errors a device's poll is answered with (RFC 8628, 3.5).
const Refusal = enum { authorization_pending, slow_down, access_denied, expired_token, invalid_grant };

/// The machine's proof for `device_code`: its signature of it, ahead of the proof's context, in base64url.
fn proofOf(arena: Allocator, identity: Identity, device_code: []const u8) ![]const u8 {
    const message = try std.mem.concat(arena, u8, &.{ proof_context, device_code });
    const signature = try identity.sign(message);
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const proof = try arena.alloc(u8, encoder.calcSize(signature.len));
    _ = encoder.encode(proof, &signature);
    return proof;
}

/// What the service answered a form posted to it.
const Answered = struct { status: std.http.Status, body: []const u8 };

/// Posts the form of `fields` to `path` of the service at `accounts`.
fn post(client: *std.http.Client, arena: Allocator, accounts: []const u8, path: []const u8, fields: []const [2][]const u8) !Answered {
    var form: Io.Writer.Allocating = .init(arena);
    for (fields, 0..) |field, index| {
        if (index > 0) try form.writer.writeByte('&');
        try encoded(&form.writer, field[0]);
        try form.writer.writeByte('=');
        try encoded(&form.writer, field[1]);
    }
    var body: Io.Writer.Allocating = .init(arena);
    const result = try client.fetch(.{
        .location = .{ .url = try std.mem.concat(arena, u8, &.{ accounts, path }) },
        .method = .POST,
        .payload = form.written(),
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
        .response_writer = &body.writer,
    });
    return .{ .status = result.status, .body = body.written() };
}

/// Writes `value` as a form encodes it: what is not unreserved, by its bytes in percent form.
fn encoded(writer: *Io.Writer, value: []const u8) !void {
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~", byte) != null) {
            try writer.writeByte(byte);
        } else {
            try writer.print("%{X:0>2}", .{byte});
        }
    }
}

const testing = std.testing;

/// An accounts service on the loopback as a test has it decide: each machine's authorization begun, polled once while
/// it waits, then decided as `decision` — added, where the machine proves its key.
const Accounts = struct {
    listener: Io.net.Server,
    serving: Io.Future(void),
    decision: enum { add, cancel },
    stopping: std.atomic.Value(bool) = .init(false),
    polls: usize = 0,
    key: ?Identity.PublicKey = null,
    address: [32]u8 = undefined,
    address_length: usize = 0,

    fn start(accounts: *Accounts) !void {
        const io = testing.io;
        accounts.listener = try (try Io.net.IpAddress.parseLiteral("127.0.0.1:0")).listen(io, .{});
        accounts.address_length = (try std.fmt.bufPrint(&accounts.address, "http://127.0.0.1:{d}", .{accounts.listener.socket.address.getPort()})).len;
        accounts.serving = try io.concurrent(serve, .{accounts});
    }

    /// Stops the service: its accept woken by a connection of the test's own, which it takes as its sign to end.
    fn stop(accounts: *Accounts) void {
        const io = testing.io;
        accounts.stopping.store(true, .release);
        if (accounts.listener.socket.address.connect(io, .{ .mode = .stream })) |waking| waking.close(io) else |_| {}
        accounts.serving.await(io);
        accounts.listener.deinit(io);
    }

    fn origin(accounts: *const Accounts) []const u8 {
        return accounts.address[0..accounts.address_length];
    }

    fn serve(accounts: *Accounts) void {
        const io = testing.io;
        while (true) {
            const stream = accounts.listener.accept(io) catch return;
            defer stream.close(io);
            if (accounts.stopping.load(.acquire)) return;
            accounts.serveConnection(stream) catch {};
        }
    }

    fn serveConnection(accounts: *Accounts, stream: Io.net.Stream) !void {
        const io = testing.io;
        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [1024]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        var writer = stream.writer(io, &write_buffer);
        var http: std.http.Server = .init(&reader.interface, &writer.interface);
        while (true) {
            var request = http.receiveHead() catch return;
            var body_buffer: [512]u8 = undefined;
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            // The head is the reader's till the body is read: its target kept first.
            const target = try arena.dupe(u8, request.head.target);
            const body = try (try request.readerExpectContinue(&body_buffer)).allocRemaining(arena, .limited(4096));
            const answered = try accounts.answer(arena, target, body);
            try request.respond(answered.body, .{ .status = answered.status, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
        }
    }

    fn answer(accounts: *Accounts, arena: Allocator, target: []const u8, body: []const u8) !Answered {
        if (std.mem.eql(u8, target, "/oauth/device_authorization")) {
            accounts.key = try Identity.PublicKey.parse(valueOf(body, "key") orelse "");
            if (!std.mem.eql(u8, valueOf(body, "name") orelse "", "studio%20mac")) return .{ .status = .bad_request, .body = "{\"error\":\"invalid_request\"}" };
            return .{ .status = .ok, .body = "{\"device_code\":\"a-device-code\",\"user_code\":\"ZQKH-RVTX\",\"verification_uri\":\"https://accounts.test/device\",\"expires_in\":600,\"interval\":0}" };
        }
        accounts.polls += 1;
        if (accounts.polls == 1) return .{ .status = .bad_request, .body = "{\"error\":\"authorization_pending\"}" };
        if (accounts.decision == .cancel) return .{ .status = .bad_request, .body = "{\"error\":\"access_denied\"}" };
        const proof = valueOf(body, "proof") orelse "";
        var signature: [Identity.signature_length]u8 = undefined;
        std.base64.url_safe_no_pad.Decoder.decode(&signature, proof) catch return .{ .status = .bad_request, .body = "{\"error\":\"invalid_grant\"}" };
        const message = try std.mem.concat(arena, u8, &.{ proof_context, "a-device-code" });
        accounts.key.?.verify(message, signature) catch return .{ .status = .bad_request, .body = "{\"error\":\"invalid_grant\"}" };
        return .{ .status = .ok, .body = "{\"access_token\":\"octoii_token\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"scope\":\"machine\",\"address\":\"https://k3x7mq2vtd7a.octoiitunnel.test\"}" };
    }

    /// The value of the field `name` of a form, as it was encoded.
    fn valueOf(form: []const u8, name: []const u8) ?[]const u8 {
        var fields = std.mem.splitScalar(u8, form, '&');
        while (fields.next()) |field| {
            const equals = std.mem.indexOfScalar(u8, field, '=') orelse continue;
            if (std.mem.eql(u8, field[0..equals], name)) return field[equals + 1 ..];
        }
        return null;
    }
};

/// Logs the machine of `identity` in at `accounts` as "studio mac", what it is told on `arena`.
fn loginTo(accounts: *const Accounts, arena: Allocator, identity: Identity, out: *Io.Writer) !Outcome {
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();
    return login(&client, arena, accounts.origin(), identity, "studio mac", out);
}

test "a machine shows its code, waits on its person, and is added at its address once it proves its key" {
    var accounts: Accounts = .{ .listener = undefined, .serving = undefined, .decision = .add };
    try accounts.start();
    defer accounts.stop();
    const identity = Identity.generate(testing.io);
    var told: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&told);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("https://k3x7mq2vtd7a.octoiitunnel.test", (try loginTo(&accounts, arena_state.allocator(), identity, &out)).added);
    try testing.expectEqualStrings("confirm ZQKH-RVTX at https://accounts.test/device\n", out.buffered());
    try testing.expect(accounts.key.?.eql(identity.publicKey()));
    try testing.expectEqual(2, accounts.polls);
}

test "a machine its person cancels is told so" {
    var accounts: Accounts = .{ .listener = undefined, .serving = undefined, .decision = .cancel };
    try accounts.start();
    defer accounts.stop();
    var told: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&told);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqual(Outcome{ .denied = null }, try loginTo(&accounts, arena_state.allocator(), Identity.generate(testing.io), &out));
}

test "the relay at a machine's address is a WebSocket at its host" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("wss://k3x7mq2vtd7a.octoiitunnel.com", try relayAt(arena, "https://k3x7mq2vtd7a.octoiitunnel.com"));
    try testing.expectEqualStrings("ws://k3x7mq2vtd7a.localhost:8787", try relayAt(arena, "http://k3x7mq2vtd7a.localhost:8787"));
    for ([_][]const u8{ "ftp://octoiitunnel.com", "https://octoiitunnel.com/home", "https://octoiitunnel.com?x", "https://a@octoiitunnel.com", "octoiitunnel.com", "https:" }) |address| {
        try testing.expectError(error.InvalidAddress, relayAt(arena, address));
    }
}
