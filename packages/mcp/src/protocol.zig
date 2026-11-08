//! The protocol's revisions, codes and names, and the client's defaults and limits.
const std = @import("std");

/// How a server speaks: `modern`, stateless with metadata on every request (2026-07-28 and later), or `legacy`, with a
/// session that `initialize` opens (2025-11-25 and earlier).
pub const Era = enum { modern, legacy };

/// The revision this client speaks first: stateless, every request carrying its version and capabilities.
pub const version = "2026-07-28";

/// The stateless revisions this client speaks, newest first.
pub const modern_versions = [_][]const u8{version};

/// The session-based revisions, which start with `initialize`, this client speaks to servers not yet stateless, newest
/// first.
pub const legacy_versions = [_][]const u8{ "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05" };

/// MCP's own error codes, beside JSON-RPC's.
pub const codes = struct {
    /// The HTTP headers do not match the body, or one it needs is missing.
    pub const header_mismatch = -32020;
    /// The server needs a client capability the request did not declare.
    pub const missing_required_client_capability = -32021;
    /// The server does not support the request's version; `data.supported` lists those it does.
    pub const unsupported_protocol_version = -32022;
};

/// Whether `code` is one only a server of the current protocol answers with, which tells it from one of an earlier.
pub fn isModernCode(code: i64) bool {
    return code == codes.header_mismatch or code == codes.missing_required_client_capability or code == codes.unsupported_protocol_version;
}

/// The keys of a stateless request's and answer's `_meta` the protocol defines.
pub const meta = struct {
    pub const protocol_version = "io.modelcontextprotocol/protocolVersion";
    pub const client_info = "io.modelcontextprotocol/clientInfo";
    pub const client_capabilities = "io.modelcontextprotocol/clientCapabilities";
    pub const log_level = "io.modelcontextprotocol/logLevel";
    pub const subscription_id = "io.modelcontextprotocol/subscriptionId";
    pub const server_info = "io.modelcontextprotocol/serverInfo";
};

/// Whether a server may answer `method` with `input_required`.
pub fn takesInput(method: []const u8) bool {
    for ([_][]const u8{ "tools/call", "resources/read", "prompts/get" }) |each| if (std.mem.eql(u8, each, method)) return true;
    return false;
}

pub fn isLegacyVersion(given: []const u8) bool {
    for (legacy_versions) |each| if (std.mem.eql(u8, each, given)) return true;
    return false;
}

/// How long a request waits for its answer, its time stopped while its question waits for one, by default.
pub const timeout_ms = 60_000;

/// How long `server/discover` waits before the server is taken for a session-based one, by default.
pub const probe_timeout_ms = 10_000;

/// How many times a stateless request whose stream broke is sent again.
pub const reissues_max = 2;

/// How many rounds of input one request may ask for.
pub const input_rounds_max = 16;

/// How long to wait before opening a broken stream again when the server set no `retry`, by default.
pub const reconnect_delay_ms = 1000;

/// How many times in a row a broken stream is opened again before it is given up, by default.
pub const reconnects_max = 3;

/// How long a stdio server has to exit once its stdin is closed, before it is ended, by default.
pub const shutdown_timeout_ms = 2000;

/// The random bytes of a sign-in's `state`.
pub const oauth_state_bytes = 32;
