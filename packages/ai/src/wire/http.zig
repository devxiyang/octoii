//! What every provider's protocol shares over HTTP: a request sent through the host with its provider's headers and
//! its call's wait; a failure classified by its status, its headers and what its body says; server-sent events read as
//! they arrive; JSON read as a type. Each turns what the host's HTTP fails with into the call's failure.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const http = foundation.http;
const sse = foundation.sse;
const failure_ = @import("../failure.zig");
const Failure = failure_.Failure;
const Error = failure_.Error;
const Kind = failure_.Kind;
const Call = @import("../driver.zig").Call;

/// The most of a failure's body that is read.
const failure_body_max = 1 << 20;

/// Sends `request` through the host, with the provider's headers over the driver's and the call's wait, and gives
/// the response whatever its status; `transport`, `aborted` or `timeout` where it does not get through.
pub fn send(call: *Call, request: http.Request) Error!http.Response {
    var sent = request;
    sent.headers = try withProviderHeaders(call, request.headers);
    if (sent.wait == null) sent.wait = call.wait;
    return call.host.network().send(sent) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Transport => call.failWith(.transport, "The request to {s} did not get through", .{shownAddress(request.url)}),
        error.Canceled => call.failWith(.aborted, "The request was aborted", .{}),
        error.Timeout => call.failWith(.timeout, "No response began within {d} ms", .{if (sent.wait) |wait| wait.head_ms else 0}),
    };
}

/// `headers`, but each the provider sets in their place.
fn withProviderHeaders(call: *Call, headers: []const http.Header) Allocator.Error![]const http.Header {
    const own = call.provider.settings.headers;
    if (own.len == 0) return headers;
    var merged: std.ArrayList(http.Header) = .empty;
    for (headers) |header| if (http.find(own, header.name) == null) try merged.append(call.arena, header);
    try merged.appendSlice(call.arena, own);
    return merged.items;
}

/// What a protocol reads of a failure from its body: the provider's own kind, message, retryability, code and wait,
/// each where it says.
pub const Details = struct {
    kind: ?Kind = null,
    message: ?[]const u8 = null,
    retryable: ?bool = null,
    code: ?[]const u8 = null,
    retry_after_ms: ?u64 = null,
    /// For a quota used up: when it is given again, in milliseconds since the epoch, and the window it is counted over.
    reset_at_ms: ?i64 = null,
    window_minutes: ?u32 = null,
};

/// Reads the provider's own account of a failure from its body, in `arena`; null where it gives none.
pub const DetailsOf = *const fn (arena: Allocator, body: []const u8) ?Details;

/// The failure a response that is not ok stands for, its body read and the response closed: its kind by its status,
/// unless `details` says, with the wait its headers ask for, else the one its body gives, else for a rate limit the
/// reset of its spent limits; retryable as its `x-should-retry` says, else as its kind is; a quota used up given again
/// when its body says, else once that wait is over.
pub fn failureOf(call: *Call, response: http.Response, details: ?DetailsOf) Error!Failure {
    defer response.close();
    const body = response.body.allocRemaining(call.arena, .limited(failure_body_max)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadFailed, error.StreamTooLong => "",
    };
    const own: Details = if (details) |read| read(call.arena, body) orelse .{} else .{};
    const kind = own.kind orelse kindOfStatus(response.status);
    const now_ms = call.nowMs();
    const said = retryAfterMs(response.headers, now_ms) orelse own.retry_after_ms;
    const reset_at_ms = own.reset_at_ms orelse if (kind == .quota) if (said) |wait| now_ms + @as(i64, @intCast(wait)) else null else null;
    return .{
        .kind = kind,
        .message = own.message orelse if (body.len == 0)
            try call.arena.print("The provider answered {d}", .{response.status})
        else
            try call.arena.print("The provider answered {d}: {s}", .{ response.status, body }),
        .retryable = own.retryable orelse shouldRetry(response.headers) orelse failure_.retryableKind(kind),
        .retry_after_ms = said orelse if (kind == .rate_limit) rateLimitResetMs(response.headers) else null,
        .status = response.status,
        .code = own.code,
        .body = body,
        .reset_at_ms = reset_at_ms,
        .window_minutes = own.window_minutes,
    };
}

/// The kind of failure an HTTP status stands for, before a protocol reads the provider's own codes.
pub fn kindOfStatus(status: u16) Kind {
    return switch (status) {
        401 => .auth,
        402 => .quota,
        403 => .forbidden,
        408 => .timeout,
        413 => .payload_too_large,
        429 => .rate_limit,
        else => if (status >= 500) .server else .invalid_request,
    };
}

/// Whether the provider says to try again, by its `x-should-retry`; null where it does not say.
fn shouldRetry(headers: []const http.Header) ?bool {
    const said = std.mem.trim(u8, http.find(headers, "x-should-retry") orelse return null, " ");
    if (std.ascii.eqlIgnoreCase(said, "true")) return true;
    if (std.ascii.eqlIgnoreCase(said, "false")) return false;
    return null;
}

/// How long a response asks to wait before trying again: its `retry-after-ms`, else its `retry-after` in seconds or
/// as an HTTP date, counted from `now_ms` and never below 0.
pub fn retryAfterMs(headers: []const http.Header, now_ms: i64) ?u64 {
    if (http.find(headers, "retry-after-ms")) |text| if (delay(text)) |ms| return roundedMs(ms);
    const text = http.find(headers, "retry-after") orelse return null;
    if (delay(text)) |seconds| return roundedMs(seconds * std.time.ms_per_s);
    const date_ms = httpDateMs(std.mem.trim(u8, text, " ")) orelse return null;
    return @intCast(@max(0, date_ms - now_ms));
}

/// A delay of whole or decimal units; null for another text.
fn delay(text: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return null;
    for (trimmed) |char| if (!std.ascii.isDigit(char) and char != '.') return null;
    return std.fmt.parseFloat(f64, trimmed) catch null;
}

fn roundedMs(ms: f64) u64 {
    return @intFromFloat(@ceil(ms));
}

/// How long a rate limit lasts by its `x-ratelimit-reset-*` headers: the latest reset of the limits whose
/// `x-ratelimit-remaining-*` say they are spent, or of all of them where none says so; null where it gives none.
pub fn rateLimitResetMs(headers: []const http.Header) ?u64 {
    const reset = "x-ratelimit-reset-";
    var latest_spent: ?f64 = null;
    var latest: ?f64 = null;
    for (headers) |header| {
        if (header.name.len <= reset.len or !std.ascii.startsWithIgnoreCase(header.name, reset)) continue;
        const ms = goDurationMs(std.mem.trim(u8, header.value, " ")) orelse continue;
        latest = @max(latest orelse ms, ms);
        var name_buffer: [128]u8 = undefined;
        const remaining_name = std.fmt.bufPrint(&name_buffer, "x-ratelimit-remaining-{s}", .{header.name[reset.len..]}) catch continue;
        const remaining = http.find(headers, remaining_name) orelse continue;
        const left = std.fmt.parseFloat(f64, std.mem.trim(u8, remaining, " ")) catch continue;
        if (left <= 0) latest_spent = @max(latest_spent orelse ms, ms);
    }
    return roundedMs(latest_spent orelse latest orelse return null);
}

/// A duration as Go writes it, such as `6m0s`, `1.5s` or `20ms`, in ms; null for another text.
fn goDurationMs(text: []const u8) ?f64 {
    if (text.len == 0) return null;
    var total: f64 = 0;
    var at: usize = 0;
    while (at < text.len) {
        const start = at;
        while (at < text.len and (std.ascii.isDigit(text[at]) or text[at] == '.')) at += 1;
        if (at == start) return null;
        const amount = std.fmt.parseFloat(f64, text[start..at]) catch return null;
        const units = [_]struct { name: []const u8, ms: f64 }{
            .{ .name = "ms", .ms = 1 },        .{ .name = "us", .ms = 0.001 },    .{ .name = "\u{b5}s", .ms = 0.001 },
            .{ .name = "ns", .ms = 0.000001 }, .{ .name = "h", .ms = 3_600_000 }, .{ .name = "m", .ms = 60_000 },
            .{ .name = "s", .ms = 1_000 },
        };
        const unit = for (units) |unit| {
            if (std.mem.startsWith(u8, text[at..], unit.name)) break unit;
        } else return null;
        total += amount * unit.ms;
        at += unit.name.len;
    }
    return total;
}

/// The time an HTTP date names in its preferred form, such as `Wed, 21 Oct 2026 07:28:00 GMT`, in ms since the
/// epoch; null for another text.
fn httpDateMs(text: []const u8) ?i64 {
    if (text.len != 29 or text[3] != ',' or !std.mem.endsWith(u8, text, " GMT")) return null;
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const month = for (months, 1..) |name, number| {
        if (std.mem.eql(u8, text[8..11], name)) break number;
    } else return null;
    const day = std.fmt.parseInt(u32, text[5..7], 10) catch return null;
    const year = std.fmt.parseInt(i32, text[12..16], 10) catch return null;
    const hours = std.fmt.parseInt(i64, text[17..19], 10) catch return null;
    const minutes = std.fmt.parseInt(i64, text[20..22], 10) catch return null;
    const seconds = std.fmt.parseInt(i64, text[23..25], 10) catch return null;
    const days = daysFromCivil(year, @intCast(month), day);
    return ((days * 24 + hours) * 60 + minutes) * 60_000 + seconds * 1000;
}

/// The days from 1970-01-01 to a date of the proleptic Gregorian calendar.
fn daysFromCivil(year: i32, month: u32, day: u32) i64 {
    const y: i64 = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const year_of_era = y - era * 400;
    const shifted: i64 = if (month > 2) month - 3 else month + 9;
    const day_of_year = @divFloor(153 * shifted + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

/// An address as a failure's message names it: without its query, which may hold a key.
pub fn shownAddress(url: []const u8) []const u8 {
    return url[0 .. std.mem.indexOfAny(u8, url, "?#") orelse url.len];
}

/// The failure a read of `response`'s body that failed stands for, as the host's HTTP says.
pub fn readFailure(call: *Call, response: http.Response) Error {
    return switch (response.failure()) {
        error.Transport => call.failWith(.transport, "The provider's stream broke off", .{}),
        error.Canceled => call.failWith(.aborted, "The request was aborted", .{}),
        error.Timeout => call.failWith(.timeout, "The response fell silent for {d} ms", .{if (call.wait) |wait| wait.idle_ms else 0}),
    };
}

/// The server-sent events of a response's body, as they arrive, each failure of its reading the call's.
pub const Events = struct {
    call: *Call,
    response: http.Response,
    reader: sse.Reader,

    pub fn init(call: *Call, response: http.Response) Events {
        return .{ .call = call, .response = response, .reader = .init(call.arena, response.body) };
    }

    /// The next event, or null at the end of the body.
    pub fn next(events: *Events) Error!?sse.Event {
        return events.reader.next() catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ReadFailed => readFailure(events.call, events.response),
        };
    }

    pub fn close(events: *Events) void {
        events.reader.deinit();
        events.response.close();
    }
};

/// `text` read as JSON of `T`, such as an event's data; `invalid_response`, naming `what`, where it is not.
pub fn parse(comptime T: type, call: *Call, text: []const u8, what: []const u8) Error!T {
    return foundation.json.decode(T, call.arena, text) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => {
            var failure = try Failure.format(call.arena, .invalid_response, "The provider's {s} is not as expected: {t}", .{ what, err });
            failure.body = text;
            return call.fail(failure);
        },
    };
}

test "a status stands for a kind of failure" {
    try std.testing.expectEqual(Kind.auth, kindOfStatus(401));
    try std.testing.expectEqual(Kind.quota, kindOfStatus(402));
    try std.testing.expectEqual(Kind.rate_limit, kindOfStatus(429));
    try std.testing.expectEqual(Kind.server, kindOfStatus(529));
    try std.testing.expectEqual(Kind.invalid_request, kindOfStatus(400));
}

test "a wait is read from retry-after-ms, then retry-after in seconds or as a date" {
    const now: i64 = 1_793_260_800_000;
    try std.testing.expectEqual(@as(?u64, 1500), retryAfterMs(&.{.{ .name = "Retry-After-Ms", .value = "1500" }}, now));
    try std.testing.expectEqual(@as(?u64, 2500), retryAfterMs(&.{.{ .name = "retry-after", .value = "2.5" }}, now));
    // 1793260800 is Thu, 29 Oct 2026 08:00:00 GMT.
    try std.testing.expectEqual(@as(?u64, 30_000), retryAfterMs(&.{.{ .name = "retry-after", .value = "Thu, 29 Oct 2026 08:00:30 GMT" }}, now));
    try std.testing.expectEqual(@as(?u64, 0), retryAfterMs(&.{.{ .name = "retry-after", .value = "Thu, 29 Oct 2026 07:00:00 GMT" }}, now));
    try std.testing.expectEqual(null, retryAfterMs(&.{.{ .name = "retry-after", .value = "soon" }}, now));
}

test "a rate limit lasts until the latest reset of its spent limits, else of all" {
    try std.testing.expectEqual(@as(?u64, 6000), rateLimitResetMs(&.{
        .{ .name = "x-ratelimit-reset-requests", .value = "6s" },
        .{ .name = "x-ratelimit-remaining-requests", .value = "0" },
        .{ .name = "x-ratelimit-reset-tokens", .value = "1m30s" },
        .{ .name = "x-ratelimit-remaining-tokens", .value = "4000" },
    }));
    try std.testing.expectEqual(@as(?u64, 90_020), rateLimitResetMs(&.{
        .{ .name = "x-ratelimit-reset-requests", .value = "20ms" },
        .{ .name = "x-ratelimit-reset-tokens", .value = "1m30.02s" },
    }));
    try std.testing.expectEqual(null, rateLimitResetMs(&.{.{ .name = "x-ratelimit-reset-tokens", .value = "later" }}));
}

test "an address is shown without its query" {
    try std.testing.expectEqualStrings("https://example.com/v1/models", shownAddress("https://example.com/v1/models?key=secret"));
}

/// The largest file ai fetches from its address.
pub const fetched_file_max = 32 << 20;

/// A file fetched from its address: the type its `Content-Type` names, or `application/octet-stream`, and its bytes.
pub const Fetched = struct { media_type: []const u8, data: []const u8 };

/// The file at `url`, at most `fetched_file_max` of it; `invalid_request`, saying which file and why, where it cannot be
/// fetched or is larger. It checks nothing of the file's type.
pub fn fetchFile(call: *Call, url: []const u8) Error!Fetched {
    const shown = shownAddress(url);
    var sent = call.host.network().send(.{ .url = url, .headers = try withProviderHeaders(call, &.{}) }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return call.failWith(.aborted, "The request was aborted", .{}),
        else => return call.failWith(.invalid_request, "The file at {s} cannot be fetched: {t}", .{ shown, err }),
    };
    defer sent.close();
    if (sent.status < 200 or sent.status >= 300) return call.failWith(.invalid_request, "The file at {s} cannot be fetched: its server answered {d}", .{ shown, sent.status });
    if (sent.header("content-length")) |length| if ((std.fmt.parseInt(u64, std.mem.trim(u8, length, " "), 10) catch 0) > fetched_file_max) {
        return call.failWith(.invalid_request, "The file at {s} cannot be fetched: it is larger than {d} bytes", .{ shown, fetched_file_max });
    };
    const data = sent.body.allocRemaining(call.arena, .limited(fetched_file_max + 1)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return call.failWith(.invalid_request, "The file at {s} cannot be fetched: it is larger than {d} bytes", .{ shown, fetched_file_max }),
        error.ReadFailed => return call.failWith(.invalid_request, "The file at {s} cannot be fetched: it broke off", .{shown}),
    };
    const given = sent.header("content-type") orelse "";
    const bare = std.mem.trim(u8, given[0 .. std.mem.indexOfScalar(u8, given, ';') orelse given.len], " ");
    return .{ .media_type = if (bare.len == 0) "application/octet-stream" else try std.ascii.allocLowerString(call.arena, bare), .data = data };
}
