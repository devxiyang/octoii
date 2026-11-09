//! What Google's kinds share: the Gemini API's Interactions API at `/interactions`, a request sent as a stream with
//! `store: false`, so that Google keeps nothing, and Google's options set over its body, an object's members one by
//! one. Its server-sent events are read as the interaction's creation, each step's start, deltas and stop, and the
//! status and usage it ends with; an `error` event, an interaction that failed or was cancelled, or a stream that ends
//! before the interaction does, fails the call. A `done` event, or `[DONE]`, says nothing more.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const foundation = @import("foundation");
const seam = @import("../../driver.zig");
const Call = seam.Call;
const failure_ = @import("../../failure.zig");
const Failure = failure_.Failure;
const Error = failure_.Error;
const Kind = failure_.Kind;
const http = @import("../../wire/http.zig");

/// Where the Gemini API is.
pub const base_url = "https://generativelanguage.googleapis.com/v1beta";

/// Tokens of one modality, such as `image` or `audio`.
pub const ModalityTokens = []const struct { modality: ?[]const u8 = null, tokens: ?u64 = null };

/// What an interaction used, as Google counts it: the output's tokens leave out the thoughts'.
pub const Usage = struct {
    total_input_tokens: ?u64 = null,
    input_tokens_by_modality: ?ModalityTokens = null,
    total_cached_tokens: ?u64 = null,
    cached_tokens_by_modality: ?ModalityTokens = null,
    total_output_tokens: ?u64 = null,
    output_tokens_by_modality: ?ModalityTokens = null,
    total_tool_use_tokens: ?u64 = null,
    total_thought_tokens: ?u64 = null,
    total_tokens: ?u64 = null,
    /// How many times each of Google's grounding tools ran, such as `google_search`.
    grounding_tool_count: ?[]const struct { type: ?[]const u8 = null, count: ?u64 = null } = null,
};

/// The tokens of `modality` among `tokens`.
pub fn tokensOf(tokens: ?ModalityTokens, modality: []const u8) u64 {
    var total: u64 = 0;
    for (tokens orelse &.{}) |each| if (each.modality) |named| if (std.mem.eql(u8, named, modality)) {
        total += each.tokens orelse 0;
    };
    return total;
}

/// A content block as Google writes it: text with its annotations, or an image, audio, a document or a video.
pub const Content = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    annotations: ?[]const Value = null,
    data: ?[]const u8 = null,
    uri: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
    sample_rate: ?u32 = null,
};

/// A step as `step.start` names it, by its `type`, with what it may already carry.
pub const Step = struct {
    type: []const u8,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: ?Value = null,
    call_id: ?[]const u8 = null,
    signature: ?[]const u8 = null,
    summary: ?[]const Content = null,
    content: ?[]const Content = null,
    result: ?Value = null,
};

/// More of a step, by its `type`: text, an image or audio made, a thought's summary or signature, a part of a call's
/// arguments as JSON text, citations on the text, or what a search of Google's ran and found.
pub const Delta = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    annotations: ?[]const Value = null,
    data: ?[]const u8 = null,
    uri: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
    sample_rate: ?u32 = null,
    /// A thought's new summary.
    content: ?Content = null,
    signature: ?[]const u8 = null,
    /// A part of a call's arguments as JSON text, or the queries of a search.
    arguments: ?Value = null,
    result: ?Value = null,

    /// The delta as the content it carries.
    pub fn asContent(delta: Delta) Content {
        return .{ .type = delta.type, .text = delta.text, .annotations = delta.annotations, .data = delta.data, .uri = delta.uri, .mime_type = delta.mime_type, .sample_rate = delta.sample_rate };
    }
};

/// An error as Google writes it, in a refusal's body, an `error` event or a failed interaction.
pub const WireError = struct { code: ?[]const u8 = null, message: ?[]const u8 = null };

const WireInteraction = struct {
    id: ?[]const u8 = null,
    status: ?[]const u8 = null,
    created: ?[]const u8 = null,
    usage: ?Usage = null,
    errors: ?[]const WireError = null,
};

/// The statuses an interaction ends with that are no failure: done, waiting for a function's result, or cut off.
pub const EndStatus = enum { completed, requires_action, incomplete };

/// What an interaction's stream gives.
pub const Event = union(enum) {
    created: struct { id: ?[]const u8, created_s: i64 },
    step_start: struct { index: u32, step: Step },
    step_delta: struct { index: u32, delta: Delta },
    step_stop: u32,
    completed: struct { status: EndStatus, usage: ?Usage },
};

/// The body an interaction is asked with: `body`'s JSON with Google's own options set over it, an object's members one
/// by one, kept nowhere and streamed.
pub fn requestBody(arena: Allocator, body: anytype, options: ?std.json.ObjectMap) Allocator.Error![]const u8 {
    var value = try foundation.json.toValue(arena, body);
    if (options) |own| {
        var it = own.iterator();
        while (it.next()) |entry| {
            const slot = try value.object.getOrPut(arena, entry.key_ptr.*);
            if (slot.found_existing and slot.value_ptr.* == .object and entry.value_ptr.* == .object) {
                var members = entry.value_ptr.object.iterator();
                while (members.next()) |member| try slot.value_ptr.object.put(arena, member.key_ptr.*, member.value_ptr.*);
            } else slot.value_ptr.* = entry.value_ptr.*;
        }
    }
    try value.object.put(arena, "store", .{ .bool = false });
    try value.object.put(arena, "stream", .{ .bool = true });
    return foundation.json.encode(arena, value);
}

/// An interaction's events as its stream gives them.
pub const Reader = struct {
    call: *Call,
    events: http.Events,
    ended: bool = false,

    /// Sends `body` to the Interactions API with the provider's key; `Failed` for a refusal.
    pub fn open(call: *Call, body: []const u8) Error!Reader {
        const key = try call.apiKey();
        const response = try http.send(call, .{
            .method = .POST,
            .url = try call.arena.print("{s}/interactions", .{call.baseUrl(base_url)}),
            .headers = &.{
                .{ .name = "x-goog-api-key", .value = key },
                .{ .name = "accept", .value = "text/event-stream" },
                .{ .name = "content-type", .value = "application/json" },
            },
            .body = body,
        });
        if (response.status < 200 or response.status >= 300) return call.fail(try http.failureOf(call, response, details));
        return .{ .call = call, .events = .init(call, response) };
    }

    /// The next event, null once the interaction has ended; `Failed` for an `error` event, an interaction that ends as
    /// a failure, or a stream that ends before the interaction does.
    pub fn next(reader: *Reader) Error!?Event {
        const call = reader.call;
        while (!reader.ended) {
            const event = try reader.events.next() orelse break;
            if (std.mem.eql(u8, event.event, "done") or std.mem.eql(u8, event.data, "[DONE]")) break;
            const data = try call.arena.dupe(u8, event.data);
            const value = std.json.parseFromSliceLeaky(Value, call.arena, data, .{ .allocate = .alloc_always }) catch null;
            const kind = if (value) |given| (if (given == .object) given.object.get("event_type") else null) else null;
            if (kind == null or kind.? != .string) return reader.invalid("an event that is no event of its Interactions API", data);
            if (try reader.translated(kind.?.string, value.?, data)) |made| return made;
        }
        if (reader.ended) return null;
        return call.failWith(.transport, "The provider's stream ended before the interaction completed", .{});
    }

    pub fn close(reader: *Reader) void {
        reader.events.close();
    }

    /// The event `value`, of `kind`, stands for; null for one ai does not read.
    fn translated(reader: *Reader, kind: []const u8, value: Value, data: []const u8) Error!?Event {
        const call = reader.call;
        if (std.mem.eql(u8, kind, "interaction.created")) {
            const given = try reader.decoded(struct { interaction: WireInteraction }, value, data);
            return .{ .created = .{ .id = given.interaction.id, .created_s = createdSeconds(given.interaction.created, call.nowMs()) } };
        }
        if (std.mem.eql(u8, kind, "step.start")) {
            const given = try reader.decoded(struct { index: u32, step: Step }, value, data);
            return .{ .step_start = .{ .index = given.index, .step = given.step } };
        }
        if (std.mem.eql(u8, kind, "step.delta")) {
            const given = try reader.decoded(struct { index: u32, delta: Delta }, value, data);
            return .{ .step_delta = .{ .index = given.index, .delta = given.delta } };
        }
        if (std.mem.eql(u8, kind, "step.stop")) return .{ .step_stop = (try reader.decoded(struct { index: u32 }, value, data)).index };
        if (std.mem.eql(u8, kind, "interaction.completed")) {
            const given = try reader.decoded(struct { interaction: WireInteraction }, value, data);
            reader.ended = true;
            return .{ .completed = .{ .status = try reader.endStatus(given.interaction, data), .usage = given.interaction.usage } };
        }
        if (std.mem.eql(u8, kind, "error")) {
            const given = try reader.decoded(struct { @"error": ?WireError = null }, value, data);
            return call.fail(try streamFailure(call.arena, given.@"error" orelse .{}, data));
        }
        return null;
    }

    fn decoded(reader: *Reader, comptime T: type, value: Value, data: []const u8) Error!T {
        return foundation.json.decodeValue(T, reader.call.arena, value) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => reader.invalid("an event that is no event of its Interactions API", data),
        };
    }

    fn invalid(reader: *Reader, comptime what: []const u8, data: []const u8) Error {
        var failure: Failure = .init(.invalid_response, "The provider sent " ++ what);
        failure.body = data;
        return reader.call.fail(failure);
    }

    /// The status an interaction ended with where it is no failure; `Failed` for one that failed, as its error's code
    /// says, else as `server`; for one cancelled, as `server`; and for any other, as `invalid_response`.
    fn endStatus(reader: *Reader, interaction: WireInteraction, data: []const u8) Error!EndStatus {
        const call = reader.call;
        const status = interaction.status orelse "";
        if (std.meta.stringToEnum(EndStatus, status)) |ended| return ended;
        const first: ?WireError = if (interaction.errors) |errors| (if (errors.len > 0) errors[0] else null) else null;
        const failed = std.mem.eql(u8, status, "failed");
        if (failed) if (first) |given| return call.fail(try streamFailure(call.arena, given, data));
        const kind: Kind = if (failed or std.mem.eql(u8, status, "cancelled")) .server else .invalid_response;
        const why = if (first) |given| (if (given.message) |message| try call.arena.print(": {s}", .{message}) else "") else "";
        var failure = try Failure.format(call.arena, kind, "The interaction ended {s}{s}", .{ if (status.len == 0) "without a status" else status, why });
        failure.body = data;
        return call.fail(failure);
    }
};

/// What an image or speech interaction gives: its creation, what is made, with whether a thought made it, and its
/// usage.
pub const Made = union(enum) {
    created: i64,
    made: struct { content: Content, thought: bool },
    completed: ?Usage,
};

/// The events of an image or speech interaction: each delta's content, a thought's summary among them, and the usage
/// it ends with; `invalid_response` for an interaction that ends other than `completed`, as what it made is cut off
/// or waits for an answer.
pub const MadeReader = struct {
    reader: Reader,
    /// Which steps are thoughts, by their index.
    thoughts: std.AutoHashMapUnmanaged(u32, bool) = .empty,

    pub fn open(call: *Call, body: []const u8) Error!MadeReader {
        return .{ .reader = try .open(call, body) };
    }

    pub fn next(made: *MadeReader) Error!?Made {
        const call = made.reader.call;
        while (try made.reader.next()) |event| switch (event) {
            .created => |created| return .{ .created = created.created_s },
            .step_start => |start| try made.thoughts.put(call.arena, start.index, std.mem.eql(u8, start.step.type, "thought")),
            .step_stop => {},
            .step_delta => |more| {
                const summary = std.mem.eql(u8, more.delta.type, "thought_summary");
                const thought = summary or (made.thoughts.get(more.index) orelse false);
                const content = if (summary) more.delta.content orelse continue else more.delta.asContent();
                return .{ .made = .{ .content = content, .thought = thought } };
            },
            .completed => |ended| {
                if (ended.status != .completed) return call.failWith(.invalid_response, "The interaction ended {t}", .{ended.status});
                return .{ .completed = ended.usage };
            },
        };
        return null;
    }

    pub fn close(made: *MadeReader) void {
        made.reader.close();
    }
};

/// When an interaction was created, in Unix seconds, by its time in ISO 8601, else by `now_ms`.
pub fn createdSeconds(created: ?[]const u8, now_ms: i64) i64 {
    const given = created orelse return @divFloor(now_ms, 1000);
    return isoSeconds(given) orelse @divFloor(now_ms, 1000);
}

/// The Unix seconds of a time written `YYYY-MM-DDTHH:MM:SS`, its fraction and a `Z` after it ignored.
fn isoSeconds(text: []const u8) ?i64 {
    if (text.len < 19 or text[4] != '-' or text[7] != '-' or text[10] != 'T' or text[13] != ':' or text[16] != ':') return null;
    const year = std.fmt.parseInt(i64, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, text[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, text[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, text[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, text[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    // Days from the civil date, as Howard Hinnant's algorithm counts them.
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const year_of_era = y - era * 400;
    const shifted: i64 = if (month > 2) month - 3 else month + 9;
    const day_of_year = @divFloor(153 * shifted + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    const days = era * 146097 + day_of_era - 719468;
    return days * 86400 + hour * 3600 + minute * 60 + second;
}

/// The kind of each of Google's error codes the specification's table lists.
const kinds_of_codes = std.StaticStringMap(Kind).initComptime(.{
    .{ "authentication", .auth },                       .{ "permission_denied", .forbidden },
    .{ "payment_required", .quota },                    .{ "rate_limit_exceeded", .rate_limit },
    .{ "quota_exceeded", .rate_limit },                 .{ "too_many_requests", .rate_limit },
    .{ "safety", .content_filter },                     .{ "recitation", .content_filter },
    .{ "language", .content_filter },                   .{ "prohibited_content", .content_filter },
    .{ "spii", .content_filter },                       .{ "blocklist", .content_filter },
    .{ "jailbreak", .content_filter },                  .{ "content_blocked", .content_filter },
    .{ "missing_thought_signature", .invalid_request }, .{ "invalid_request", .invalid_request },
    .{ "failed_precondition", .invalid_request },       .{ "out_of_range", .invalid_request },
    .{ "parameter_unknown", .invalid_request },         .{ "not_found", .invalid_request },
    .{ "model_not_found", .invalid_request },           .{ "malformed_function_call", .invalid_response },
    .{ "malformed_tool_call", .invalid_response },      .{ "unexpected_tool_call", .invalid_response },
    .{ "too_many_tool_calls", .invalid_response },      .{ "no_image", .invalid_response },
    .{ "api_error", .server },                          .{ "service_unavailable", .server },
    .{ "deadline_exceeded", .server },                  .{ "aborted", .server },
    .{ "cancelled", .server },                          .{ "unimplemented", .server },
});

/// An error's code, the end of the address Google may write it as.
fn codeOf(given: WireError) ?[]const u8 {
    const code = given.code orelse return null;
    const slash = std.mem.lastIndexOfScalar(u8, code, '/') orelse return code;
    return code[slash + 1 ..];
}

/// The kind a code stands for, as the table says, an image blocked as `content_filter`; an invalid request, or a code
/// the table does not list, by what its message says of the input's tokens or the request's size.
pub fn kindOf(arena: Allocator, code: ?[]const u8, message: ?[]const u8) Allocator.Error!?Kind {
    const listed: ?Kind = if (code) |given| kinds_of_codes.get(given) orelse (if (std.mem.startsWith(u8, given, "image_")) Kind.content_filter else null) else null;
    if (listed) |kind| if (kind != .invalid_request) return kind;
    const lowered = try std.ascii.allocLowerString(arena, message orelse "");
    const counted = std.mem.indexOf(u8, lowered, "input token count");
    const too_many = (counted != null and std.mem.indexOf(u8, lowered[counted.?..], "exceeds") != null) or
        std.mem.indexOf(u8, lowered, "exceeds the maximum number of tokens") != null or
        std.mem.indexOf(u8, lowered, "too many tokens") != null;
    if (too_many) return .context_overflow;
    for ([_][]const u8{ "payload size exceeds", "request payload size", "request entity too large", "too large" }) |words| {
        if (std.mem.indexOf(u8, lowered, words) != null) return .payload_too_large;
    }
    return listed;
}

/// What Google's body says of a refusal before the stream: its kind where its code or message tell it, its message
/// and code.
pub fn details(arena: Allocator, body: []const u8) ?http.Details {
    const parsed = foundation.json.decode(struct { @"error": WireError }, arena, body) catch return null;
    const code = codeOf(parsed.@"error");
    return .{ .kind = kindOf(arena, code, parsed.@"error".message) catch return null, .message = parsed.@"error".message, .code = code };
}

/// The failure an error in the stream, or of an interaction that failed, stands for: its kind as its code says, else
/// `server`, as no HTTP status says more once the stream has begun.
pub fn streamFailure(arena: Allocator, given: WireError, body: []const u8) Allocator.Error!Failure {
    const code = codeOf(given);
    var failure: Failure = .init(try kindOf(arena, code, given.message) orelse .server, given.message orelse "The provider's stream failed without saying why");
    failure.code = code;
    failure.body = body;
    return failure;
}

test "Google's codes are classified by its table, an image blocked as content_filter, and an invalid request by its words" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    try std.testing.expectEqual(Kind.content_filter, (try kindOf(arena, "image_safety", null)).?);
    try std.testing.expectEqual(Kind.context_overflow, (try kindOf(arena, "invalid_request", "The input token count (1200000) exceeds the maximum")).?);
    try std.testing.expectEqual(Kind.payload_too_large, (try kindOf(arena, "invalid_request", "Request payload size exceeds the limit")).?);
    try std.testing.expectEqual(Kind.invalid_request, (try kindOf(arena, "invalid_request", "bad")).?);
    try std.testing.expectEqual(null, try kindOf(arena, "something_new", "bad"));
    try std.testing.expectEqualStrings("safety", codeOf(.{ .code = "errors/safety" }).?);
    try std.testing.expectEqualStrings("safety", codeOf(.{ .code = "safety" }).?);
    try std.testing.expectEqual(@as(i64, 1_793_275_200), createdSeconds("2026-10-29T12:00:00Z", 0));
}
