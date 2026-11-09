//! mcp: Octoii's client and server of the Model Context Protocol — both of its eras, the stateless one and the
//! session-based one before it — over the transports a host gives it, on the host's io by default.
pub const jsonrpc = @import("foundation").jsonrpc;
pub const protocol = @import("protocol.zig");
pub const types = @import("types.zig");
pub const failure = @import("failure.zig");
pub const Failure = failure.Failure;
pub const headers = @import("headers.zig");
pub const results = @import("results.zig");
pub const transport = @import("transport.zig");
pub const Transport = transport.Transport;
pub const memory = @import("memory.zig");
pub const streamable_http = @import("streamable_http.zig");
pub const stdio = @import("stdio.zig");
pub const oauth = @import("oauth.zig");
pub const Client = @import("Client.zig");
pub const Pool = @import("Pool.zig");
pub const Server = @import("Server.zig");
pub const stdio_server = @import("stdio_server.zig");

pub const testing = struct {
    pub const Host = @import("testing/host.zig").Host;
    pub const server = @import("testing/server.zig");
    pub const http = @import("testing/http.zig");
};

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("client_tests.zig");
    _ = @import("streamable_http_tests.zig");
    _ = @import("stdio_tests.zig");
    _ = @import("oauth_tests.zig");
    _ = @import("server_tests.zig");
}
