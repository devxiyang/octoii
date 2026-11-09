//! OpenAI's realtime transcription: its Realtime API's transcription sessions, which the vocabulary is. Over WebSocket
//! at `/realtime` with `intent=transcription`, the session goes as a `session.update`, its model by `id`, and is open
//! once `session.updated` has come; the events come back as they are, the session's model as its reference and each
//! error's failure classified. A WebRTC session is made at `/realtime/calls`, and its sideband connects with its
//! `call_id`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const realtime = vocabulary.realtime;
const seam = @import("../../driver.zig");
const Call = seam.Call;
const failure_ = @import("../../failure.zig");
const Error = failure_.Error;
const Model = @import("../../catalogue/model.zig").Model;
const json = @import("../../wire/json.zig");
const session_ = @import("../../wire/realtime/session.zig");
const Out = session_.Out;
const WireError = session_.Error;
const media = @import("media.zig");
const openai = @import("../openai.zig");

pub const calls: seam.RealtimeCalls = .{ .connect = connect, .connect_sideband = connectSideband, .create_call = createCall };

/// The server events of the subset, which come back as they are; OpenAI's others are left out.
const passed = std.StaticStringMap(void).initComptime(.{
    .{"input_audio_buffer.committed"},
    .{"input_audio_buffer.cleared"},
    .{"input_audio_buffer.speech_started"},
    .{"input_audio_buffer.speech_stopped"},
    .{"conversation.item.input_audio_transcription.delta"},
    .{"conversation.item.input_audio_transcription.segment"},
    .{"conversation.item.input_audio_transcription.completed"},
});

/// `session` as OpenAI takes it: its model by `id`, without `provider`, OpenAI's own options joining it.
pub fn wireSession(arena: Allocator, model_id: []const u8, session: *const realtime.Session) Allocator.Error!std.json.Value {
    var value = try foundation.json.toValue(arena, session);
    _ = value.object.orderedRemove("provider");
    const transcription = value.object.getPtr("audio").?.object.getPtr("input").?.object.getPtr("transcription").?;
    try transcription.object.put(arena, "model", .{ .string = model_id });
    const options = if (session.provider) |provider| try json.optionsOf(arena, provider.options, "openai") else null;
    if (options) |own| {
        var it = own.iterator();
        while (it.next()) |entry| try value.object.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    }
    return value;
}

fn connect(call: *Call, model: *const Model, session: *const realtime.Session, gpa: Allocator) Error!seam.RealtimeOpening {
    const update = try foundation.json.encode(call.arena, .{ .type = "session.update", .session = try wireSession(call.arena, model.id, session) });
    return opening(call, model, gpa, "intent=transcription", update);
}

/// The sideband of the call `call_id`, which sends no audio.
fn connectSideband(call: *Call, model: *const Model, call_id: []const u8, gpa: Allocator) Error!seam.RealtimeOpening {
    const query = try foundation.oauth.formEncoded(call.arena, &.{.{ "call_id", call_id }});
    return opening(call, model, gpa, query, null);
}

fn opening(call: *Call, model: *const Model, gpa: Allocator, query: []const u8, update: ?[]const u8) Error!seam.RealtimeOpening {
    const key = try call.apiKey();
    const wire = try Wire.create(gpa, model.id, try model.reference(call.arena), update);
    return .{
        .url = try session_.socketUrl(call.arena, call.baseUrl(openai.base_url), "/realtime", query),
        .headers = try call.arena.dupe(foundation.http.Header, &.{.{ .name = "authorization", .value = try call.arena.print("Bearer {s}", .{key}) }}),
        .wire = wire.wire(),
    };
}

/// Makes a session for a client from its offer: the answer is the body, and the call's id the end of its `Location`.
fn createCall(call: *Call, model: *const Model, params: *const realtime.CallCreateParams) Error!realtime.CallCreateResponse {
    const session = try foundation.json.encode(call.arena, try wireSession(call.arena, model.id, &params.session));
    const form = try foundation.multipart.encode(call.arena, try call.host.boundary(call.arena), &.{
        .{ .name = "sdp", .value = params.sdp, .content_type = "application/sdp" },
        .{ .name = "session", .value = session, .content_type = "application/json" },
    });
    const response = try media.send(call, .{ .path = "/realtime/calls", .accept = "application/sdp", .body = form.bytes, .content_type = form.content_type });
    const location = response.header("location") orelse "";
    const call_id = location[if (std.mem.lastIndexOfScalar(u8, location, '/')) |at| at + 1 else 0..];
    const answer = try @import("../openrouter/media.zig").bytesBody(call, response, "application/sdp");
    if (call_id.len == 0 or std.mem.eql(u8, answer.media_type, "application/json")) {
        var failure = try failure_.Failure.format(call.arena, .invalid_response, "OpenAI's answer to a call names no call by its Location, or holds no SDP", .{});
        failure.body = answer.data;
        return call.fail(failure);
    }
    return .{ .call_id = try call.arena.dupe(u8, call_id), .sdp = answer.data };
}

/// How a session speaks over OpenAI's WebSocket: sending its `session.update` as it opens, or nothing for a sideband,
/// which sends no audio; once closing, settled when every commit sent and every item committed have been answered.
/// Each commit goes with an id, Octoii's where the client gives none, by which an `error` answering it is known.
const Wire = struct {
    gpa: Allocator,
    strings_arena: std.heap.ArenaAllocator,
    model_id: []const u8,
    reference: []const u8,
    /// The `session.update` it opens with; none for a sideband.
    update: ?[]const u8,
    ids: session_.Ids = .{},
    /// The items committed and not yet ended, and the commits sent and not yet answered.
    pending: std.StringArrayHashMapUnmanaged(void) = .empty,
    commits: std.ArrayList([]const u8) = .empty,
    appended: bool = false,

    fn create(gpa: Allocator, model_id: []const u8, reference: []const u8, update: ?[]const u8) Allocator.Error!*Wire {
        const made = try gpa.create(Wire);
        errdefer gpa.destroy(made);
        made.* = .{ .gpa = gpa, .strings_arena = .init(gpa), .model_id = undefined, .reference = undefined, .update = null };
        errdefer made.strings_arena.deinit();
        const arena = made.strings_arena.allocator();
        made.model_id = try arena.dupe(u8, model_id);
        made.reference = try arena.dupe(u8, reference);
        if (update) |given| made.update = try arena.dupe(u8, given);
        return made;
    }

    fn wire(self: *Wire) session_.Wire {
        return .{
            .context = self,
            .vtable = &.{ .start = start, .read = read, .write = write, .close = close, .settled = settled, .ended = ended, .deinit = deinit },
            .opens_on = if (self.update == null) null else .session_updated,
        };
    }

    fn of(context: *anyopaque) *Wire {
        return @ptrCast(@alignCast(context));
    }

    fn start(context: *anyopaque, out: *Out) WireError!void {
        const self = of(context);
        if (self.update) |update| try out.send(.{ .text = update });
    }

    fn read(context: *anyopaque, out: *Out, message: foundation.websocket.Message) WireError!void {
        const self = of(context);
        const text = switch (message) {
            .text => |given| given,
            .binary => return out.brokenBy("OpenAI sent a message that is no JSON event", .{}),
        };
        const value = std.json.parseFromSliceLeaky(std.json.Value, out.arena, text, .{ .allocate = .alloc_always }) catch return out.brokenBy("OpenAI sent a message that is no JSON event", .{});
        const kind = json.textOf(value, "type") orelse return out.brokenBy("OpenAI sent a message that is no JSON event", .{});
        try self.track(kind, value);
        return self.serverEvents(out, kind, value);
    }

    /// Keeps count of what is yet to be answered: the items committed until they end, the commits until answered.
    fn track(self: *Wire, kind: []const u8, value: std.json.Value) Allocator.Error!void {
        const item = json.textOf(value, "item_id");
        if (std.mem.eql(u8, kind, "input_audio_buffer.committed")) if (item) |id| {
            if (!self.pending.contains(id)) {
                try self.pending.ensureUnusedCapacity(self.gpa, 1);
                self.pending.putAssumeCapacity(try self.gpa.dupe(u8, id), {});
            }
            if (self.commits.items.len > 0) self.gpa.free(self.commits.orderedRemove(0));
        };
        if (std.mem.endsWith(u8, kind, ".completed") or std.mem.endsWith(u8, kind, ".failed")) if (item) |id| {
            if (self.pending.fetchOrderedRemove(id)) |removed| self.gpa.free(removed.key);
        };
        if (!std.mem.eql(u8, kind, "error")) return;
        const answered = if (value.object.get("error")) |given| json.textOf(given, "event_id") else null;
        for (self.commits.items, 0..) |commit, index| if (answered != null and std.mem.eql(u8, commit, answered.?)) {
            self.gpa.free(self.commits.orderedRemove(index));
            break;
        };
    }

    /// The vocabulary's events an event of OpenAI's stands for: those of the subset, the session's model by reference
    /// and each error classified.
    fn serverEvents(self: *Wire, out: *Out, kind: []const u8, given: std.json.Value) WireError!void {
        var value = given;
        if (std.mem.eql(u8, kind, "session.created") or std.mem.eql(u8, kind, "session.updated")) {
            try self.referencedSession(out.arena, &value);
        } else if (std.mem.eql(u8, kind, "error") or std.mem.eql(u8, kind, "conversation.item.input_audio_transcription.failed")) {
            try classified(out.arena, &value);
        } else if (!passed.has(kind)) return;
        const event = foundation.json.decodeValue(realtime.ServerEvent, out.arena, value) catch {
            return out.brokenBy("OpenAI sent a {s} event outside the vocabulary: {s}", .{ kind, try foundation.json.encode(out.arena, value) });
        };
        try out.give(event);
    }

    /// The session as OpenAI gives it, its model, asked for by its `id`, by its reference where it names one.
    fn referencedSession(self: *Wire, arena: Allocator, value: *std.json.Value) Allocator.Error!void {
        const session = value.object.getPtr("session") orelse return;
        if (session.* != .object) return;
        if (!session.object.contains("type")) try session.object.put(arena, "type", .{ .string = "transcription" });
        const audio = session.object.getPtr("audio") orelse return;
        if (audio.* != .object) return;
        const input = audio.object.getPtr("input") orelse return;
        if (input.* != .object) return;
        const transcription = input.object.getPtr("transcription") orelse return;
        if (transcription.* != .object or json.textOf(transcription.*, "model") == null) return;
        try transcription.object.put(arena, "model", .{ .string = self.reference });
    }

    fn write(context: *anyopaque, out: *Out, event: realtime.ClientEvent) WireError!void {
        const self = of(context);
        if (self.update == null and event != .session_update) {
            return out.give(try session_.errorEvent(out.arena, &self.ids, .invalid_request, "A sideband sends no audio: the client's connection carries it", .{}));
        }
        switch (event) {
            .session_update => |update| {
                if (!std.mem.eql(u8, update.session.model(), self.reference)) {
                    return out.give(try session_.errorEvent(out.arena, &self.ids, .invalid_request, "A session.update names the session's own model", .{}));
                }
                const session = try wireSession(out.scratch_arena, self.model_id, &update.session);
                try out.send(.{ .text = try foundation.json.encode(out.scratch_arena, .{ .type = "session.update", .session = session, .event_id = update.event_id }) });
            },
            .append => |append| {
                self.appended = true;
                try out.send(.{ .text = try foundation.json.encode(out.scratch_arena, append) });
            },
            .commit => |commit| try self.sendCommit(out, commit.event_id),
            .clear => |clear| {
                self.appended = false;
                try out.send(.{ .text = try foundation.json.encode(out.scratch_arena, clear) });
            },
        }
    }

    /// Commits the buffer under `event_id`, Octoii's where none is given, kept until it is answered.
    fn sendCommit(self: *Wire, out: *Out, event_id: ?[]const u8) Allocator.Error!void {
        const id = event_id orelse try out.scratch_arena.print("octoii_commit_{s}", .{try self.ids.event(out.scratch_arena)});
        try self.commits.ensureUnusedCapacity(self.gpa, 1);
        self.commits.appendAssumeCapacity(try self.gpa.dupe(u8, id));
        self.appended = false;
        try out.send(.{ .text = try foundation.json.encode(out.scratch_arena, realtime.Commit{ .event_id = id }) });
    }

    fn close(context: *anyopaque, out: *Out) WireError!void {
        const self = of(context);
        if (self.appended) try self.sendCommit(out, null);
    }

    fn settled(context: *anyopaque) bool {
        const self = of(context);
        return self.commits.items.len == 0 and self.pending.count() == 0;
    }

    fn ended(_: *anyopaque, _: *Out) WireError!void {}

    fn deinit(context: *anyopaque) void {
        const self = of(context);
        for (self.pending.keys()) |key| self.gpa.free(key);
        self.pending.deinit(self.gpa);
        for (self.commits.items) |commit| self.gpa.free(commit);
        self.commits.deinit(self.gpa);
        self.strings_arena.deinit();
        self.gpa.destroy(self);
    }
};

/// An error as OpenAI's events carry it, its failure classified: by its code, as a text request's, else by its type,
/// else `server`.
fn classified(arena: Allocator, value: *std.json.Value) Allocator.Error!void {
    const given = value.object.getPtr("error");
    var made: std.json.ObjectMap = if (given) |found| (if (found.* == .object) try found.object.clone(arena) else .empty) else .empty;
    const code = json.textOf(.{ .object = made }, "code");
    const type_name = json.textOf(.{ .object = made }, "type");
    const kind: failure_.Kind = (if (code) |known| openai.kindOf(known) else null) orelse
        (if (type_name) |known| openai.kindOf(known) else null) orelse
        (if (type_name != null and std.mem.eql(u8, type_name.?, "invalid_request_error")) .invalid_request else .server);
    if (type_name == null) try made.put(arena, "type", .{ .string = "server_error" });
    if (json.textOf(.{ .object = made }, "message") == null) try made.put(arena, "message", .{ .string = "OpenAI's session failed without saying why" });
    try made.put(arena, "octoii", try foundation.json.toValue(arena, vocabulary.extensions.FailureExtension{ .kind = kind, .retryable = failure_.retryableKind(kind) }));
    try value.object.put(arena, "error", .{ .object = made });
}
