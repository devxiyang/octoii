//! A request sent with a sign-in's access token, read from the host's store at each use: refreshed first where it
//! expires within five minutes, and once where the provider refuses it, unless someone refreshed it meanwhile, the
//! request then sent once more — the one time ai sends a request again. Each refresh runs inside the store's `modify`,
//! so that two processes never spend one refresh token. A provider not signed in fails as `auth` before anything is
//! sent.
const std = @import("std");
const foundation = @import("foundation");
const seam = @import("../driver.zig");
const Call = seam.Call;
const Error = @import("../failure.zig").Error;
const http = @import("http.zig");

/// How long before it expires an access token is refreshed.
pub const refresh_margin_ms = 5 * 60_000;

/// The tokens of a sign-in.
pub const Tokens = @typeInfo(@FieldType(seam.OAuth, "tokens")).optional.child;

/// Asks the issuer for new tokens with `refresh_token`, the provider's own call: `credential` holding the access token,
/// its expiry, the scopes and the rotated refresh token together; `Failed` where the issuer refuses.
pub const Refresh = *const fn (call: *Call, credential: seam.OAuth, refresh_token: []const u8) Error!seam.OAuth;

/// Sends `request` with the sign-in's access token as its authorization.
pub fn send(call: *Call, refresh: Refresh, request: foundation.http.Request) Error!foundation.http.Response {
    var tokens = try signedIn(call, try call.credential());
    if (tokens.expires_at_ms - refresh_margin_ms <= call.nowMs()) tokens = try renewed(call, refresh, .due);
    const response = try sendWith(call, request, tokens.access);
    if (response.status != 401) return response;
    response.close();
    return sendWith(call, request, (try renewed(call, refresh, .{ .refused = tokens.access })).access);
}

fn sendWith(call: *Call, request: foundation.http.Request, access: []const u8) Error!foundation.http.Response {
    var headers: std.ArrayList(foundation.http.Header) = .empty;
    try headers.append(call.arena, .{ .name = "authorization", .value = try call.arena.print("Bearer {s}", .{access}) });
    try headers.appendSlice(call.arena, request.headers);
    var sent = request;
    sent.headers = headers.items;
    return http.send(call, sent);
}

/// When the tokens are stale: once they are due, or while they are still the ones the provider refused.
const Stale = union(enum) {
    due,
    refused: []const u8,

    fn of(stale: Stale, call: *const Call, tokens: Tokens) bool {
        return switch (stale) {
            .due => tokens.expires_at_ms - refresh_margin_ms <= call.nowMs(),
            .refused => |access| std.mem.eql(u8, tokens.access, access),
        };
    }
};

/// The sign-in's tokens after a refresh inside the store's `modify`, which reads the credential again there and
/// refreshes it only where it is still stale, so that a refresh made meanwhile is used as it is.
fn renewed(call: *Call, refresh: Refresh, stale: Stale) Error!Tokens {
    const Renewal = struct {
        call: *Call,
        refresh: Refresh,
        stale: Stale,

        fn apply(context: *anyopaque, _: std.mem.Allocator, current: ?seam.Credential) Error!?seam.Credential {
            const renewal: *@This() = @ptrCast(@alignCast(context));
            const tokens = try signedIn(renewal.call, current);
            if (!renewal.stale.of(renewal.call, tokens)) return null;
            const refresh_token = tokens.refresh orelse
                return renewal.call.failWith(.auth, "The sign-in to {s} has expired and holds no refresh token: sign in again", .{renewal.call.provider.id});
            return .{ .oauth = try renewal.refresh(renewal.call, current.?.oauth, refresh_token) };
        }
    };
    var renewal: Renewal = .{ .call = call, .refresh = refresh, .stale = stale };
    const stored = call.host.credentials.modify(call.arena, call.provider.id, .{ .context = &renewal, .apply = Renewal.apply }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return error.Failed,
        error.Unavailable => return call.failWith(.auth, "The host's credentials for the provider {s} cannot be changed", .{call.provider.id}),
    };
    return signedIn(call, stored);
}

/// The tokens of `credential`, a sign-in that holds them; `auth` where it is none.
fn signedIn(call: *Call, credential: ?seam.Credential) Error!Tokens {
    if (credential) |given| if (given == .oauth) if (given.oauth.tokens) |tokens| return tokens;
    return call.failWith(.auth, "The provider {s} is not signed in: the host's credentials hold no sign-in with tokens for it", .{call.provider.id});
}
