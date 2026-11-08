//! A device reaching the node through a relay on the loopback, over HTTP/3 in its tunnel session: refused files until it
//! pairs, paired by a link's credential for a session its key holds, then a file kept and given back, and the protocol
//! greeting it on its WebSocket.
const std = @import("std");
const tunnel = @import("tunnel");
const siphon_ = @import("siphon");
const Node = @import("Node.zig");
const Access = @import("Access.zig");
const auth = @import("auth.zig");
const serve = @import("serve.zig");

const testing = std.testing;
const Io = std.Io;
const Station = tunnel.Station;
const http3 = tunnel.http3;

/// A relay of the tunnel's own on the loopback, serving in a task of its own.
const Relay = struct {
    listener: Io.net.Server,
    server: tunnel.relay.Server,
    serving: Io.Future(Io.Cancelable!void),
    address_buffer: [32]u8,
    address: []const u8,

    fn start(relay: *Relay) !void {
        relay.listener = try (try Io.net.IpAddress.parseLiteral("127.0.0.1:0")).listen(testing.io, .{});
        relay.server = .init(testing.allocator, testing.io, "127.0.0.1");
        relay.serving = try testing.io.concurrent(tunnel.relay.Server.serve, .{ &relay.server, &relay.listener });
        relay.address = try std.fmt.bufPrint(&relay.address_buffer, "ws://127.0.0.1:{d}", .{relay.listener.socket.address.getPort()});
    }

    fn stop(relay: *Relay) void {
        _ = relay.serving.cancel(testing.io) catch {};
        relay.server.deinit();
        relay.listener.deinit(testing.io);
    }
};

/// The status of the response to `request`, its body read whole into `arena`.
fn answerOf(arena: std.mem.Allocator, request: *http3.Client.Request) !struct { std.http.Status, []const u8 } {
    try request.finish();
    try request.receiveHead();
    var buffer: [4096]u8 = undefined;
    return .{ request.head.status, try request.reader(&buffer).allocRemaining(arena, .limited(1 << 20)) };
}

test "a device pairs with the node through a relay, then reaches its files and its protocol by its key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    const node = try Node.open(testing.allocator, testing.io, &environ, arena, try tmp.dir.realPathFileAlloc(testing.io, ".", arena), .{ .port = 7600 });
    defer node.close();
    try node.siphon.runtime.start();

    var relay: Relay = undefined;
    try relay.start();
    defer relay.stop();
    const home = node.identity.publicKey();
    const station = try Station.init(testing.allocator, testing.io, node.identity, .{});
    defer station.deinit();
    _ = try station.join(relay.address, home);
    const server: serve.Server = .{ .siphon = node.siphon, .gpa = testing.allocator, .access = node.access, .app = null, .cookie = "octoii_session_7600" };
    var serving = try testing.io.concurrent(serve.serveTunnel, .{ &server, station });
    defer _ = serving.cancel(testing.io) catch {};

    const device_identity = tunnel.Identity.generate(testing.io);
    const device = try Station.init(testing.allocator, testing.io, device_identity, .{});
    defer device.deinit();
    const opened = try device.connect(home, try device.join(relay.address, home));
    defer device.close(opened, @backingInt(http3.Code.no_error));
    const client: http3.Client = try .init(testing.allocator, device, opened);
    defer client.deinit();

    const refused = try client.request(.GET, "/files/sha256:00", .{ .authority = "node" });
    defer refused.deinit();
    try testing.expectEqual(std.http.Status.unauthorized, (try answerOf(arena, refused))[0]);

    const link = try node.access.makeLink(arena, null, Access.all_scopes);
    const pairing = try client.request(.POST, auth.session_path, .{ .authority = "node", .extra_headers = &.{.{ .name = "user-agent", .value = "a test's device" }} });
    defer pairing.deinit();
    try pairing.writer().print("{{\"credential\":\"{s}\"}}", .{link.credential});
    const paired_status, const paired = try answerOf(arena, pairing);
    try testing.expectEqual(std.http.Status.ok, paired_status);
    const session = (try std.json.parseFromSliceLeaky(struct { session: []const u8 }, arena, paired, .{ .ignore_unknown_fields = true })).session;
    try testing.expectEqualStrings(session, (try node.access.authenticateKey(arena, &device_identity.publicKey().text())).?.session);

    const keeping = try client.request(.POST, "/files", .{ .authority = "node" });
    defer keeping.deinit();
    try keeping.writer().writeAll("a file a device sent");
    const kept_status, const kept = try answerOf(arena, keeping);
    try testing.expectEqual(std.http.Status.ok, kept_status);
    const ref = (try std.json.parseFromSliceLeaky(struct { ref: []const u8 }, arena, kept, .{ .ignore_unknown_fields = true })).ref;
    const giving = try client.request(.GET, try std.mem.concat(arena, u8, &.{ "/files/", ref }), .{ .authority = "node" });
    defer giving.deinit();
    const given_status, const given = try answerOf(arena, giving);
    try testing.expectEqual(std.http.Status.ok, given_status);
    try testing.expectEqualStrings("a file a device sent", given);

    var messages: [64 * 1024]u8 = undefined;
    const socket = try client.openWebSocket(serve.socket_path, .{ .authority = "node", .buffer = &messages });
    defer socket.close();
    try socket.send(.text, try std.fmt.allocPrint(arena, "{{\"id\":\"1\",\"method\":\"hello\",\"params\":{{\"protocol\":{d}}}}}", .{siphon_.protocol.Connection.protocol}));
    const greeted = (try socket.receive()).text;
    const answer = try std.json.parseFromSliceLeaky(struct { id: []const u8, result: struct { session: []const u8 } }, arena, greeted, .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings("1", answer.id);
    try testing.expectEqualStrings(session, answer.result.session);
}
