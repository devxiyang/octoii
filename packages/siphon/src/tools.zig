//! The tools a thread's model may call: what a tool is and gives; the table that finds one by its name — Siphon's own,
//! each MCP server's under the server's name — and the servers; the calls that ask a tool, as fibers, weighed by the
//! permissions their threads hold and judged by a second model in auto; the person's trust in a project's servers; and
//! the tools Siphon has of its own, built in — the coding tools, the command lines the shell runs read for what they
//! run, scripts that call the rest, questions to the person, and the browser's pages, looked at and acted on.
pub const Tool = @import("tools/Tool.zig");
pub const Table = @import("tools/Table.zig");
pub const Servers = @import("tools/Servers.zig");
pub const Coprocess = @import("tools/Coprocess.zig");
pub const declarations = @import("tools/declarations.zig");
pub const trust = @import("tools/trust.zig");
pub const calls = @import("tools/calls.zig");
pub const permissions = @import("tools/permissions.zig");
pub const review = @import("tools/review.zig");
pub const question = @import("tools/question.zig");
pub const commands = @import("tools/commands.zig");
pub const coding = @import("tools/coding.zig");
pub const scripts = @import("tools/scripts.zig");
pub const browser = @import("tools/browser.zig");
pub const Asked = @import("tools/browser/Asked.zig");
pub const snapshot = @import("tools/browser/snapshot.zig");
pub const keys = @import("tools/browser/keys.zig");

test {
    _ = Tool;
    _ = Table;
    _ = Servers;
    _ = Coprocess;
    _ = declarations;
    _ = trust;
    _ = calls;
    _ = permissions;
    _ = review;
    _ = question;
    _ = commands;
    _ = coding;
    _ = scripts;
    _ = browser;
    _ = Asked;
    _ = snapshot;
    _ = keys;
}
