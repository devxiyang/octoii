//! HTTP as the libraries take it: an interface the host implements — the node over its client, a browser over
//! `fetch`, a test over a recording — so that a library sends requests and does no I/O of its own. A call blocks until
//! the response's head arrives; its body is read as it streams. A host that cancels the task the call runs on ends it
//! `Canceled`; one whose wait runs out ends it `Timeout`.
const std = @import("std");

pub const Method = std.http.Method;
pub const Header = std.http.Header;

/// A request: where to, how, with which headers, and its body, sent whole.
pub const Request = struct {
    method: Method = .GET,
    url: []const u8,
    headers: []const Header = &.{},
    /// The body, its type named among `headers`; none for a request without one.
    body: ?[]const u8 = null,
    /// How long the host waits; none, as long as the host's own bounds allow.
    wait: ?Wait = null,
};

/// How long a host waits for a response: for its head, then between reads of its body.
pub const Wait = struct {
    head_ms: u64,
    idle_ms: u64,
};

/// Why a request did not get through, or its body broke off: the network failed, the host canceled the task, or the
/// request's wait ran out.
pub const Error = error{ Transport, Canceled, Timeout };

pub const SendError = Error || error{OutOfMemory};

/// A response: its status and headers, and its body as it arrives. What it holds is the host's until it is closed.
pub const Response = struct {
    status: u16,
    /// The headers as the server sent them; `header` finds one by its name in any case.
    headers: []const Header,
    /// The body as it streams; a read that fails with `ReadFailed` leaves why in `failure`.
    body: *std.Io.Reader,
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Why the body's last read failed.
        failure: *const fn (context: *anyopaque) Error,
        /// Lets the response go, its body read or not.
        close: *const fn (context: *anyopaque) void,
    };

    /// The value of the header `name`, in any case; the first where several are sent.
    pub fn header(response: Response, name: []const u8) ?[]const u8 {
        return find(response.headers, name);
    }

    /// Why the body's last read failed with `ReadFailed`.
    pub fn failure(response: Response) Error {
        return response.vtable.failure(response.context);
    }

    pub fn close(response: Response) void {
        response.vtable.close(response.context);
    }
};

/// The value of the header `name` among `headers`, in any case; the first where several are.
pub fn find(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |each| if (std.ascii.eqlIgnoreCase(each.name, name)) return each.value;
    return null;
}

/// The host's HTTP: one call, which sends a request and gives its response whatever its status.
pub const Http = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (context: *anyopaque, request: Request) SendError!Response,
    };

    pub fn send(http: Http, request: Request) SendError!Response {
        return http.vtable.send(http.context, request);
    }
};

test "a header is found by its name in any case, the first of several" {
    const headers = [_]Header{ .{ .name = "Content-Type", .value = "text/event-stream" }, .{ .name = "content-type", .value = "x" } };
    try std.testing.expectEqualStrings("text/event-stream", find(&headers, "content-type").?);
    try std.testing.expectEqual(null, find(&headers, "retry-after"));
}
