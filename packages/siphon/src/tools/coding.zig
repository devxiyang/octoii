//! The `coding` tools: read, write, edit, glob and grep on the files of the machine a thread works on — its whole tree
//! mounted as the root of a namespace of Beak's for the call — through Beak's file operations, which do the work where
//! the files are; and shell, a command line run in the thread's workspace on the machine. A path is taken and shown as
//! `Machine` has it. What the model reads of their results is made here: what Beak gives, as it gives it, with the notes
//! that tell what it leaves out and how to go on; what Beak throws, as it throws it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const typebox = @import("typebox");
const beak = @import("../beak.zig");
const h = beak.h;
const Tool = @import("Tool.zig");
const Table = @import("Table.zig");
const threads = @import("../threads.zig");
const log = threads.log;
const Machine = @import("../machine.zig");
const files = Machine.files;
const text = @import("../text.zig");
const commands = @import("commands.zig");

/// Adds the coding tools to `table`.
pub fn register(table: *Table) !void {
    for (all) |tool| try table.add(tool);
}

/// What a path argument is, as every tool that takes one tells it.
const path_is = "relative to the workspace, or absolute; ~ the home folder";

const all = [_]Tool{
    .{
        .name = "read",
        .description = "Reads a file as it is, a page of lines at a time, or lists a directory, a / after each directory's name. A note after the text tells what the page leaves out: the lines it holds and the offset to read on from, lines cut for their length. An image, a PDF or a binary file is named for what it is, not shown.",
        .parameters = typebox.of(ReadArguments),
        .work = .{ .task = read },
    },
    .{
        .name = "write",
        .description = "Writes a file whole, making it and its directories where they are missing; gives how many lines it added and took out.",
        .parameters = typebox.of(WriteArguments),
        .access = editAccess,
        .work = .{ .task = write },
    },
    .{
        .name = "edit",
        .description = "Replaces text in a file: `old` must match one place, or every place with `all`. It is matched exactly, else with typographic characters (curly quotes, dashes, special spaces) read as plain ones, else line by line with trailing whitespace ignored, a match not exact noted with its tier. Gives the change as a unified diff. A refusal gives its reason: empty, same (`new` is `old`), not-found (`old` is nowhere in the file), unchanged, many (with how many places matched: give more of `old`, or set `all`).",
        .parameters = typebox.of(EditArguments),
        .access = editAccess,
        .work = .{ .task = edit },
    },
    .{
        .name = "glob",
        .description = "Finds the files under a directory whose paths match a glob, honouring ignore files: their paths one to a line, the newest first.",
        .parameters = typebox.of(GlobArguments),
        .work = .{ .task = glob },
    },
    .{
        .name = "grep",
        .description = "Finds the lines a regular expression matches in the files under a directory, or in one file, honouring ignore files: each as path:line: text, a line around it as path:line- text. Binary files and files too large to search are skipped, and counted.",
        .parameters = typebox.of(GrepArguments),
        .work = .{ .task = grep },
    },
    .{
        .name = "shell",
        .description = "Runs a command line in the workspace, in the machine's shell — bash on macOS and Linux, PowerShell on Windows — its input closed; gives its output, the head and the newest tail of a long one, and a note of how it ended: its exit code, the signal that ended it, or its time run out. In the default mode a command runs in a sandbox that writes the workspace and the temporary folders alone; one that must write beyond them — install a package for the machine, write elsewhere — is run again with escalate and a justification, and the person decides.",
        .parameters = typebox.of(ShellArguments),
        .access = shellAccess,
        .work = .{ .task = shell },
    },
};

/// What a call of write or edit does: edits the file its path names; granted always, every edit of the thread goes
/// ahead.
fn editAccess(arena: Allocator, base: ?Machine.paths.Base, arguments: []const u8) anyerror!Tool.Access {
    const given = try std.json.parseFromSliceLeaky(struct { path: []const u8 }, arena, arguments, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    const place = try Machine.paths.resolve(arena, base orelse return error.NoWorkspace, given.path);
    return .{ .action = .edit, .resources = try arena.dupe([]const u8, &.{place}), .save = &.{"*"} };
}

/// What a call of shell does: runs the simple commands of its line — beyond the sandbox, where it asks to; reading
/// alone, where each of them reads and nothing else.
fn shellAccess(arena: Allocator, _: ?Machine.paths.Base, arguments: []const u8) anyerror!Tool.Access {
    const given = try foundation.json.decode(ShellArguments, arena, arguments);
    const line = try commands.read(arena, given.command);
    return .{ .action = .command, .resources = line.resources, .save = line.save, .escalate = given.escalate, .justification = given.justification, .reads_alone = line.reads_alone };
}

/// What `read` is called with.
const ReadArguments = struct {
    path: []const u8,
    offset: ?u64 = null,
    limit: ?u64 = null,

    pub const schema = .{
        .path = .{ .description = "The file or directory, " ++ path_is },
        .offset = .{ .description = "The first line, or entry, from 1", .minimum = 1 },
        .limit = .{ .description = "How many lines, or entries", .minimum = 1 },
    };
};

fn read(_: ?*anyopaque, run: *const Tool.Run) anyerror!Tool.Output {
    const given = try foundation.json.decode(ReadArguments, run.arena, run.arguments);
    const machine = try run.openMachine();
    defer machine.close();
    const path = try machine.pathOf(run.arena, given.path);
    var bounds: text.Bounds = .{ .line_chars_max = line_chars_max };
    if (given.offset) |offset| bounds.offset = @max(1, offset);
    if (given.limit) |limit| bounds.limit = @max(1, limit);
    const found = machine.readFile(run.arena, path, .{ .bounds = bounds, .media_bytes_max = threads.stored.bytes_max }) catch |err| return refusedBy(run.arena, err);
    var notes: Tool.Notes = .{ .arena = run.arena };
    // A name read as the one entry of its canonical form is told, as the model wrote another.
    if (!std.mem.eql(u8, found.pathOf(), path)) try notes.add("read as {s}", .{try machine.shown(run.arena, found.pathOf())});
    switch (found) {
        .text => |page| return textPage(run.arena, page, &notes),
        .directory => |page| return directoryPage(run.arena, page, &notes),
        .image => |image| return imagePage(run, image, &notes),
        .pdf => |pdf| try notes.add("application/pdf {d} bytes: not shown", .{pdf.bytes.len}),
        .binary => try notes.add("binary: not shown", .{}),
        .past_end => |past| return refused(run.arena, "invalid: past-end: {d}", .{past.count}),
        .too_large => |large| return refused(run.arena, "too-large: {d} bytes; limit {d}", .{ large.size, large.limit }),
    }
    return .{ .text = "", .notes = notes.list.items };
}

/// A call refused, with what it was refused for, as a failure is told.
fn refused(arena: Allocator, comptime format: []const u8, arguments: anytype) !Tool.Output {
    return .{ .outcome = .refused, .text = try arena.print(format, arguments) };
}

/// A call refused for what the namespace failed with, as Beak tells it.
fn refusedBy(arena: Allocator, err: beak.Error) !Tool.Output {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return .{ .outcome = .refused, .text = try beak.told(arena, err) };
}

/// An image read, kept as a model is given one and handed the model as that file; noted as what the file is and how
/// large, and what the model is shown where that differs — or, where it does not decode, as what it was told to be and
/// why it is not shown.
fn imagePage(run: *const Tool.Run, image: files.Media, notes: *Tool.Notes) !Tool.Output {
    const kept = threads.stored.keepImage(run.runtime, run.arena, image.bytes) catch |err| {
        const why = switch (err) {
            error.NotAnImage, error.Malformed => "does not decode",
            error.TooLarge => "too large to decode",
            else => return err,
        };
        try notes.add("{s} {d} bytes, which {s}: not shown", .{ image.media_type, image.bytes.len, why });
        return .{ .text = "", .notes = notes.list.items };
    };
    const shown = kept.image;
    if (std.mem.eql(u8, shown.media_type, image.media_type) and std.meta.eql(shown.size, shown.original)) {
        try notes.add("{s} {d}x{d}", .{ image.media_type, shown.size.width, shown.size.height });
    } else try notes.add("{s} {d}x{d}, shown as {s} {d}x{d}", .{ image.media_type, shown.original.width, shown.original.height, shown.media_type, shown.size.width, shown.size.height });
    const handed = try run.arena.dupe(log.OutputFile, &.{.{ .ref = kept.ref, .media_type = shown.media_type }});
    return .{ .text = "", .notes = notes.list.items, .files = handed };
}

/// A page of a text file: its lines as they are; notes of what it leaves out — the lines it holds where the file goes
/// on past them, or where it starts within the file — and of the lines cut for their length.
fn textPage(arena: Allocator, page: files.TextPage, notes: *Tool.Notes) !Tool.Output {
    var out: std.Io.Writer.Allocating = .init(arena);
    var cut: std.Io.Writer.Allocating = .init(arena);
    for (page.lines) |line| {
        try out.writer.print("{s}\n", .{line.text});
        if (line.cut) try cut.writer.print("{s}{d}", .{ if (cut.written().len > 0) ", " else "", line.number });
    }
    if (page.lines.len == 0) {
        try notes.add("empty", .{});
    } else {
        const last = page.from + page.lines.len - 1;
        if (page.more) {
            try notes.add("lines {d}-{d}; more from offset {d}", .{ page.from, last, last + 1 });
        } else if (page.from > 1) {
            if (page.line_count) |total| try notes.add("lines {d}-{d} of {d}", .{ page.from, last, total });
        }
    }
    if (cut.written().len > 0) try notes.add("lines cut at {d} characters: {s}", .{ line_chars_max, cut.written() });
    return .{ .text = out.written(), .notes = notes.list.items };
}

/// A page of a directory: its names, a / after each directory's; a note of the entries it holds where there are more.
fn directoryPage(arena: Allocator, page: files.FolderPage, notes: *Tool.Notes) !Tool.Output {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (page.entries) |entry| try out.writer.print("{s}{s}\n", .{ beak.slice(entry.name), if (entry.type == h.BEAK_ENTRY_DIRECTORY) "/" else "" });
    if (page.entries.len == 0) try notes.add("empty", .{});
    if (page.more) {
        const last = page.from + page.entries.len - 1;
        try notes.add("entries {d}-{d} of {d}; more from offset {d}", .{ page.from, last, page.total, last + 1 });
    }
    return .{ .text = out.written(), .notes = notes.list.items };
}

/// What `write` is called with.
const WriteArguments = struct {
    path: []const u8,
    content: []const u8,

    pub const schema = .{
        .path = .{ .description = "The file, " ++ path_is },
        .content = .{ .description = "What the file holds after" },
    };
};

fn write(_: ?*anyopaque, run: *const Tool.Run) anyerror!Tool.Output {
    const given = try foundation.json.decode(WriteArguments, run.arena, run.arguments);
    const machine = try run.openMachine();
    defer machine.close();
    const path = try machine.pathOf(run.arena, given.path);
    const shown = try machine.shown(run.arena, path);
    const written = machine.writeFile(run.arena, path, given.content, shown) catch |err| return refusedBy(run.arena, err);
    const change = switch (written) {
        .written => |change| change,
        .directory => return refused(run.arena, "is-a-directory", .{}),
    };
    if (change.created) return .{ .text = try run.arena.print("created {s} +{d}", .{ shown, change.additions }) };
    return .{ .text = try run.arena.print("wrote {s} +{d} -{d}", .{ shown, change.additions, change.deletions }) };
}

/// What `edit` is called with.
const EditArguments = struct {
    path: []const u8,
    old: []const u8,
    new: []const u8,
    all: bool = false,

    pub const schema = .{
        .path = .{ .description = "The file, " ++ path_is },
        .old = .{ .description = "The text to replace, as read gives it" },
        .new = .{ .description = "The text to put in its place" },
        .all = .{ .description = "Replace every match" },
    };
};

fn edit(_: ?*anyopaque, run: *const Tool.Run) anyerror!Tool.Output {
    const given = try foundation.json.decode(EditArguments, run.arena, run.arguments);
    const machine = try run.openMachine();
    defer machine.close();
    const path = try machine.pathOf(run.arena, given.path);
    const shown = try machine.shown(run.arena, path);
    const result = machine.editFile(run.arena, path, .{ .old = given.old, .new = given.new, .all = given.all }, shown) catch |err| return refusedBy(run.arena, err);
    const made = switch (result) {
        .made => |made| made,
        // An edit refused fails with its reason — `many` with how many matched; a file that is not there, a folder or
        // no text fails as what it is.
        .refused => |why| return switch (why) {
            .many => |count| refused(run.arena, "refused: many: {d}", .{count}),
            else => refused(run.arena, "refused: {s}", .{why.reasonOf()}),
        },
        .missing => return refused(run.arena, "not-found", .{}),
        .directory => return refused(run.arena, "is-a-directory", .{}),
        .not_text => return refused(run.arena, "unsupported: not-text", .{}),
    };
    var notes: Tool.Notes = .{ .arena = run.arena };
    if (made.tier != .exact) try notes.add("tier {s}", .{@tagName(made.tier)});
    if (made.replacements > 1) try notes.add("replacements {d}", .{made.replacements});
    return .{ .text = made.change.diff, .notes = notes.list.items };
}

/// What `glob` is called with.
const GlobArguments = struct {
    pattern: []const u8,
    path: []const u8 = "",
    offset: ?u64 = null,

    pub const schema = .{
        .pattern = .{ .description = "A glob, as src/**/*.zig" },
        .path = .{ .description = "The directory to look under, " ++ path_is ++ "; the workspace unless given" },
        .offset = .{ .description = "The first file, from 1, the newest first", .minimum = 1 },
    };
};

fn glob(_: ?*anyopaque, run: *const Tool.Run) anyerror!Tool.Output {
    const given = try foundation.json.decode(GlobArguments, run.arena, run.arguments);
    const machine = try run.openMachine();
    defer machine.close();
    const excludes = try beak.bytesAll(run.arena, try machine.excludesOf(run.arena, given.path));
    const offset: usize = @intCast(@max(1, given.offset orelse 1) - 1);
    var walk = std.mem.zeroes(h.beak_walk);
    walk.glob = beak.bytes(given.pattern);
    walk.newest_first = true;
    walk.offset = offset;
    walk.limit = files_page;
    walk.excludes = excludes.ptr;
    walk.exclude_count = excludes.len;
    const allocator = beak.outputs(&run.arena);
    var found: h.beak_found_files = undefined;
    if (try beak.failed(run.arena, h.beak_namespace_glob(machine.namespace, beak.bytes(try machine.pathOf(run.arena, given.path)), &walk, &allocator, &found))) |thrown| return .{ .outcome = .refused, .text = thrown };
    if (found.count == 0 and found.total > 0) return refused(run.arena, "invalid: past-end: {d}", .{found.total});
    var out: std.Io.Writer.Allocating = .init(run.arena);
    for (beak.items(h.beak_bytes, found.files, found.count)) |file| try out.writer.print("{s}\n", .{try machine.shown(run.arena, beak.slice(file))});
    var notes: Tool.Notes = .{ .arena = run.arena };
    if (found.total == 0) try notes.add("no match", .{});
    const last = offset + found.count;
    if (last < found.total) {
        try notes.add("files {d}-{d} of {d}, the newest first; more from offset {d}", .{ offset + 1, last, found.total, last + 1 });
    } else if (offset > 0) try notes.add("files {d}-{d} of {d}", .{ offset + 1, last, found.total });
    try noteDenied(machine, &notes, beak.items(h.beak_bytes, found.denied, found.denied_count));
    return .{ .text = out.written(), .notes = notes.list.items };
}

/// What `grep` is called with.
const GrepArguments = struct {
    pattern: []const u8,
    path: []const u8 = "",
    glob: []const u8 = "",
    literal: bool = false,
    case_insensitive: bool = false,
    context: usize = 0,
    offset: ?u64 = null,

    pub const schema = .{
        .pattern = .{ .description = "A PCRE2 pattern, or plain text with literal" },
        .path = .{ .description = "The directory or file to look in, " ++ path_is ++ "; the workspace unless given" },
        .glob = .{ .description = "Only files whose paths match it" },
        .context = .{ .description = "Lines shown around each match", .minimum = 0 },
        .offset = .{ .description = "The first matching line, from 1, the files in order by path", .minimum = 1 },
    };
};

fn grep(_: ?*anyopaque, run: *const Tool.Run) anyerror!Tool.Output {
    const given = try foundation.json.decode(GrepArguments, run.arena, run.arguments);
    const machine = try run.openMachine();
    defer machine.close();
    const excludes = try beak.bytesAll(run.arena, try machine.excludesOf(run.arena, given.path));
    const offset: usize = @intCast(@max(1, given.offset orelse 1) - 1);
    var options = std.mem.zeroes(h.beak_grep_options);
    options.literal = given.literal;
    options.case_insensitive = given.case_insensitive;
    options.context = given.context;
    options.line_chars_max = grep_line_chars_max;
    options.offset = offset;
    options.limit = matches_page;
    options.walk.glob = beak.bytes(given.glob);
    options.walk.excludes = excludes.ptr;
    options.walk.exclude_count = excludes.len;
    const allocator = beak.outputs(&run.arena);
    var grepped: h.beak_grepped = undefined;
    if (try beak.failed(run.arena, h.beak_namespace_grep(machine.namespace, beak.bytes(try machine.pathOf(run.arena, given.path)), beak.bytes(given.pattern), &options, &allocator, &grepped))) |thrown| return .{ .outcome = .refused, .text = thrown };
    var out: std.Io.Writer.Allocating = .init(run.arena);
    var matched: usize = 0;
    var cut = false;
    for (beak.items(h.beak_grep_file, grepped.files, grepped.count)) |file| {
        const shown = try machine.shown(run.arena, beak.slice(file.path));
        for (beak.items(h.beak_grep_line, file.lines, file.line_count)) |line| {
            try out.writer.print("{s}:{d}{s}{s}\n", .{ shown, line.number, if (line.match) ": " else "- ", beak.slice(line.text) });
            if (line.match) matched += 1;
            if (line.cut) cut = true;
        }
    }
    var notes: Tool.Notes = .{ .arena = run.arena };
    if (matched == 0) try notes.add("no match", .{});
    if (grepped.more) {
        try notes.add("matches {d}-{d}; more from offset {d}", .{ offset + 1, offset + matched, offset + matched + 1 });
    } else if (offset > 0 and matched > 0) try notes.add("matches {d}-{d}", .{ offset + 1, offset + matched });
    if (cut) try notes.add("lines cut at {d} characters", .{grep_line_chars_max});
    if (grepped.binary > 0) try notes.add("{d} binary files passed over", .{grepped.binary});
    try noteDenied(machine, &notes, beak.items(h.beak_bytes, grepped.denied, grepped.denied_count));
    return .{ .text = out.written(), .notes = notes.list.items };
}

/// A note of the directories a walk went past, as their access was denied, by their paths as the model reads them.
fn noteDenied(machine: Machine, notes: *Tool.Notes, denied: []const h.beak_bytes) !void {
    if (denied.len == 0) return;
    var out: std.Io.Writer.Allocating = .init(notes.arena);
    for (denied, 0..) |directory, i| try out.writer.print("{s}{s}", .{ if (i > 0) ", " else "", try machine.shown(notes.arena, beak.slice(directory)) });
    try notes.add("skipped {d} directories, access-denied: {s}", .{ denied.len, out.written() });
}

/// What `shell` is called with.
const ShellArguments = struct {
    command: []const u8,
    timeout_seconds: u32 = shell_timeout_seconds,
    escalate: bool = false,
    justification: ?[]const u8 = null,

    pub const schema = .{
        .command = .{ .description = "The command line" },
        .timeout_seconds = .{ .description = std.fmt.comptimePrint("How long it may run; {d} unless given", .{shell_timeout_seconds}), .minimum = 1, .maximum = 600 },
        .escalate = .{ .description = "Run it beyond the sandbox, once the person lets it" },
        .justification = .{ .description = "Why it must write beyond the sandbox, in a sentence the person reads" },
    };
};

fn shell(_: ?*anyopaque, run: *const Tool.Run) anyerror!Tool.Output {
    const given = try foundation.json.decode(ShellArguments, run.arena, run.arguments);
    const manifest = try threads.manifestOf(run.runtime.volume, &run.arena, try threads.pathOf(run.arena, run.thread));
    const workspace = manifest.workspace orelse return error.NoWorkspace;
    var spawn = std.mem.zeroes(h.beak_spawn);
    spawn.machine = run.host.machine.handle orelse return error.NoMachine;
    spawn.shell = beak.bytes(given.command);
    spawn.cwd = beak.bytes(workspace);
    // Kept within the system's sandbox, where the machine sandboxes commands: writing where its call's weighing let it,
    // reaching nothing the host keeps for itself.
    var sandbox = std.mem.zeroes(h.beak_sandbox);
    if (run.host.machine.sandboxes) {
        const writable = try beak.bytesAll(run.arena, switch (run.writes) {
            .workspace => try std.mem.concat(run.arena, []const u8, &.{ &.{workspace}, run.host.machine.temporary }),
            .anywhere => &.{Machine.root},
        });
        const inaccessible = try beak.bytesAll(run.arena, run.host.machine.hidden);
        sandbox.write = writable.ptr;
        sandbox.write_count = writable.len;
        sandbox.inaccessible = inaccessible.ptr;
        sandbox.inaccessible_count = inaccessible.len;
        sandbox.network = true;
        spawn.sandbox = &sandbox;
    }
    // All of its output is logged, where the host keeps outputs, so the line Beak puts where it left bytes out says
    // where they are.
    if (run.host.outputs) |folder| {
        spawn.log_path = beak.bytes(try std.fs.path.join(run.arena, &.{ folder, try std.mem.concat(run.arena, u8, &.{ run.key, ".log" }) }));
        spawn.log_bytes_max = log_bytes_max;
    }
    var command: h.beak_handle = 0;
    if (try beak.failed(run.arena, h.beak_command_spawn(&spawn, &command))) |thrown| return .{ .outcome = .refused, .text = thrown };
    defer _ = h.beak_close(command);
    // What it prints is told as it comes, for those who follow the thread; the model reads all of it once it ends.
    var telling: Telling = .{ .run = run, .scratch_arena = .init(run.arena) };
    defer telling.scratch_arena.deinit();
    const ended = try Machine.waitForEnd(run.runtime.host.io, run.arena, run.waits, command, given.timeout_seconds * std.time.ms_per_s, &telling);
    const allocator = beak.outputs(&run.arena);
    var output: h.beak_bytes = undefined;
    try beak.check(h.beak_command_output(command, &allocator, &output));
    var notes: Tool.Notes = .{ .arena = run.arena };
    switch (ended) {
        .code => |code| try notes.add("exit {d}", .{code}),
        .signal => |signal| try notes.add("signal {d}", .{signal}),
        .timed_out => try notes.add("timed out after {d} s; killed", .{given.timeout_seconds}),
    }
    return .{ .text = beak.slice(output), .notes = notes.list.items };
}

/// What hears a command's output as it comes and tells it on its run's stream as text: its bytes as UTF-8, a character
/// cut short at the end of what came held for what comes next, any bytes that are no UTF-8 told as U+FFFD.
const Telling = struct {
    run: *const Tool.Run,
    held: std.ArrayList(u8) = .empty,
    scratch_arena: std.heap.ArenaAllocator,

    pub fn take(telling: *Telling, bytes: []const u8) !void {
        try telling.held.appendSlice(telling.run.arena, bytes);
        const held = telling.held.items;
        const whole = wholeLength(held);
        if (whole == 0) return;
        _ = telling.scratch_arena.reset(.retain_capacity);
        const scratch_arena = telling.scratch_arena.allocator();
        try telling.run.tell(scratch_arena, try scratch_arena.print("{f}", .{std.unicode.fmtUtf8(held[0..whole])}));
        std.mem.copyForwards(u8, held[0 .. held.len - whole], held[whole..]);
        telling.held.shrinkRetainingCapacity(held.len - whole);
    }
};

/// How many of `bytes` hold whole characters: all but a last one cut short, as output that comes in pieces may cut it.
fn wholeLength(bytes: []const u8) usize {
    var back: usize = 1;
    while (back <= @min(3, bytes.len)) : (back += 1) {
        const byte = bytes[bytes.len - back];
        // A continuation byte belongs to the character a byte before it begins.
        if (byte & 0xc0 == 0x80) continue;
        const length = std.unicode.utf8ByteSequenceLength(byte) catch return bytes.len;
        return if (length > back) bytes.len - back else bytes.len;
    }
    return bytes.len;
}

/// How long a command may run unless its call says.
const shell_timeout_seconds = 120;

/// The most bytes of a command's output its log keeps.
const log_bytes_max = 64 << 20;

/// How many files a glob shows at most.
/// How many files a page of glob gives, and matching lines a page of grep; how many characters of a line grep shows.
const files_page = 200;
const matches_page = 250;
const grep_line_chars_max = 500;
/// How many characters of a line a read shows; past them the line is cut.
const line_chars_max = 2000;

test "of output that comes in pieces, the bytes that hold whole characters: a last one cut short held back" {
    try std.testing.expectEqual(@as(usize, 3), wholeLength("abc"));
    // é is two bytes, € three: cut after the first, or the second, they wait for the rest.
    try std.testing.expectEqual(@as(usize, 1), wholeLength("a\xc3"));
    try std.testing.expectEqual(@as(usize, 3), wholeLength("a\xc3\xa9"));
    try std.testing.expectEqual(@as(usize, 1), wholeLength("a\xe2\x82"));
    try std.testing.expectEqual(@as(usize, 4), wholeLength("a\xe2\x82\xac"));
    // A byte no character begins with is told as it is, made U+FFFD as it is told.
    try std.testing.expectEqual(@as(usize, 2), wholeLength("a\xff"));
}
