//! What a thread's model is told of itself, of where it works and of what it may call, one text for every model: the
//! sections — the base every turn starts from; the instructions it follows, which always apply, given whole; the skills
//! it may use, each told by what it is for and read when a task calls for it; the catalog of its MCP servers' tools,
//! which its scripts call; and the environment the thread works in, in that order, the most shared first, so a
//! provider's cache of the beginning serves one thread as well as the next — and the tools it may call. Where its
//! project names servers the person has not decided to trust, gathering finds what to ask them, and the thread's main
//! fiber has them asked. Before each turn a `context` request has its sources gather them, in a task of its own, as
//! they are read through the machine; the thread's main fiber appends the sections that changed to the log as a system
//! entry, so the model is told each change once, where it came, and what it was told stays in the log as it was sent.
//! The tools a window of the conversation declares are those of the entry that begins it: a change of them takes effect
//! from the next window, so what a window begins with is never changed within it, and no provider's cache of it is lost
//! till the conversation is compacted.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const ai = @import("ai");
const runtime_ = @import("../runtime.zig");
const Runtime = runtime_.Runtime;
const Request = runtime_.Request;
const Phase = runtime_.Phase;
const threads = @import("../threads.zig");
const log = threads.log;
const Window = threads.Window;
const beak = @import("../beak.zig");
const Machine = @import("../machine.zig");
const tools = @import("../tools.zig");
const Table = tools.Table;
const trust = tools.trust;
const skills = @import("skills.zig");

/// The name of a context request.
pub const context_request = "context";

/// What a context request asks: the sections the model of the thread `thread`, by its id, is told now.
pub const ContextRequest = struct { thread: []const u8 };

/// Has what the model of the thread at `thread` is told now gathered, by a context request made with the phase's
/// commit: its key, whose mail answers it.
pub fn gather(phase: *Phase, thread: []const u8) ![]const u8 {
    const key = try phase.mint();
    try phase.request(context_request, key, ContextRequest{ .thread = threads.idOf(thread) });
    return key;
}

/// What the model is told: its sections, and the tools it may call; and what the person is asked to trust, as what it
/// would be told of names what they have not decided on.
pub const Told = struct { sections: []const log.Section = &.{}, tools: []const vocabulary.Tool = &.{}, asked: ?trust.Asked = null };

/// Where what the model is told comes from: the tools' table — Siphon's tools, the servers' catalog, and the machine a
/// thread works on — the models' facts, and the person's own instructions and skills, for every project, by their
/// absolute paths on the machine; none of either where the host keeps none.
pub const Sources = struct {
    table: *Table,
    /// The models, whose facts say what each runs for itself, as its provider's web search.
    models: *ai.Models,
    instructions: ?[]const u8 = null,
    skills: ?[]const u8 = null,
};

/// Acts on every context request by gathering the sections from `sources`.
pub fn register(runtime: *Runtime, sources: *Sources) !void {
    try runtime.handle(context_request, .{ .context = sources, .act = act });
}

fn act(context: ?*anyopaque, request: *Request) anyerror!void {
    const sources: *Sources = @ptrCast(@alignCast(context.?));
    const arena = request.arena();
    const asked = try foundation.json.decode(ContextRequest, arena, request.payload);
    try request.answer(try gathered(sources, arena, asked.thread));
}

/// What a source of what the model is told is given, and gathers its sections into: the thread, by its id, and the
/// machine it works on, where it works in a folder of one.
const Gathering = struct {
    runtime: *Runtime,
    sources: *const Sources,
    arena: Allocator,
    tid: []const u8,
    manifest: threads.Manifest,
    machine: ?Machine,
    sections: std.ArrayList(log.Section) = .empty,
    tools: std.ArrayList(vocabulary.Tool) = .empty,
    asked: ?trust.Asked = null,

    fn add(gathering: *Gathering, name: []const u8, text: []const u8) !void {
        try gathering.sections.append(gathering.arena, .{ .name = name, .text = text });
    }
};

/// The steps of gathering what the model is told, in the order it is told it: each adds its sections and tools, where it
/// has any.
const steps = [_]*const fn (*Gathering) anyerror!void{ gatherBase, gatherInstructions, gatherSkills, gatherCatalog, gatherEnvironment, gatherThreads, gatherTools, gatherHosted };

/// What the model of the thread `tid` is told now, as its sources gather it.
pub fn gathered(sources: *const Sources, arena: Allocator, tid: []const u8) !Told {
    const runtime = sources.table.runtime;
    const host = sources.table.host.machine;
    const manifest = try threads.manifestOf(runtime.volume, &arena, try threads.pathOf(arena, tid));
    const machine: ?Machine = if (manifest.workspace != null and host.handle != null) try .open(host, .{ .base = .{ .workspace = manifest.workspace.?, .home = host.home } }) else null;
    defer if (machine) |opened| opened.close();
    var gathering: Gathering = .{ .runtime = runtime, .sources = sources, .arena = arena, .tid = tid, .manifest = manifest, .machine = machine };
    for (steps) |step| try step(&gathering);
    return .{ .sections = gathering.sections.items, .tools = gathering.tools.items, .asked = gathering.asked };
}

/// The tools Siphon has that the thread is offered, as the model is told of them.
fn gatherTools(gathering: *Gathering) !void {
    try gathering.tools.appendSlice(gathering.arena, try gathering.sources.table.definitions(gathering.arena, &gathering.manifest));
}

/// The tools the thread's model runs for itself, where its facts say it does: its provider's web search, which the
/// model calls as it needs and whose results come back in its reply.
fn gatherHosted(gathering: *Gathering) !void {
    const reference = gathering.manifest.model orelse return;
    const served = try gathering.sources.models.find(gathering.arena, reference) orelse return;
    if (searches(served.model)) try gathering.tools.append(gathering.arena, .{ .web_search = .{} });
}

/// Whether `model`'s facts say it searches the web itself.
pub fn searches(model: ai.Model) bool {
    const hosted = model.octoii.hosted_tools orelse return false;
    for (hosted) |tool| if (tool == .web_search) return true;
    return false;
}

fn gatherBase(gathering: *Gathering) !void {
    try gathering.add("base", base);
}

/// What every model is told first, whatever it is.
const base =
    \\You are a coding agent in Octoii, working on the person's machine through your tools. Help the person do what they ask.
    \\
    \\Your tools' results:
    \\- A tool gives what it gave as it is. A line in brackets after it is a note on it: what it leaves out and how to go on, how a command ended, how an edit matched.
    \\- A failure is given as the system gives it: its code, then its reason and detail where it has them, as `not-found`, `refused: many: 3` or `invalid: bad-pattern: missing closing parenthesis (offset 5)`.
    \\- A relative path starts at the workspace, as a shell's does, and a path a tool gives is one you can give back as it is.
    \\
    \\Working:
    \\- Follow the instructions in <instructions>: the person's own, for every project, then each folder's AGENTS.md from the root down to the workspace. Where they differ, the later one holds.
    \\- Each <skill> is a file of instructions for one kind of task, told by its name and what it is for: before a task of that kind, read its file and follow it.
    \\- A <recap> stands for the conversation before it, which grew too long to keep: carry on from where it says the work stands, and read again any file you need as it is now.
    \\- Prefer the file tools to the shell for reading, writing and searching files.
    \\- Keep a change in the structure, naming and style of the code around it.
    \\- Take changes you did not make for the person's work: look before you overwrite or delete them, and ask before what cannot be undone.
    \\- Say plainly what you found and what you did, naming files by their paths.
    \\- To show the person an image file, write it in your reply as Markdown, `![what it is](path)`, the path as your tools take it: they see it, and you do not. To point them at a page of the thread's browser, write `::page{id="its id"}` on a line of its own.
;

fn gatherEnvironment(gathering: *Gathering) !void {
    const sandboxes = gathering.sources.table.host.machine.sandboxes;
    try gathering.add("environment", try environmentOf(gathering.arena, gathering.manifest, sandboxes, gathering.runtime.now()));
}

/// The environment a thread works in, as the model is told it: its workspace, the platform and shell its commands run
/// on — this machine's, as Siphon runs on the machine it works on — what its mode lets its calls do, on a machine that
/// sandboxes commands or not, and the day, in UTC.
fn environmentOf(arena: Allocator, manifest: threads.Manifest, sandboxes: bool, now_ms: i64) ![]const u8 {
    const day = (std.time.epoch.EpochSeconds{ .secs = @intCast(@divFloor(now_ms, std.time.ms_per_s)) }).getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    try writer.writeAll("<environment>\n");
    if (manifest.workspace) |folder| try writer.print("workspace: {s}\n", .{folder});
    try writer.print("platform: {t} {t}\nshell: {s}\n", .{ builtin.target.os.tag, builtin.target.cpu.arch, if (builtin.target.os.tag == .windows) "powershell" else "bash" });
    try writer.print("permissions: {s}\n", .{permissionsOf(manifest.mode, sandboxes)});
    try writer.print("date: {d}-{d:0>2}-{d:0>2} (UTC)\n</environment>", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1 });
    return out.written();
}

/// What a thread's mode lets its calls do, as the model is told it, on a machine that sandboxes commands or not.
fn permissionsOf(mode: threads.Mode, sandboxes: bool) []const u8 {
    return switch (mode) {
        .default => if (sandboxes)
            "default — edits within the workspace go ahead, and commands run in a sandbox that writes the workspace and the temporary folders alone. An edit beyond the workspace, a command that must write beyond the sandbox — run it with escalate and a justification — and a tool of a server wait for the person to let them, but what they let the project do always. A call they reject comes back with their words."
        else
            "default — edits within the workspace go ahead. This machine has no sandbox for commands: each command, an edit beyond the workspace and a tool of a server wait for the person to let them, but what they let the project do always. A call they reject comes back with their words.",
        .auto => "auto — edits within the workspace and commands that only read go ahead; every other call is judged first, by a second model or by the person, but what the person let the project do always. A call blocked comes back with why: find a safer way within what the person asked, or ask them.",
        .@"full-access" => "full-access — every call goes ahead as you make it.",
    };
}

/// Where the threads are, as the model is told it, where the host lays them out: each a folder by its id, read alone
/// through the file tools; and this thread's id.
fn gatherThreads(gathering: *Gathering) !void {
    const folder = gathering.sources.table.host.machine.threads orelse return;
    try gathering.add("threads", try gathering.arena.print(threads_told, .{ folder, gathering.tid }));
}

/// How the threads are laid out, as the model is told it: their folder, then this thread's id.
const threads_told =
    \\<threads>
    \\The threads of this machine are in {s}, each a folder by its id — this thread's is {s} — to read with the file tools; the shell does not see them, and nothing writes them.
    \\- thread.json: its title, workspace, project, model and mode, and the thread that delegated it, as parent.
    \\- log/: its conversation, as JSON Lines in files that sort in the order they began, an entry a line: its id, which rises along the log; its type — input, what the person sent; reply, the model's response; result, a tool's output; turn-end; configuration, a change of how it runs; compaction, a recap of what came before it; system, what the model was told; failure — and its fields.
    \\Read them where the person asks about another thread, or about work done before.
    \\</threads>
;

/// The instructions the model follows, one section of them all, each file whole: the person's own, for every project,
/// as the host keeps them; then the `AGENTS.md` of each folder from the machine's root down to the workspace, as each
/// folder's applies within it — the nearest last. A file the machine lets no one read is left out, as the person keeps
/// it; a thread that works in no folder of a machine has none.
fn gatherInstructions(gathering: *Gathering) !void {
    const machine = gathering.machine orelse return;
    const arena = gathering.arena;
    var files: std.ArrayList([]const u8) = .empty;
    if (gathering.sources.instructions) |own| try files.append(arena, own);
    for (try foldersDown(arena, machine.base.workspace)) |folder| {
        const path = try std.fs.path.join(arena, &.{ folder, instructions_name });
        for (files.items) |listed| {
            if (std.mem.eql(u8, listed, path)) break;
        } else try files.append(arena, path);
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    for (files.items) |path| {
        const text = machine.readAll(&arena, path, instructions_bytes_max) catch |err| switch (err) {
            error.Refused => continue,
            else => return err,
        } orelse continue;
        if (out.written().len > 0) try out.writer.writeByte('\n');
        try out.writer.print("<instructions path=\"{s}\">\n{s}\n</instructions>", .{ path, std.mem.trimEnd(u8, text, "\n") });
    }
    if (out.written().len > 0) try gathering.add("instructions", out.written());
}

/// The skills the model may use, each by its name, its file and what it is for: the person's own, then each project
/// folder's, a nearer one standing for one of its name farther away; a thread that works in no folder of a machine has
/// none.
fn gatherSkills(gathering: *Gathering) !void {
    const machine = gathering.machine orelse return;
    const found = try skills.find(gathering.arena, machine, gathering.sources.skills, try foldersDown(gathering.arena, machine.base.workspace));
    if (found.len > 0) try gathering.add("skills", try skills.told(gathering.arena, found));
}

/// The tools of the MCP servers the thread may use, as a script calls them, where it has any; and what the person is
/// asked to trust of them.
fn gatherCatalog(gathering: *Gathering) !void {
    const found = try gathering.sources.table.servers.catalog(gathering.arena, gathering.tid);
    if (found.text) |text| try gathering.add("catalog", text);
    gathering.asked = found.asked;
}

/// The folders from the machine's root down to `workspace`, the workspace last.
fn foldersDown(arena: Allocator, workspace: []const u8) ![]const []const u8 {
    var folders: std.ArrayList([]const u8) = .empty;
    var folder: ?[]const u8 = workspace;
    while (folder) |at| : (folder = std.fs.path.dirname(at)) try folders.append(arena, at);
    std.mem.reverse([]const u8, folders.items);
    return folders.items;
}

/// The name of a folder's instructions file.
const instructions_name = "AGENTS.md";
/// The most of an instructions file read.
const instructions_bytes_max = 64 << 10;

/// The sections the model of the thread at `thread` was told, by the system entries of the window its log ends in —
/// those it begins with, then those within it — as `fold` takes them; a window begins told nothing before it.
pub fn toldIn(volume: beak.Volume, arena: *const Allocator, thread: []const u8) ![]const log.Section {
    const window: Window = try .read(volume, arena, thread);
    var entries: std.ArrayList(log.System) = .empty;
    for ([_][]const []const u8{ window.told, window.conversation }) |lines| {
        for (lines) |line| {
            if (!std.mem.eql(u8, (try log.headOf(arena.*, line)).type, "system")) continue;
            try entries.append(arena.*, try foundation.json.decode(log.System, arena.*, line));
        }
    }
    return fold(arena.*, entries.items);
}

/// The sections the model holds after the system entries `entries`, in their order: each as the last entry that named
/// it gave it — the latest, not the first, is what a change is weighed against — and none that an entry took away.
pub fn fold(arena: Allocator, entries: []const log.System) ![]const log.Section {
    var told: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    for (entries) |entry| {
        for (entry.sections) |section| {
            if (section.text) |text| try told.put(arena, section.name, text) else _ = told.orderedRemove(section.name);
        }
    }
    const out = try arena.alloc(log.Section, told.count());
    for (told.keys(), told.values(), out) |name, text, *each| each.* = .{ .name = name, .text = text };
    return out;
}

/// What of `current` the model was not told, as `told` holds the sections it was: each section new or changed, whole,
/// each no longer there with none; and the tools, where a window begins — where it was told nothing — and never within
/// one.
pub fn changes(arena: Allocator, told: []const log.Section, current: Told) !Told {
    var sections: std.ArrayList(log.Section) = .empty;
    for (current.sections) |section| {
        const before = for (told) |each| {
            if (std.mem.eql(u8, each.name, section.name)) break each.text;
        } else null;
        if (before == null or !std.mem.eql(u8, before.?, section.text.?)) try sections.append(arena, section);
    }
    for (told) |each| {
        const kept = for (current.sections) |section| {
            if (std.mem.eql(u8, section.name, each.name)) break true;
        } else false;
        if (!kept) try sections.append(arena, .{ .name = each.name, .text = null });
    }
    return .{ .sections = sections.items, .tools = if (told.len == 0) current.tools else &.{} };
}

test "the model is told each section new or changed, each no longer there, and the tools as a window begins alone" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const read: vocabulary.Tool = .{ .function = .{ .name = "read", .description = "Reads." } };
    const first = try changes(arena, &.{}, .{ .sections = &.{.{ .name = "base", .text = "b" }}, .tools = &.{read} });
    try std.testing.expectEqual(@as(usize, 1), first.tools.len);
    const told = [_]log.Section{ .{ .name = "base", .text = "b" }, .{ .name = "instructions", .text = "p" }, .{ .name = "environment", .text = "e1" } };
    const none = try changes(arena, &told, .{ .sections = &told, .tools = &.{read} });
    try std.testing.expectEqual(@as(usize, 0), none.sections.len + none.tools.len);
    const now = [_]log.Section{ .{ .name = "base", .text = "b" }, .{ .name = "environment", .text = "e2" } };
    const news = try changes(arena, &told, .{ .sections = &now, .tools = &.{} });
    try std.testing.expectEqual(@as(usize, 2), news.sections.len);
    try std.testing.expectEqualStrings("e2", news.sections[0].text.?);
    try std.testing.expectEqualStrings("instructions", news.sections[1].name);
    try std.testing.expect(news.sections[1].text == null);
    try std.testing.expectEqual(@as(usize, 0), news.tools.len);
}

test "a section is weighed against what the model was told last of it: told again where it changed back" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const entries = [_]log.System{
        .{ .id = "1", .request = "r1", .sections = &.{ .{ .name = "base", .text = "b" }, .{ .name = "instructions", .text = "v1" }, .{ .name = "old", .text = "o" } } },
        .{ .id = "2", .request = "r2", .sections = &.{ .{ .name = "instructions", .text = "v2" }, .{ .name = "old", .text = null } } },
    };
    const told = try fold(arena, &entries);
    try std.testing.expectEqual(@as(usize, 2), told.len);
    try std.testing.expectEqualStrings("v2", told[1].text.?);
    // Back to its first text, it is a change from the last: told again, whole.
    const back = try changes(arena, told, .{ .sections = &.{ .{ .name = "base", .text = "b" }, .{ .name = "instructions", .text = "v1" } } });
    try std.testing.expectEqual(@as(usize, 1), back.sections.len);
    try std.testing.expectEqualStrings("v1", back.sections[0].text.?);
}

test "the environment names the workspace, the platform and shell, and the day in UTC" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const text = try environmentOf(arena, .{ .workspace = "/work/app" }, true, 1_794_096_000_000);
    try std.testing.expect(std.mem.startsWith(u8, text, "<environment>\nworkspace: /work/app\nplatform: "));
    try std.testing.expect(std.mem.endsWith(u8, text, "date: 2026-11-08 (UTC)\n</environment>"));
}
