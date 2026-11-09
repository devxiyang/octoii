//! Siphon: Octoii's runtime, on Beak, linked through `beak.h` — put together as `Siphon` from its parts, each on those
//! below it: the binding to Beak, images fitted, the shell's language read, text, the runtime, operations done once,
//! the threads, the settings, the accounts of the providers, the machine a thread works on, the script engine, the
//! tools, the agent, and the protocol its clients speak.
const std = @import("std");
pub const Siphon = @import("Siphon.zig");
pub const beak = @import("beak.zig");
pub const image = @import("image.zig");
pub const shell = @import("shell.zig");
pub const text = @import("text.zig");
pub const runtime = @import("runtime.zig");
pub const threads = @import("threads.zig");
pub const settings = @import("settings.zig");
pub const operations = @import("operations.zig");
pub const Accounts = @import("accounts.zig");
pub const Machine = @import("machine.zig");
pub const Git = @import("git.zig");
pub const Browser = @import("browser.zig");
pub const script = @import("script.zig");
pub const tools = @import("tools.zig");
pub const agent = @import("agent.zig");
pub const protocol = @import("protocol.zig");
pub const testing = @import("testing.zig");
pub const ai = @import("ai");
pub const vocabulary = @import("vocabulary");
pub const foundation = @import("foundation");

test {
    // Every public declaration of Siphon's own is compiled, used by a test or not.
    inline for (.{ Siphon, beak, image, shell, text, runtime, operations, threads, settings, Accounts, Machine, script, tools, agent, protocol, testing }) |namespace| {
        std.testing.refAllDecls(namespace);
    }
    _ = image;
    _ = shell;
    _ = text;
    _ = runtime;
    _ = threads;
    _ = settings;
    _ = Machine;
    _ = Git;
    _ = Browser;
    _ = Browser.Cdp;
    _ = script;
    _ = tools;
    _ = agent;
    _ = protocol;
    _ = @import("layers.zig");
    _ = @import("log_test.zig");
    _ = @import("loop_test.zig");
    _ = @import("threads_test.zig");
    _ = @import("models_test.zig");
    _ = @import("tools_test.zig");
    _ = @import("coding_test.zig");
    _ = @import("browser_test.zig");
    _ = @import("scripts_test.zig");
    _ = @import("skills_test.zig");
    _ = @import("connection_test.zig");
    _ = @import("machine_test.zig");
    _ = @import("servers_test.zig");
    _ = @import("trust_test.zig");
    _ = @import("permissions_test.zig");
    _ = @import("question_test.zig");
    _ = @import("stored_test.zig");
    _ = @import("coprocess_test.zig");
}
