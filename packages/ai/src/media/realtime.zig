//! The realtime transcription kind as `Models` serves it: a session's settings checked against its model — one that
//! serves the kind and reads audio, at the one rate of the subset — its socket opened through the host's connector as
//! its provider's driver says, and held until the provider has taken its settings; each completed item's usage priced
//! at the model's realtime prices; and a session made for a client by WebRTC.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vocabulary = @import("vocabulary");
const realtime = vocabulary.realtime;
const ServerEvent = realtime.ServerEvent;
const driver = @import("../driver.zig");
const Call = driver.Call;
const failure_ = @import("../failure.zig");
const Failure = failure_.Failure;
const Error = failure_.Error;
const Model = @import("../catalogue/model.zig").Model;
const Models = @import("../Models.zig");
const stream_ = @import("stream.zig");
const usage = @import("usage.zig");
const text_stream = @import("../text/stream.zig");
const session_ = @import("../wire/realtime/session.zig");
pub const Polled = session_.Polled;

/// A realtime transcription session, open: its events read with `poll` or `next` by one task at a time, while
/// another may `send` and `close`. Its events are the provider's, each completed item priced; an event lives until
/// the next read. It is let go with `deinit`.
pub const RealtimeSession = struct {
    gpa: Allocator,
    /// What the session keeps of its opening, its model among it.
    lasting: std.heap.ArenaAllocator,
    model: *const Model,
    session: *session_.Session,

    /// The next event, waiting at most `wait_ms`; none, until one comes or the session ends.
    pub fn poll(open: *RealtimeSession, wait_ms: ?u64) Polled {
        return switch (open.session.poll(wait_ms)) {
            .event => |event| .{ .event = priced(open.model, event, open.session.host.nowMs()) },
            else => |other| other,
        };
    }

    /// The next event, however long it takes; null once the session ends, `failure` saying why where a failure ended
    /// it.
    pub fn next(open: *RealtimeSession) ?ServerEvent {
        return switch (open.poll(null)) {
            .event => |event| event,
            .ended => null,
            .quiet => unreachable,
        };
    }

    /// Sends `event` to the provider; one the provider does not take is answered by an `error` event.
    pub fn send(open: *RealtimeSession, event: realtime.ClientEvent) void {
        open.session.send(event);
    }

    /// Commits the audio not yet committed; the events go on until its transcription completes.
    pub fn close(open: *RealtimeSession) void {
        open.session.close();
    }

    /// What ended the session, once it ended, where a failure did.
    pub fn failure(open: *RealtimeSession) ?Failure {
        open.session.lock.lockUncancelable(open.session.host.io);
        defer open.session.lock.unlock(open.session.host.io);
        return open.session.failure;
    }

    pub fn deinit(open: *RealtimeSession) void {
        open.session.deinit();
        open.lasting.deinit();
        open.gpa.destroy(open);
    }
};

/// A session opened, or the failure it could not open with.
pub const Connected = union(enum) {
    session: *RealtimeSession,
    failed: Failure,
};

/// Opens a session of `session`'s settings, once its provider has taken them; its failure in `arena`.
pub fn connect(models: *Models, arena: Allocator, session: realtime.Session) Allocator.Error!Connected {
    return opened(models, arena, session.model(), .{ .settings = &session });
}

/// Connects to the session of a client's call as its sideband, which sends no audio; its failure in `arena`.
pub fn sideband(models: *Models, arena: Allocator, params: realtime.SidebandParams) Allocator.Error!Connected {
    return opened(models, arena, params.model, .{ .call_id = params.call_id });
}

/// What a session opens with: its settings, or the call it is the sideband of.
const Opened = union(enum) {
    settings: *const realtime.Session,
    call_id: []const u8,
};

fn opened(models: *Models, arena: Allocator, reference: []const u8, given: Opened) Allocator.Error!Connected {
    const open = try models.gpa.create(RealtimeSession);
    open.* = .{ .gpa = models.gpa, .lasting = .init(models.gpa), .model = undefined, .session = undefined };
    var call: Call = .{ .arena = open.lasting.allocator(), .provider = undefined, .host = &models.host };
    const made = opening(models, &call, open, reference, given) catch |err| {
        open.lasting.deinit();
        models.gpa.destroy(open);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Failed => .{ .failed = try copied(arena, call.failure.?) },
        };
    };
    open.session = made;
    if (made.awaitOpen()) |failure| {
        const kept = try copied(arena, failure);
        open.deinit();
        return .{ .failed = kept };
    }
    return .{ .session = open };
}

/// The session `given` opens for the model `reference` names, its socket open and its wire started.
fn opening(models: *Models, call: *Call, open: *RealtimeSession, reference: []const u8, given: Opened) Error!*session_.Session {
    const found = try models.served(call, reference, .@"realtime-transcription");
    call.provider = found.provider;
    const model = try call.arena.create(Model);
    model.* = found.model;
    open.model = model;
    if (!model.reads(.audio)) return call.failWith(.invalid_request, "The model {s} does not read audio: its architecture.input_modalities lack it", .{reference});
    const calls = found.provider.driver.realtime orelse return call.failWith(.invalid_request, "The provider {s} serves no realtime transcription", .{found.provider.id});
    const made = switch (given) {
        .settings => |settings| made: {
            try checkSession(call, settings);
            break :made try calls.connect(call, model, settings, models.gpa);
        },
        .call_id => |id| made: {
            const connect_sideband = calls.connect_sideband orelse return call.failWith(.invalid_request, "The provider {s} connects no sideband to a realtime session", .{found.provider.id});
            break :made try connect_sideband(call, model, id, models.gpa);
        },
    };
    const socket = models.host.sockets().connect(.{ .url = made.url, .headers = made.headers }) catch |err| {
        made.wire.vtable.deinit(made.wire.context);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => call.failWith(.aborted, "The session's opening was canceled", .{}),
            error.Transport => call.failWith(.transport, "The session's connection did not open", .{}),
        };
    };
    return session_.Session.start(models.gpa, &models.host, socket, made.wire);
}

/// Checks the settings' audio: raw PCM16 at the one rate of the subset.
fn checkSession(call: *Call, session: *const realtime.Session) Error!void {
    const format = session.audio.input.format orelse return;
    const rate = format.rate orelse return;
    if (rate != realtime.pcm_rate_hz) return call.failWith(.invalid_request, "A realtime session's audio is PCM16 at {d} Hz, not {d}", .{ realtime.pcm_rate_hz, rate });
}

/// Makes a session for a client that connects by WebRTC, from its offer: its call's id and the answer for the client.
pub fn createCall(models: *Models, arena: Allocator, params: realtime.CallCreateParams) Allocator.Error!stream_.Outcome(realtime.CallCreateResponse) {
    var call: Call = .{ .arena = arena, .provider = undefined, .host = &models.host, .wait = .{ .head_ms = text_stream.start_timeout_ms, .idle_ms = text_stream.idle_timeout_ms } };
    const made = createdCall(models, &call, &params) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return .{ .failed = call.failure.? },
    };
    return .{ .made = made };
}

fn createdCall(models: *Models, call: *Call, params: *const realtime.CallCreateParams) Error!realtime.CallCreateResponse {
    const reference = params.session.model();
    const found = try models.served(call, reference, .@"realtime-transcription");
    call.provider = found.provider;
    const model = try call.arena.create(Model);
    model.* = found.model;
    if (!model.reads(.audio)) return call.failWith(.invalid_request, "The model {s} does not read audio: its architecture.input_modalities lack it", .{reference});
    try checkSession(call, &params.session);
    const calls = found.provider.driver.realtime orelse return call.failWith(.invalid_request, "The provider {s} serves no realtime transcription", .{found.provider.id});
    const create_call = calls.create_call orelse return call.failWith(.invalid_request, "The provider {s} makes no realtime session for a client by WebRTC", .{found.provider.id});
    return create_call(call, model, params);
}

/// `event` with Octoii's account where it completes an item: the meters its provider gave, else its usage's, at the
/// model's realtime prices.
fn priced(model: *const Model, event: ServerEvent, at_ms: i64) ServerEvent {
    if (event != .completed) return event;
    var completed = event.completed;
    var at_prices = model.*;
    if (model.octoii.realtime_pricing) |prices| at_prices.pricing = prices;
    const meters = if (completed.octoii) |given| given.usage orelse usage.realtimeMeters(&at_prices, completed.usage) else usage.realtimeMeters(&at_prices, completed.usage);
    completed.octoii = .{ .usage = usage.priced(&at_prices, meters, null, at_ms) };
    return .{ .completed = completed };
}

/// `failure` with what it holds copied into `arena`, as the session that made it is let go.
fn copied(arena: Allocator, failure: Failure) Allocator.Error!Failure {
    var made = failure;
    made.message = try arena.dupe(u8, failure.message);
    if (failure.code) |code| made.code = try arena.dupe(u8, code);
    if (failure.body) |body| made.body = try arena.dupe(u8, body);
    return made;
}
