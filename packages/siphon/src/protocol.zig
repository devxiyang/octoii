//! Siphon's protocol, as its clients speak it: each client a connection the host opened for it, served by the runtime's
//! loop, which it hears from as the loop's listener.
pub const Access = @import("protocol/Access.zig");
pub const Clients = @import("protocol/Clients.zig");
pub const Connection = @import("protocol/Connection.zig");
pub const Following = @import("protocol/Following.zig");
pub const Providers = @import("protocol/Providers.zig");
pub const files = @import("protocol/files.zig");
pub const on_machine = @import("protocol/on_machine.zig");
pub const git = @import("protocol/git.zig");
pub const pages = @import("protocol/pages.zig");
pub const terminals = @import("protocol/terminals.zig");

test {
    _ = Access;
    _ = Clients;
    _ = Connection;
    _ = Following;
    _ = Providers;
    _ = files;
    _ = on_machine;
    _ = git;
    _ = pages;
    _ = terminals;
}
