//! What can go wrong talking to an MCP server. A call that fails leaves its failure where its caller reads it and
//! returns `error.Failed`, as Zig's errors carry nothing; the failure says which of these it was and what it holds.
const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

pub const Error = error{ Failed, OutOfMemory };

pub const Failure = union(enum) {
    /// The server answered with a JSON-RPC error.
    refused: struct { code: i64, message: []const u8, data: ?std.json.Value = null },
    /// The server broke the protocol: an answer that is not what the request asks for, or a request the client does
    /// not take.
    protocol: []const u8,
    /// A request got no answer within its time; it was cancelled.
    timeout: struct { method: []const u8, timeout_ms: u64 },
    /// The connection is gone or broke under a request: the transport closed, the process exited, the network failed.
    connection_lost: []const u8,
    /// A session-based server ended the session, and with it the connection. A request it answered so had not run,
    /// and may be sent again on a new connection.
    session_ended: []const u8,
    /// A stateless server asked the person questions within a request made to hand them back, and ended it: the caller
    /// keeps them, has them answered, and sends the request again with the answers.
    input_required: struct { method: []const u8, input: types.InputRequired },
    /// The server refused the request's credentials over HTTP: 401, or 403 for scope it lacks, with its challenge.
    unauthorized: struct { status: u16, www_authenticate: ?[]const u8 = null },
    /// The server answered over HTTP with a status the transport cannot use, and no JSON-RPC error that says more.
    http: struct { status: u16, body: []const u8 },
    /// The caller's answer to a server's question does not fit it, as an accepted form whose content breaks the form.
    invalid_answer: []const u8,
    /// A step of signing in to the server failed, of the kind it says.
    oauth: struct { kind: OAuthKind, message: []const u8 },
    /// The caller canceled the request.
    canceled,

    /// What the failure says, for a person.
    pub fn message(failure: Failure, arena: Allocator) Allocator.Error![]const u8 {
        return switch (failure) {
            .refused => |refused| refused.message,
            .protocol, .connection_lost, .session_ended, .invalid_answer => |text| text,
            .timeout => |timeout| arena.print("The MCP request {s} got no answer within {d} ms", .{ timeout.method, timeout.timeout_ms }),
            .input_required => |input| arena.print("The MCP server asks for input to {s}", .{input.method}),
            .unauthorized => |refusal| arena.print("The MCP server answered {d}: {s}", .{ refusal.status, if (refusal.status == 401) "sign-in required" else "access denied" }),
            .http => |answer| arena.print("The MCP server answered HTTP {d}{s}{s}", .{ answer.status, if (answer.body.len == 0) "" else ": ", answer.body[0..@min(answer.body.len, 200)] }),
            .oauth => |refusal| refusal.message,
            .canceled => "The MCP request was canceled",
        };
    }

    /// Whether the connection is gone with it, as a lost connection and an ended session are.
    pub fn isConnectionLost(failure: Failure) bool {
        return failure == .connection_lost or failure == .session_ended;
    }
};

/// Why a step of signing in to an MCP server failed.
pub const OAuthKind = enum {
    /// No usable protected resource or authorization server metadata.
    metadata,
    /// The authorization server's metadata names another issuer than the one it was fetched for.
    issuer,
    /// The authorization server does not offer PKCE with S256.
    pkce,
    /// No way to identify the client to the authorization server.
    client,
    /// Dynamic client registration was refused.
    registration,
    /// A callback whose `state` names no sign-in that waits.
    state,
    /// A callback whose `iss` is not the issuer the sign-in went to, or lacks one it must carry (RFC 9207).
    callback_issuer,
    /// The person or the authorization server ended the sign-in with an error.
    denied,
    /// A callback without a code.
    callback,
    /// The token endpoint refused the exchange or the refresh.
    token,
};

/// Where a failure is left for the caller: what the failed call made lives in `arena`.
pub const Slot = struct {
    arena: Allocator,
    failure: ?Failure = null,

    pub fn fail(slot: *Slot, failure: Failure) error{Failed} {
        slot.failure = failure;
        return error.Failed;
    }

    /// Fails a sign-in's step with `kind`, its message formatted.
    pub fn refused(slot: *Slot, kind: OAuthKind, comptime text: []const u8, arguments: anytype) Error {
        return slot.fail(.{ .oauth = .{ .kind = kind, .message = try slot.arena.print(text, arguments) } });
    }

    /// Fails with a protocol violation, its message formatted.
    pub fn violated(slot: *Slot, comptime text: []const u8, arguments: anytype) Error {
        return slot.fail(.{ .protocol = try slot.arena.print(text, arguments) });
    }
};

/// What a call made, or the failure it ended with.
pub fn Outcome(comptime T: type) type {
    return union(enum) {
        done: T,
        failed: Failure,
    };
}
