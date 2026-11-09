//! The node's Home, laid out as a system's folders are: `etc/` the person's own configuration, for every project —
//! their instructions, `AGENTS.md`, and MCP servers, `mcp.json` — and the providers' credentials, `etc/credstore`;
//! `share/skills` their skills; `var/lib` the node's state — the volume, the access its clients hold, the node's
//! identity its tunnel sessions show, the address its account gave the machine, the profile of the browser the threads' pages are open in; `var/log/outputs` what the tools could not give whole; `var/cache` the
//! catalogue of models fetched last; `run` what lasts while the node runs, the machine's ledger; and `threads`, where a
//! thread's calls read the threads. The Home is the person's alone, and what the node keeps for itself in it — the
//! credentials, its state, `run` — nothing that reaches the machine through Siphon reads or writes.
const Home = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const beak = @import("siphon").beak;
const h = beak.h;

root: []const u8,
instructions: []const u8,
mcp: []const u8,
credentials: []const u8,
skills: []const u8,
volume: []const u8,
access: []const u8,
/// The seed of the node's identity, the key its tunnel sessions show.
identity: []const u8,
/// The address the machine is reached at, as its account gave it when it joined.
address: []const u8,
browser: []const u8,
outputs: []const u8,
catalogue: []const u8,
run: []const u8,
threads: []const u8,
/// What the node keeps for itself, by absolute paths: the credentials, its state and `run`.
hidden: []const []const u8,

/// The Home at `given`, else `.octoii` in the person's home folder, by its absolute path, as every path the node
/// gives Siphon is; the Home made the person's alone, and its folders made where they are missing.
pub fn open(io: std.Io, environ: *const std.process.Environ.Map, arena: Allocator, given: ?[]const u8) !Home {
    const named = given orelse try std.fs.path.join(arena, &.{ environ.get("HOME") orelse return error.NoHome, ".octoii" });
    const root = try std.fs.path.resolve(arena, &.{ try std.process.currentPathAlloc(io, arena), named });
    const state = try std.fs.path.join(arena, &.{ root, "var", "lib" });
    const credentials = try std.fs.path.join(arena, &.{ root, "etc", "credstore" });
    const run = try std.fs.path.join(arena, &.{ root, "run" });
    const home: Home = .{
        .root = root,
        .instructions = try std.fs.path.join(arena, &.{ root, "etc", "AGENTS.md" }),
        .mcp = try std.fs.path.join(arena, &.{ root, "etc", "mcp.json" }),
        .credentials = credentials,
        .skills = try std.fs.path.join(arena, &.{ root, "share", "skills" }),
        .volume = try std.fs.path.join(arena, &.{ state, "volume" }),
        .access = try std.fs.path.join(arena, &.{ state, "access" }),
        .identity = try std.fs.path.join(arena, &.{ state, "identity" }),
        .address = try std.fs.path.join(arena, &.{ state, "address" }),
        .browser = try std.fs.path.join(arena, &.{ state, "browser" }),
        .outputs = try std.fs.path.join(arena, &.{ root, "var", "log", "outputs" }),
        .catalogue = try std.fs.path.join(arena, &.{ root, "var", "cache", "catalogue.json" }),
        .run = run,
        .threads = try std.fs.path.join(arena, &.{ root, "threads" }),
        .hidden = try arena.dupe([]const u8, &.{ credentials, state, run }),
    };
    // The Home is the person's alone, as their ~/.ssh is: made or found so, where the system has modes.
    const modes = @hasDecl(std.Io.File.Permissions, "fromMode");
    const owner_only: std.Io.File.Permissions = if (modes) .fromMode(0o700) else .default_dir;
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{ .permissions = owner_only });
    defer dir.close(io);
    if (modes) try dir.setPermissions(io, owner_only);
    for ([_][]const u8{ credentials, state, run, home.outputs, std.fs.path.dirname(home.catalogue).? }) |folder| try std.Io.Dir.cwd().createDirPath(io, folder);
    return home;
}

/// The local machine, its ledger in the Home: what a node that ended left running is stopped as it opens.
pub fn openMachine(home: Home, arena: Allocator) !h.beak_handle {
    const ledger = try std.fs.path.join(arena, &.{ home.run, "machine.ledger" });
    const local: h.beak_local_machine = .{ .ledger = beak.bytes(ledger), .sandbox_helper = beak.bytes("") };
    var machine: h.beak_handle = 0;
    var stopped: u64 = 0;
    try beak.check(h.beak_machine_open_local(&local, &machine, &stopped));
    return machine;
}

/// Whether the local machine, as the node opens it, confines a command to the system's sandbox: on macOS by the
/// system's own; on Linux only with Beak's helper, which the node does not give it yet; on Windows not yet.
pub const machine_sandboxes = builtin.target.os.tag == .macos;

/// The local machine's name as its person knows it, which clients show the environment by: its host name, less the
/// `.local` a Mac gives it; on Windows its computer name; none where the system tells none.
pub fn machineNameOf(arena: Allocator, environ: *const std.process.Environ.Map) !?[]const u8 {
    if (builtin.target.os.tag == .windows) return environ.get("COMPUTERNAME");
    var buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const name = std.posix.gethostname(&buffer) catch return null;
    const bare = if (std.mem.endsWith(u8, name, ".local")) name[0 .. name.len - ".local".len] else name;
    return if (bare.len == 0) null else try arena.dupe(u8, bare);
}

/// The local machine's temporary folders, which a sandboxed command writes besides its workspace: the person's own, as
/// the login environment names it, and on Unix the shared `/tmp`.
pub fn temporaryOf(arena: Allocator, environ: *const std.process.Environ.Map) ![]const []const u8 {
    var folders: std.ArrayList([]const u8) = .empty;
    const own = if (builtin.target.os.tag == .windows) environ.get("TEMP") else environ.get("TMPDIR");
    if (own) |folder| if (std.fs.path.isAbsolute(folder)) try folders.append(arena, folder);
    if (builtin.target.os.tag != .windows) try folders.append(arena, "/tmp");
    return folders.items;
}

/// The person's own ignore file, as git reads it beneath every repository's own: the one their configuration names as
/// `core.excludesFile`, else git's default, `$XDG_CONFIG_HOME/git/ignore` or `~/.config/git/ignore` — named where it is
/// there or not, as git passes over one that is not; none where neither is named, nor git nor a home there to ask.
pub fn excludesOf(io: std.Io, arena: Allocator, environ: *const std.process.Environ.Map) !?[]const u8 {
    const asked = std.process.run(arena, io, .{ .argv = &.{ "git", "config", "--global", "--path", "--get", "core.excludesFile" }, .environ_map = environ, .stdout_limit = .limited(64 << 10), .stderr_limit = .limited(64 << 10) }) catch null;
    if (asked) |ran| {
        const named = std.mem.trim(u8, ran.stdout, " \t\r\n");
        if (ran.term == .exited and ran.term.exited == 0 and std.fs.path.isAbsolute(named)) return named;
    }
    if (environ.get("XDG_CONFIG_HOME")) |config| if (std.fs.path.isAbsolute(config)) return try std.fs.path.join(arena, &.{ config, "git", "ignore" });
    const own = environ.get("HOME") orelse return null;
    return try std.fs.path.join(arena, &.{ own, ".config", "git", "ignore" });
}

/// The Chromium of the machine the threads' pages are opened in, by its path: the first there is of Chrome, Chromium,
/// Edge and Brave, where each is put on this system; none where there is none.
pub fn browserOf(io: std.Io, arena: Allocator, environ: *const std.process.Environ.Map) !?[]const u8 {
    var candidates: std.ArrayList([]const u8) = .empty;
    switch (builtin.target.os.tag) {
        .macos => {
            const apps = [_][]const u8{ "Google Chrome.app/Contents/MacOS/Google Chrome", "Chromium.app/Contents/MacOS/Chromium", "Microsoft Edge.app/Contents/MacOS/Microsoft Edge", "Brave Browser.app/Contents/MacOS/Brave Browser" };
            for (apps) |app| {
                try candidates.append(arena, try std.fs.path.join(arena, &.{ "/Applications", app }));
                if (environ.get("HOME")) |own| try candidates.append(arena, try std.fs.path.join(arena, &.{ own, "Applications", app }));
            }
        },
        .windows => {
            const programs = [_][]const u8{ "Google\\Chrome\\Application\\chrome.exe", "Microsoft\\Edge\\Application\\msedge.exe", "BraveSoftware\\Brave-Browser\\Application\\brave.exe" };
            for ([_][]const u8{ "ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA" }) |root| {
                const folder = environ.get(root) orelse continue;
                for (programs) |program| try candidates.append(arena, try std.fs.path.join(arena, &.{ folder, program }));
            }
        },
        else => {
            const names = [_][]const u8{ "google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "microsoft-edge", "brave-browser" };
            var folders = std.mem.tokenizeScalar(u8, environ.get("PATH") orelse "/usr/bin", ':');
            while (folders.next()) |folder| for (names) |name| try candidates.append(arena, try std.fs.path.join(arena, &.{ folder, name }));
        },
    }
    for (candidates.items) |path| {
        std.Io.Dir.cwd().access(io, path, .{}) catch continue;
        return path;
    }
    return null;
}
