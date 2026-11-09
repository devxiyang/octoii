//! How a request fails: its kind, whether trying again may help, how long to wait, and what the provider said. A call
//! that fails returns `error.Failed` and leaves its failure where its caller reads it — a `Call`'s `failure` — and a
//! stream ends with the same failure under its error's `octoii`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vocabulary = @import("vocabulary");

pub const Kind = vocabulary.FailureKind;

/// A call failed, its failure left where its caller reads it; or memory ran out.
pub const Error = error{ Failed, OutOfMemory };

pub const Failure = struct {
    kind: Kind,
    message: []const u8,
    /// Whether trying again may help: as the provider says, else as `retryableKind` says of the kind.
    retryable: bool,
    /// How long to wait before trying again, where the provider says.
    retry_after_ms: ?u64 = null,
    /// The HTTP status the provider answered with.
    status: ?u16 = null,
    /// The provider's code for the failure, such as Anthropic's `overloaded_error`; none where it gives none.
    code: ?[]const u8 = null,
    /// The provider's report of the failure as it sent it.
    body: ?[]const u8 = null,

    /// A failure of `kind`, retryable as its kind is.
    pub fn init(kind: Kind, message: []const u8) Failure {
        return .{ .kind = kind, .message = message, .retryable = retryableKind(kind) };
    }

    /// A failure of `kind` whose message is formatted in `arena`.
    pub fn format(arena: Allocator, kind: Kind, comptime text: []const u8, arguments: anytype) Allocator.Error!Failure {
        return .init(kind, try arena.print(text, arguments));
    }

    /// The failure as an error's `octoii` carries it.
    pub fn extension(failure: Failure) vocabulary.extensions.FailureExtension {
        return .{ .kind = failure.kind, .retryable = failure.retryable, .retry_after_ms = failure.retry_after_ms, .status = failure.status };
    }

    /// The failure as a failed response's `error`: its code the provider's, else the failure's kind.
    pub fn responseError(failure: Failure) vocabulary.response.ResponseError {
        return .{ .code = failure.code orelse @tagName(failure.kind), .message = failure.message, .octoii = failure.extension() };
    }

    /// The failure an `error` event or a response's error carries, its code the provider's where it is not the kind.
    pub fn ofError(code: []const u8, message: []const u8, carried: vocabulary.extensions.FailureExtension) Failure {
        return .{
            .kind = carried.kind,
            .message = message,
            .retryable = carried.retryable,
            .retry_after_ms = carried.retry_after_ms,
            .status = carried.status,
            .code = if (std.mem.eql(u8, code, @tagName(carried.kind))) null else code,
        };
    }

    /// The failure a failed response stands for: its error's, or `invalid_response` where it gives none.
    pub fn ofResponse(arena: Allocator, failed: vocabulary.Response) Allocator.Error!Failure {
        const given = failed.@"error" orelse return format(arena, .invalid_response, "The response {s} failed without an error", .{failed.id});
        return ofError(given.code, given.message, given.octoii);
    }
};

/// Whether a failure of this kind may pass on its own, where its provider does not say: rate limits, server and
/// network failures, and timeouts.
pub fn retryableKind(kind: Kind) bool {
    return switch (kind) {
        .rate_limit, .server, .transport, .timeout => true,
        else => false,
    };
}

test "a failure is retryable as its kind is, and carries the provider's code where it gave one" {
    const failure: Failure = .init(.rate_limit, "slow down");
    try std.testing.expect(failure.retryable);
    try std.testing.expectEqualStrings("rate_limit", failure.responseError().code);
    const coded: Failure = .{ .kind = .server, .message = "busy", .retryable = true, .code = "overloaded_error", .status = 529 };
    const back = Failure.ofError(coded.responseError().code, coded.message, coded.extension());
    try std.testing.expectEqualStrings("overloaded_error", back.code.?);
    try std.testing.expectEqual(@as(?u16, 529), back.status);
    try std.testing.expectEqual(null, Failure.ofError("auth", "no", Failure.init(.auth, "no").extension()).code);
}
