//! The machine the host runs on, as a task reaches it for one piece of work — a thread's call, a client's read: its whole
//! tree mounted writable as the root of a namespace of Beak's, as a shell reaches every file of its machine, but what
//! the host keeps for itself, which nothing reaches through it — a thread's call, a command one runs, a client; the
//! threads themselves shown, read from the volume, where the host lays them out and the work reads them; where
//! its paths start — a thread's workspace, and the home folder the host knows; and the programs a task runs on it to
//! their end, as system(3) runs one, in a sleep a stop cuts off.
const std = @import("std");
const Allocator = std.mem.Allocator;
const beak = @import("beak.zig");
const h = beak.h;
const threads = @import("threads.zig");
const Waits = @import("runtime.zig").Waits;
pub const paths = @import("machine/paths.zig");
pub const files = @import("machine/files.zig");

pub const Machine = @This();

/// The machine as Beak opened it, which runs the programs.
handle: h.beak_handle,
namespace: h.beak_handle,
base: paths.Base,
/// The person's own ignore file, by its absolute path, as the host named it; none where it named none.
excludes: ?[]const u8 = null,

/// The machine threads work on, as the host opened it through Beak; the home folder of the person it runs for, which
/// `~` names in a path, and their shell, which a terminal runs; and its temporary folders, which a sandboxed command
/// writes besides the workspace — none of any where the host has none.
pub const Host = struct {
    handle: ?h.beak_handle = null,
    /// The machine's name as its person knows it, which clients show the environment by; none where the host knows none.
    name: ?[]const u8 = null,
    home: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    /// The person's own ignore file, git's `core.excludesFile`, by its absolute path; none where the host names none.
    excludes: ?[]const u8 = null,
    temporary: []const []const u8 = &.{},
    /// What the host keeps for itself on the machine, by absolute paths: nothing that reaches the machine through it — a
    /// thread's call, a command one runs, a client — reads or writes it.
    hidden: []const []const u8 = &.{},
    /// The folder a thread's calls read the threads in, by its absolute path, as the host lays its own out — each thread
    /// there by its id, read from the volume and never written; none where the host shows them nowhere.
    threads: ?[]const u8 = null,
    /// Whether the machine confines a command to a sandbox: on macOS ever, on Linux with Beak's helper; on Windows not
    /// yet. Where it does not, no command runs as sandboxed.
    sandboxes: bool = false,
};

/// How a piece of work opens the machine: where its paths start; and the volume whose threads it reads, where the host
/// lays them out, as a thread's calls do — none for work that reads none.
pub const OpenOptions = struct {
    base: paths.Base,
    threads: ?beak.Volume = null,
};

/// The machine `host` opened as `options` say: its namespace opened, what the host keeps for itself hidden, the threads
/// shown where the work reads them.
pub fn open(host: Host, options: OpenOptions) !Machine {
    const handle = host.handle orelse return error.NoMachine;
    var namespace: h.beak_handle = 0;
    try beak.check(h.beak_namespace_open(&namespace));
    errdefer _ = h.beak_close(namespace);
    var file_system = std.mem.zeroes(h.beak_file_system);
    file_system.type = h.BEAK_FILE_SYSTEM_MACHINE;
    file_system.handle = handle;
    file_system.path = beak.bytes(root);
    try beak.check(h.beak_namespace_mount(namespace, beak.bytes(""), &file_system, true));
    const machine: Machine = .{ .handle = handle, .namespace = namespace, .base = options.base, .excludes = host.excludes };
    errdefer machine.close();
    for (host.hidden) |place| try machine.hide(place);
    if (options.threads) |volume| if (host.threads) |folder| try machine.showThreads(volume, folder);
    return machine;
}

/// Hides the place at the absolute path `place`: every access to it and beneath it denied, as systemd's
/// InaccessiblePaths= keeps a path from a service.
fn hide(machine: Machine, place: []const u8) !void {
    var file_system = std.mem.zeroes(h.beak_file_system);
    file_system.type = h.BEAK_FILE_SYSTEM_INACCESSIBLE;
    try beak.check(h.beak_namespace_mount(machine.namespace, beak.bytes(place[root.len..]), &file_system, false));
}

/// Shows the threads of `volume` in the folder at the absolute path `folder`, read alone: each by its id, every thread
/// of the volume — each carrying its project's label, of any value.
fn showThreads(machine: Machine, volume: beak.Volume, folder: []const u8) !void {
    var file_system = std.mem.zeroes(h.beak_file_system);
    file_system.type = h.BEAK_FILE_SYSTEM_LABEL;
    file_system.handle = volume.handle;
    file_system.kind = beak.bytes(threads.kind);
    file_system.label = beak.bytes(threads.project_label);
    file_system.view = h.BEAK_LABEL_ANY_VALUE;
    try beak.check(h.beak_namespace_mount(machine.namespace, beak.bytes(folder[root.len..]), &file_system, false));
}

pub fn close(machine: Machine) void {
    _ = h.beak_namespace_unmount(machine.namespace, beak.bytes(""));
    _ = h.beak_close(machine.namespace);
}

/// The namespace's path of the place `given` names: the place's absolute path, its root left out.
pub fn pathOf(machine: Machine, arena: Allocator, given: []const u8) ![]const u8 {
    return (try paths.resolve(arena, machine.base, given))[root.len..];
}

/// The namespace's `path` as the model reads it.
pub fn shown(machine: Machine, arena: Allocator, path: []const u8) ![]const u8 {
    return paths.shown(arena, machine.base, try std.mem.concat(arena, u8, &.{ root, path }));
}

/// The file or folder at the namespace's `path`, read as `options` say — a page of a text file or of a folder, an image
/// or a PDF as it is — as `files.read` reads it.
pub fn readFile(machine: Machine, arena: Allocator, path: []const u8, options: files.ReadOptions) beak.Error!files.Read {
    return files.read(machine, arena, path, options);
}

/// Writes `content` as the file at the namespace's `path`, as `files.write` writes it, its diff naming it `name`.
pub fn writeFile(machine: Machine, arena: Allocator, path: []const u8, content: []const u8, name: []const u8) beak.Error!files.Written {
    return files.write(machine, arena, path, content, name);
}

/// Edits the text file at the namespace's `path`, as `files.edit` edits it, its diff naming it `name`.
pub fn editFile(machine: Machine, arena: Allocator, path: []const u8, request: @import("text.zig").Request, name: []const u8) beak.Error!files.Edit {
    return files.edit(machine, arena, path, request, name);
}

/// The bytes of the file `given` names, `length` at most; null where there is no such file.
pub fn readAll(machine: Machine, arena: *const Allocator, given: []const u8, length: u64) !?[]const u8 {
    const allocator = beak.outputs(arena);
    var bytes: h.beak_bytes = undefined;
    const status = h.beak_namespace_read(machine.namespace, beak.bytes(try machine.pathOf(arena.*, given)), 0, length, &allocator, &bytes);
    if (status == h.BEAK_NOT_FOUND) return null;
    try beak.check(status);
    return beak.slice(bytes);
}

/// Whether the place `given` names anything — a file, a folder or a link.
pub fn exists(machine: Machine, arena: Allocator, given: []const u8) !bool {
    var stat: h.beak_stat = undefined;
    const status = h.beak_namespace_stat(machine.namespace, beak.bytes(try machine.pathOf(arena, given)), &stat);
    if (status == h.BEAK_NOT_FOUND) return false;
    try beak.check(status);
    return true;
}

/// The project the folder `given` is in, by its absolute path: the repository it is in, by its root, else the folder
/// itself — as the threads working in it are grouped, granted and trusted alike.
pub fn projectOf(machine: Machine, arena: Allocator, given: []const u8) ![]const u8 {
    return try machine.repositoryOf(arena, given) orelse try paths.resolve(arena, machine.base, given);
}

/// The folder under the person's home folder that a thread works in where it names none.
const default_workspace = "octoii";

/// The folder a thread that names none works in, made where it is missing; none where the host gives no machine or
/// knows no home folder.
pub fn defaultWorkspace(host: Host, arena: Allocator) !?[]const u8 {
    if (host.handle == null) return null;
    const home = host.home orelse return null;
    const folder = try std.fs.path.join(arena, &.{ home, default_workspace });
    const machine = try open(host, .{ .base = .{ .workspace = folder, .home = home } });
    defer machine.close();
    try beak.check(h.beak_namespace_mkdir(machine.namespace, beak.bytes(try machine.pathOf(arena, folder))));
    return folder;
}

/// The project a thread working in `workspace` belongs to, as the machine `host` gives finds it — the folder itself
/// where the host gives no machine; none for a thread that works in no folder.
pub fn projectAt(host: Host, arena: Allocator, workspace: ?[]const u8) !?[]const u8 {
    const folder = workspace orelse return null;
    const machine = open(host, .{ .base = .{ .workspace = folder, .home = host.home } }) catch |err| switch (err) {
        error.NoMachine => return folder,
        else => return err,
    };
    defer machine.close();
    return try machine.projectOf(arena, folder);
}

/// The repository the folder `given` is in, by its absolute path: the nearest folder from it up that holds `.git` — a
/// folder, or in a worktree a file; none where no folder does.
pub fn repositoryOf(machine: Machine, arena: Allocator, given: []const u8) !?[]const u8 {
    var folder: ?[]const u8 = try paths.resolve(arena, machine.base, given);
    while (folder) |at| : (folder = std.fs.path.dirname(at)) {
        if (try machine.exists(arena, try std.fs.path.join(arena, &.{ at, ".git" }))) return at;
    }
    return null;
}

/// The names in the folder `given`, in order, each with what it names, page by page; none where there is no such
/// folder.
pub fn list(machine: Machine, arena: *const Allocator, given: []const u8) ![]const h.beak_dirent {
    var out: std.ArrayList(h.beak_dirent) = .empty;
    var after: ?[]const u8 = null;
    while (true) {
        const entries = machine.page(arena, given, .{ .after = after, .limit = page_names }) catch |err| switch (err) {
            error.NotFound => return out.items,
            else => return err,
        };
        try out.appendSlice(arena.*, entries);
        if (entries.len < page_names) return out.items;
        after = beak.slice(entries[entries.len - 1].name);
    }
}

/// A page of the names in the folder `given`, as `range` picks them, each with what it names, as `getdents` reads on
/// from where it left off.
pub fn page(machine: Machine, arena: *const Allocator, given: []const u8, range: beak.Range) ![]const h.beak_dirent {
    const allocator = beak.outputs(arena);
    var entries: [*c]h.beak_dirent = null;
    var count: usize = 0;
    const path = beak.bytes(try machine.pathOf(arena.*, given));
    const asked = range.asked();
    try beak.check(h.beak_namespace_list(machine.namespace, path, &asked, &allocator, &entries, &count));
    return beak.items(h.beak_dirent, entries, count);
}

/// How many names a page of a folder holds at most, as the machine is listed whole.
const page_names = 256;

/// Which of `names`, each in the folder `given`, the ignore files leave out — those of the repository the folder is in,
/// from its root down, else those from the folder down, and beneath them those from outside it — as git's check-ignore
/// decides: `ignored[i]` for `names[i]`.
pub fn checkIgnore(machine: Machine, arena: Allocator, given: []const u8, names: []const []const u8, ignored: []bool) !void {
    const folder = try paths.resolve(arena, machine.base, given);
    const full = try arena.alloc(h.beak_bytes, names.len);
    for (names, full) |name, *each| each.* = beak.bytes(try machine.pathOf(arena, try std.fs.path.join(arena, &.{ folder, name })));
    const excludes = try beak.bytesAll(arena, try machine.excludesOf(arena, folder));
    try beak.check(h.beak_namespace_check_ignore(machine.namespace, beak.bytes(try machine.pathOf(arena, folder)), full.ptr, full.len, ignored.ptr, excludes.ptr, excludes.len));
}

/// The ignore files from outside the tree a walk from the folder `given` takes beneath the repository's own, by the
/// namespace's paths, as git reads them: the person's own, then the `info/exclude` of the repository the folder is in —
/// in its git directory, or for a worktree, whose `.git` names its own, in the directory its worktrees share.
pub fn excludesOf(machine: Machine, arena: Allocator, given: []const u8) ![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    if (machine.excludes) |file| try found.append(arena, try machine.pathOf(arena, file));
    if (try machine.repositoryOf(arena, given)) |repository| {
        if (try machine.commonGitDirectoryOf(arena, repository)) |git| try found.append(arena, try machine.pathOf(arena, try std.fs.path.join(arena, &.{ git, "info", "exclude" })));
    }
    return found.items;
}

/// The git directory the repository at `repository` shares with its worktrees, by its absolute path: its `.git` where
/// that is a folder; else the folder its `.git` file names by `gitdir:`, or the one that folder's `commondir` names.
fn commonGitDirectoryOf(machine: Machine, arena: Allocator, repository: []const u8) !?[]const u8 {
    const dot_git = try std.fs.path.join(arena, &.{ repository, ".git" });
    const named = machine.readAll(&arena, dot_git, 4096) catch |err| switch (err) {
        error.IsADirectory => return dot_git,
        else => return err,
    } orelse return null;
    const prefix = "gitdir:";
    const line = std.mem.trim(u8, named, " \t\r\n");
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const git = try paths.resolve(arena, .{ .workspace = repository, .home = machine.base.home }, std.mem.trim(u8, line[prefix.len..], " \t"));
    const common = try machine.readAll(&arena, try std.fs.path.join(arena, &.{ git, "commondir" }), 4096) orelse return git;
    return try paths.resolve(arena, .{ .workspace = git, .home = machine.base.home }, std.mem.trim(u8, common, " \t\r\n"));
}

/// A program to run to its end: its arguments, the program first, a bare name looked for along the machine's PATH as
/// execvp looks; the folder it runs in; the variables set over the machine's own; how long it may run; and how much of
/// its output is taken at most, past which it is ended.
pub const Program = struct {
    argv: []const []const u8,
    cwd: []const u8,
    variables: []const Variable = &.{},
    timeout_ms: u32 = 30_000,
    output_max: usize = 16 << 20,
};

/// A variable a program is given, over the machine's own.
pub const Variable = struct { name: []const u8, value: []const u8 };

/// How a program ran: how it ended, what it wrote to its output, whole, and the head and tail of what it wrote to its
/// errors.
pub const Ran = struct { ended: Exit, output: []const u8, errors: []const u8 };

/// How a program ended: the code it exited with, or the signal that ended it.
pub const Exit = union(enum) { code: i64, signal: i64 };

/// `program` run to its end on the machine, in a task that sleeps on `waits`: its output taken whole as it comes, its
/// errors kept. Refused `MissingProgram` where the machine has no such program; one that runs past its time is ended,
/// `TimedOut`, as is one that writes more than is taken, `OutputTooLarge`, and one a stop cut off, `Canceled`.
pub fn run(machine: Machine, io: std.Io, arena: Allocator, waits: *Waits, program: Program) !Ran {
    const argv = try beak.bytesAll(arena, program.argv);
    const variables = try arena.alloc(h.beak_label, program.variables.len);
    for (program.variables, variables) |variable, *label| label.* = .{ .name = beak.bytes(variable.name), .value = beak.bytes(variable.value) };
    var spawn = std.mem.zeroes(h.beak_spawn);
    spawn.machine = machine.handle;
    spawn.argv = argv.ptr;
    spawn.argv_count = argv.len;
    spawn.cwd = beak.bytes(program.cwd);
    spawn.variables = variables.ptr;
    spawn.variable_count = variables.len;
    spawn.mode = h.BEAK_SPAWN_COPROCESS;
    var command: h.beak_handle = 0;
    const spawned = h.beak_command_spawn(&spawn, &command);
    if (spawned == h.BEAK_NOT_FOUND and std.mem.eql(u8, beak.lastReason(), "missing-program")) return error.MissingProgram;
    try beak.check(spawned);
    defer _ = h.beak_close(command);
    try beak.check(h.beak_command_close_input(command));
    var output: Taken = .{ .arena = arena, .max = program.output_max };
    const ended: Exit = switch (try waitForEnd(io, arena, waits, command, program.timeout_ms, &output)) {
        .code => |code| .{ .code = code },
        .signal => |signal| .{ .signal = signal },
        .timed_out => return error.TimedOut,
    };
    const allocator = beak.outputs(&arena);
    var errors: h.beak_bytes = undefined;
    try beak.check(h.beak_command_output(command, &allocator, &errors));
    return .{ .ended = ended, .output = output.bytes.items, .errors = beak.slice(errors) };
}

/// What a program wrote to its output, taken whole as it comes, `max` bytes at most.
const Taken = struct {
    arena: Allocator,
    max: usize,
    bytes: std.ArrayList(u8) = .empty,

    pub fn take(taken: *Taken, bytes: []const u8) !void {
        if (taken.bytes.items.len + bytes.len > taken.max) return error.OutputTooLarge;
        try taken.bytes.appendSlice(taken.arena, bytes);
    }
};

/// What hears nothing of a command's output: one whose output is kept, read once it ends.
pub const unheard: struct {
    pub fn take(_: @This(), _: []const u8) !void {}
} = .{};

/// How a command ended: the code it exited with, the signal that ended it, or still running past its time, killed.
pub const Ended = union(enum) { code: i64, signal: i64, timed_out };

/// How often, at most, what a command delivers of its output is handed on while it runs, as a terminal draws a frame at
/// a time: what comes between is handed on together.
pub const heard_every_ms = 100;

/// Waits, sleeping on `waits`, till `command` ends, `timeout_ms` at most, as waitpid waits with an alarm set: what it
/// delivers of its output handed to `heard` as it comes, `heard_every_ms` apart at most — gathered in memory of
/// `allocator`'s between, each poll's events read in memory it lets go of after — and the last of it as it ends. A
/// command still running past its time is killed, its whole group; so is one a stop cuts the sleep off from,
/// `Canceled`, and one whose output `heard` refuses.
pub fn waitForEnd(io: std.Io, allocator: Allocator, waits: *Waits, command: h.beak_handle, timeout_ms: u32, heard: anytype) !Ended {
    const set = try waits.eventSet();
    try beak.check(h.beak_events_add(set, command));
    errdefer _ = h.beak_command_signal(command, h.BEAK_SIGNAL_KILL);
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + timeout_ms;
    var scratch: std.heap.ArenaAllocator = .init(allocator);
    defer scratch.deinit();
    var gathered: std.ArrayList(u8) = .empty;
    defer gathered.deinit(allocator);
    var handed_at: i64 = 0;
    while (true) {
        const now = std.Io.Clock.awake.now(io).toMilliseconds();
        if (now >= deadline) {
            _ = h.beak_command_signal(command, h.BEAK_SIGNAL_KILL);
            try heard.take(gathered.items);
            return .timed_out;
        }
        // What was gathered is handed on once its time comes, though nothing more comes.
        const due = if (gathered.items.len == 0) deadline else @max(now, handed_at + heard_every_ms);
        try waits.untilNews(@intCast(@min(deadline, due) - now));
        _ = scratch.reset(.retain_capacity);
        const arena = scratch.allocator();
        const outputs = beak.outputs(&arena);
        var events: [*c]h.beak_event = null;
        var count: usize = 0;
        var next: h.beak_optional = undefined;
        try beak.check(h.beak_events_poll(set, std.Io.Clock.real.now(io).toMilliseconds(), &outputs, &events, &count, &next));
        for (beak.items(h.beak_event, events, count)) |event| {
            if (event.handle != command) continue;
            switch (event.type) {
                h.BEAK_EVENT_OUTPUT => try gathered.appendSlice(allocator, beak.slice(event.bytes)),
                h.BEAK_EVENT_EXIT => {
                    try heard.take(gathered.items);
                    if (beak.get(event.signal)) |signal| return .{ .signal = signal };
                    return .{ .code = beak.get(event.code) orelse 0 };
                },
                else => {},
            }
        }
        const after = std.Io.Clock.awake.now(io).toMilliseconds();
        if (gathered.items.len > 0 and after >= handed_at + heard_every_ms) {
            try heard.take(gathered.items);
            gathered.clearRetainingCapacity();
            handed_at = after;
        }
    }
}

/// Where the machine's tree begins, as its absolute paths are written.
pub const root = "/";

test {
    _ = paths;
}
