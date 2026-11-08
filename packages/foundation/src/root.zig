//! foundation: what more than one of Octoii's packages needs, on Zig's standard library alone.
pub const json = @import("json.zig");
pub const http = @import("http.zig");
pub const time = @import("time.zig");
pub const sse = @import("sse.zig");
pub const replay = @import("replay.zig");
pub const StdHttp = @import("StdHttp.zig");
pub const oauth = @import("oauth.zig");
pub const multipart = @import("multipart.zig");
pub const websocket = @import("websocket.zig");
pub const StdWebSocket = @import("StdWebSocket.zig");
pub const socket_replay = @import("socket_replay.zig");
pub const testing = @import("testing.zig");

test {
    _ = json;
    _ = http;
    _ = time;
    _ = sse;
    _ = replay;
    _ = StdHttp;
    _ = oauth;
    _ = multipart;
    _ = websocket;
    _ = StdWebSocket;
    _ = socket_replay;
    _ = testing;
}
