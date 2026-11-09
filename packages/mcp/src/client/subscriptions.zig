//! A stream of the server's change notifications, as each era has it: a stateless server is sent
//! `subscriptions/listen`, which acknowledges what it will send and stays open, its notifications coming on it; a
//! session-based one sends list changes on its own, apart from any request, and is asked to `resources/subscribe` each
//! resource. Either way the subscription's events are read with `next`, and it ends by its server, its transport, or
//! `close`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const foundation = @import("foundation");
const Client = @import("../Client.zig");
const jsonrpc = @import("foundation").jsonrpc;
const protocol = @import("../protocol.zig");
const types = @import("../types.zig");
const results = @import("../results.zig");
const failure_ = @import("../failure.zig");
const Slot = failure_.Slot;
const Error = failure_.Error;
const transport_ = @import("../transport.zig");
const requests = @import("requests.zig");
const answers = @import("answers.zig");

/// How a subscription ended: closed by the client, ended by its server, or cut off with its transport.
pub const End = enum { client, server, transport };

pub const Subscription = struct {
    client: *Client,
    /// What it keeps as long as it lasts: what the server agreed to send among it.
    arena: std.heap.ArenaAllocator,
    acknowledged: types.SubscriptionFilter,
    /// A stateless server's stream and the request it answers; none for a session-based server's.
    exchange: ?transport_.Exchange,
    id: i64,
    ended: ?End = null,

    /// The next change, in `arena`, waiting at most `wait_ms`; null where none came within it, or the subscription
    /// ended, as `ended` then says.
    pub fn next(subscription: *Subscription, arena: Allocator, wait_ms: ?u64) Allocator.Error!?answers.Event {
        if (subscription.ended != null) return null;
        const exchange = subscription.exchange orelse return subscription.nextApart(arena, wait_ms);
        var slot: Slot = .{ .arena = arena };
        while (true) {
            const incoming = exchange.next(&slot, wait_ms) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Failed => return subscription.end(.transport),
            };
            switch (incoming) {
                .message => |arrived| switch (arrived.message) {
                    .notification => |notification| {
                        if (std.mem.eql(u8, notification.method, "notifications/cancelled")) return subscription.end(.server);
                        if (try answers.eventOf(arena, notification)) |event| return event;
                    },
                    .result, .failure => return subscription.end(.server),
                    .request => |asked| answers.serve(subscription.client, &slot, asked, null) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Failed => {},
                    },
                },
                .quiet => return null,
                .lost, .closed => return subscription.end(.transport),
            }
        }
    }

    /// A session-based server's next change of those acknowledged, from what it sends apart.
    fn nextApart(subscription: *Subscription, arena: Allocator, wait_ms: ?u64) Allocator.Error!?answers.Event {
        while (true) {
            const event = try subscription.client.nextEvent(arena, wait_ms) orelse {
                if (subscription.client.currentState() == .closed) return subscription.end(.transport);
                return null;
            };
            if (subscription.takes(event)) return event;
        }
    }

    fn takes(subscription: *const Subscription, event: answers.Event) bool {
        const filter = subscription.acknowledged;
        return switch (event) {
            .tools_list_changed => filter.toolsListChanged,
            .prompts_list_changed => filter.promptsListChanged,
            .resources_list_changed => filter.resourcesListChanged,
            .resource_updated => |uri| for (filter.resourceSubscriptions) |each| {
                if (std.mem.eql(u8, each, uri)) break true;
            } else false,
            .log => false,
        };
    }

    fn end(subscription: *Subscription, how: End) ?answers.Event {
        subscription.ended = how;
        if (subscription.exchange) |exchange| exchange.close();
        subscription.exchange = null;
        return null;
    }

    /// Closes the subscription, where it is open, and lets it go: a stateless server's stream is closed, a session's
    /// resources unsubscribed.
    pub fn close(subscription: *Subscription) void {
        if (subscription.ended == null) {
            if (subscription.exchange) |exchange| exchange.cancel("The subscription closed") else subscription.unsubscribe();
        }
        const gpa = subscription.client.gpa;
        subscription.arena.deinit();
        gpa.destroy(subscription);
    }

    fn unsubscribe(subscription: *Subscription) void {
        if (subscription.client.currentState() != .connected) return;
        var scratch_arena: std.heap.ArenaAllocator = .init(subscription.client.gpa);
        defer scratch_arena.deinit();
        for (subscription.acknowledged.resourceSubscriptions) |uri| {
            var slot: Slot = .{ .arena = scratch_arena.allocator() };
            var params: ObjectMap = .empty;
            params.put(slot.arena, "uri", .{ .string = uri }) catch return;
            _ = requests.request(subscription.client, &slot, "resources/unsubscribe", params, .{}) catch {};
        }
    }
};

/// Opens a subscription to the changes `filter` asks for.
pub fn listen(client: *Client, slot: *Slot, filter: types.SubscriptionFilter) Error!*Subscription {
    const subscription = try client.gpa.create(Subscription);
    errdefer client.gpa.destroy(subscription);
    subscription.* = .{ .client = client, .arena = .init(client.gpa), .acknowledged = .{}, .exchange = null, .id = 0 };
    errdefer subscription.arena.deinit();
    if (client.era() == .legacy) try listenApart(client, slot, subscription, filter) else try listenModern(client, slot, subscription, filter);
    return subscription;
}

/// `subscriptions/listen`, waited for until the server acknowledges it.
fn listenModern(client: *Client, slot: *Slot, subscription: *Subscription, filter: types.SubscriptionFilter) Error!void {
    if (client.currentState() == .closed) return slot.fail(.{ .connection_lost = "The MCP client is not connected" });
    const id = client.nextId();
    var params: ObjectMap = .empty;
    try params.put(slot.arena, "notifications", try foundation.json.toValue(slot.arena, filter));
    const message: jsonrpc.Request = .{ .id = .{ .number = id }, .method = "subscriptions/listen", .params = try requests.withMeta(client, slot.arena, params, id, .{}) };
    const exchange = try client.transport.request(slot, message, .{});
    subscription.id = id;
    while (true) {
        const incoming = exchange.next(slot, client.options.timeout_ms) catch |err| {
            exchange.close();
            return err;
        };
        const notification = switch (incoming) {
            .message => |arrived| switch (arrived.message) {
                .notification => |given| given,
                .failure => |failed| {
                    exchange.close();
                    return slot.fail(.{ .refused = .{ .code = failed.@"error".code, .message = failed.@"error".message, .data = failed.@"error".data } });
                },
                .result => {
                    exchange.close();
                    return slot.violated("The server ended the subscription before acknowledging it", .{});
                },
                .request => |asked| {
                    try answers.serve(client, slot, asked, null);
                    continue;
                },
            },
            .quiet => {
                exchange.cancel("Timed out");
                return slot.fail(.{ .timeout = .{ .method = "subscriptions/listen", .timeout_ms = client.options.timeout_ms } });
            },
            .lost, .closed => {
                exchange.close();
                return slot.fail(.{ .connection_lost = "The subscription's stream broke before the server acknowledged it" });
            },
        };
        if (!std.mem.eql(u8, notification.method, "notifications/subscriptions/acknowledged")) continue;
        const params_given = notification.params orelse Value{ .object = .empty };
        const acknowledged = if (params_given == .object) params_given.object.get("notifications") else null;
        subscription.acknowledged = try copiedFilter(subscription.arena.allocator(), try results.subscriptionFilter(slot.arena, acknowledged));
        subscription.exchange = exchange;
        return;
    }
}

/// A session-based server's subscription: each resource subscribed where the server takes subscriptions, and list
/// changes acknowledged where the server says it sends them.
fn listenApart(client: *Client, slot: *Slot, subscription: *Subscription, filter: types.SubscriptionFilter) Error!void {
    const capabilities = client.server().?.capabilities;
    const subscribes = flag(capabilities, "resources", "subscribe");
    const uris = if (subscribes) filter.resourceSubscriptions else &.{};
    for (uris) |uri| {
        var params: ObjectMap = .empty;
        try params.put(slot.arena, "uri", .{ .string = uri });
        _ = try requests.request(client, slot, "resources/subscribe", params, .{});
    }
    subscription.acknowledged = try copiedFilter(subscription.arena.allocator(), .{
        .toolsListChanged = filter.toolsListChanged and flag(capabilities, "tools", "listChanged"),
        .promptsListChanged = filter.promptsListChanged and flag(capabilities, "prompts", "listChanged"),
        .resourcesListChanged = filter.resourcesListChanged and flag(capabilities, "resources", "listChanged"),
        .resourceSubscriptions = uris,
    });
}

/// Whether the capability `group` sets `name`.
fn flag(capabilities: Value, group: []const u8, name: []const u8) bool {
    if (capabilities != .object) return false;
    const given = capabilities.object.get(group) orelse return false;
    if (given != .object) return false;
    const value = given.object.get(name) orelse return false;
    return value == .bool and value.bool;
}

fn copiedFilter(arena: Allocator, filter: types.SubscriptionFilter) Allocator.Error!types.SubscriptionFilter {
    var copy = filter;
    const uris = try arena.alloc([]const u8, filter.resourceSubscriptions.len);
    for (filter.resourceSubscriptions, uris) |uri, *kept| kept.* = try arena.dupe(u8, uri);
    copy.resourceSubscriptions = uris;
    return copy;
}
