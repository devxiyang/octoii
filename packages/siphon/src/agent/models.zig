//! A thread's model, as Siphon asks it: a `model` request rendered from the thread's log into `ai`'s vocabulary, sent
//! through `ai` over the host's network, and answered with the response as it came — completed, cut short, or failed
//! with what its provider said — once. What streams while it is answered is published on the thread, by the request's
//! key, for those that follow it; a stop cancels the read, and the response answered is what had come.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const ai = @import("ai");
const runtime_ = @import("../runtime.zig");
const Runtime = runtime_.Runtime;
const Request = runtime_.Request;
const threads = @import("../threads.zig");
const log = threads.log;
const Window = threads.Window;
const Tool = @import("../tools.zig").Tool;
const compaction = @import("compaction.zig");
const system = @import("system.zig");

/// The name of a model's request.
pub const model_request = "model";

/// Lists the providers' models again, and fetches the catalogue where the host gives its address, off the loop, as a job
/// of the runtime's started from the loop: a listing or a fetch that fails keeps what was there.
pub fn relist(runtime: *Runtime, models: *ai.Models) void {
    runtime.spawn(.{ .context = models, .run = relisting, .finish = relisted, .drop = relisted }) catch |err| {
        std.log.scoped(.siphon).warn("the models are not listed again: {s}", .{@errorName(err)});
    };
}

fn relisting(context: *anyopaque, _: *runtime_.Waits) void {
    const models: *ai.Models = @ptrCast(@alignCast(context));
    models.refresh() catch |err| std.log.scoped(.siphon).warn("the models are not listed again: {s}", .{@errorName(err)});
}

/// What a listing leaves behind: nothing, the directory changed in place.
fn relisted(_: *anyopaque) void {}

/// What a model's request asks: what follows the window the log of the thread `thread`, by its id, ends in, its
/// conversation up to the entry `until`, of `model`; or, where `instruction` is given, what it asks after them — a
/// recap of the window up to its cut, a title for the thread — answered in words, no tool called.
pub const ModelRequest = struct {
    thread: []const u8,
    until: []const u8,
    model: ?[]const u8 = null,
    instruction: ?[]const u8 = null,
};

/// Acts on every model request through `models`.
pub fn register(runtime: *Runtime, models: *ai.Models) !void {
    try runtime.handle(model_request, .{ .context = models, .act = act });
}

fn act(context: ?*anyopaque, request: *Request) anyerror!void {
    const models: *ai.Models = @ptrCast(@alignCast(context.?));
    const arena = request.arena();
    const asked = try foundation.json.decode(ModelRequest, arena, request.payload);
    const served = if (asked.model) |model| try models.find(arena, model) else null;
    const rendered = try render(request.runtime, &arena, asked, if (served) |found| found.model else null);
    var stream = models.text(arena, rendered);
    defer stream.close();
    var scratch_arena: std.heap.ArenaAllocator = .init(request.runtime.allocator);
    defer scratch_arena.deinit();
    while (try stream.next()) |event| {
        // What streams is published on the thread, by the request it streams for, for those that follow it; the reply
        // comes whole after.
        _ = scratch_arena.reset(.retain_capacity);
        const encoded = foundation.json.encode(scratch_arena.allocator(), event) catch continue;
        request.publish(asked.thread, encoded) catch continue;
    }
    const response = stream.response() orelse return error.NoResponse;
    try request.answer(response);
}

/// The vocabulary's request for what follows the window the log of the thread `asked` names ends in, its conversation
/// up to the entry `until` — every part of it from the log, so what the window begins with stays as it was sent and
/// every provider's cache of it holds: the system entries it begins with as developer messages, the instructions, their
/// tools the request's tools; the effort it is asked at; its compaction's recap; then its conversation — a later system
/// entry an update, a later configuration a change of the effort, each input as its message, each reply as the items its
/// response gave, each result as the output its call gave, and the end of a turn the person stopped as a note that they
/// stopped it there. A request with an instruction asks it after the window up to `until` — a recap, a title — the
/// tools declared as ever, so the window's cache holds, but none to be called. It is rendered as `served`, the facts of
/// the model asked, where they are known, has the model take it, the log left as it is: a window begun with another
/// model — the person changed the model within it — may declare a search this one does not run, which is left out; and
/// a model that reads no images is told each in words in its place, as every image the log names was kept as a model
/// that reads them takes one.
pub fn render(runtime: *const Runtime, arena: *const Allocator, asked: ModelRequest, served: ?ai.Model) !vocabulary.ResponsesRequest {
    const model = asked.model orelse return error.NoModel;
    const window: Window = try .read(runtime.volume, arena, try threads.pathOf(arena.*, asked.thread));
    var items: std.ArrayList(vocabulary.Item) = .empty;
    var declared: std.ArrayList(vocabulary.Tool) = .empty;
    const searches = if (served) |facts| system.searches(facts) else true;
    for (window.told) |line| {
        const entry = try foundation.json.decode(log.System, arena.*, line);
        for (entry.tools) |tool| if (searches or tool != .web_search) try declared.append(arena.*, tool);
        if (entry.sections.len > 0) try items.append(arena.*, .{ .input_message = try messageOf(arena.*, entry.sections) });
    }
    if (window.compaction) |made| try items.append(arena.*, .{ .input_message = try recapMessageOf(arena.*, try compaction.recapIn(arena.*, made)) });
    const end = for (window.conversation, 1..) |line, count| {
        if (std.mem.eql(u8, (try log.headOf(arena.*, line)).id, asked.until)) break count;
    } else return error.UntilGone;
    for (window.conversation[0..end], 0..) |line, index| {
        // A configuration before the window's first reply is how the window is asked, not sent where it stands.
        if (index < window.answered and std.mem.eql(u8, (try log.headOf(arena.*, line)).type, "configuration")) continue;
        try appendItems(arena.*, &items, line);
    }
    if (asked.instruction) |instruction| try items.append(arena.*, .{ .input_message = .{ .role = .user, .content = .{ .text = instruction } } });
    if (served) |facts| if (!facts.reads(.image)) for (items.items) |*item| try imagesTold(arena.*, item, model);
    return .{
        .model = model,
        .input = .{ .parts = items.items },
        .tools = if (declared.items.len > 0) declared.items else null,
        .tool_choice = if (asked.instruction != null and declared.items.len > 0) .{ .mode = .none } else null,
        .reasoning = if (window.effort) |effort| .{ .effort = effort } else null,
        // The thread names the conversation, by which a provider keeps its requests' cache, or its session, together.
        .prompt_cache_key = asked.thread,
    };
}

/// `item` — a message, or a call's output — with each image it holds told in words in its place, to `model`, which
/// reads none.
fn imagesTold(arena: Allocator, item: *vocabulary.Item, model: []const u8) !void {
    switch (item.*) {
        .input_message => |*message| switch (message.content) {
            .text => {},
            .parts => |parts| message.content = .{ .parts = try withoutImages(arena, parts, model) },
        },
        .function_call_output => |*output| switch (output.output) {
            .text => {},
            .parts => |parts| output.output = .{ .parts = try withoutImages(arena, parts, model) },
        },
        else => {},
    }
}

/// `parts`, each image told in words in its place, to `model`, which reads none.
fn withoutImages(arena: Allocator, parts: []const vocabulary.content.InputContent, model: []const u8) ![]const vocabulary.content.InputContent {
    const told: vocabulary.content.InputContent = .{ .input_text = .{ .text = try arena.print("[an image, not shown: the model {s} reads no images]", .{model}) } };
    const kept = try arena.dupe(vocabulary.content.InputContent, parts);
    for (kept) |*part| if (part.* == .input_image) {
        part.* = told;
    };
    return kept;
}

/// The items an entry of a window's conversation is sent as: a system entry's sections as an update, a configuration
/// as a change of the effort where it stands, an input as its message, a reply as the items its response gave, a
/// result as the output its call gave, a turn's end — one the person stopped, as the window holds no other — as a note
/// of it; nothing of another entry.
pub fn appendItems(arena: Allocator, items: *std.ArrayList(vocabulary.Item), line: []const u8) !void {
    const kind = (try log.headOf(arena, line)).type;
    if (std.mem.eql(u8, kind, "system")) {
        const entry = try foundation.json.decode(log.System, arena, line);
        if (entry.sections.len > 0) try items.append(arena, .{ .input_message = try messageOf(arena, entry.sections) });
    } else if (std.mem.eql(u8, kind, "input")) {
        try items.append(arena, .{ .input_message = (try foundation.json.decode(log.Input, arena, line)).message });
    } else if (std.mem.eql(u8, kind, "reply")) {
        const reply = try foundation.json.decode(log.Reply, arena, line);
        const response = try foundation.json.decode(vocabulary.Response, arena, reply.response.text);
        for (response.output) |output| try items.append(arena, vocabulary.Item.ofOutput(output));
    } else if (std.mem.eql(u8, kind, "result")) {
        try items.append(arena, .{ .function_call_output = (try foundation.json.decode(log.Result, arena, line)).call_output });
    } else if (std.mem.eql(u8, kind, "configuration")) {
        try items.append(arena, .{ .configuration_update = .{ .reasoning = .{ .effort = (try foundation.json.decode(log.Configuration, arena, line)).effort } } });
    } else if (std.mem.eql(u8, kind, "turn-end")) {
        try items.append(arena, .{ .input_message = .{ .role = .developer, .content = .{ .text = stopped_note } } });
    }
}

/// What a response says its request used, as a thread's usage counts it; none where it says nothing.
pub fn usageOf(response: vocabulary.Response) ?threads.Usage {
    const used = response.usage orelse return null;
    const cost = used.cost orelse 0;
    return .{
        .input_tokens = used.input_tokens,
        .cached_tokens = used.input_tokens_details.cached_tokens,
        .output_tokens = used.output_tokens,
        .reasoning_tokens = used.output_tokens_details.reasoning_tokens,
        .cost_nanodollars = if (cost > 0) @intFromFloat(@round(cost * 1e9)) else 0,
    };
}

/// Charges what `response` says its request used to the fiber at `process` and every fiber above it, with the commit
/// of `changes`, as a cgroup charges its ancestors; nothing where it says nothing.
pub fn charge(changes: *runtime_.Changes, process: []const u8, response: vocabulary.Response) !void {
    const used = usageOf(response) orelse return;
    const counters = try used.counters(changes.arena);
    if (counters.len > 0) try changes.charge(process, counters);
}

/// The words a response's messages gave, trimmed; none where they gave none.
pub fn textOf(arena: Allocator, response: vocabulary.Response) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (response.output) |item| switch (item) {
        .output_message => |message| switch (message.content) {
            .text => |text| try out.appendSlice(arena, text),
            .parts => |parts| for (parts) |part| switch (part) {
                .output_text => |given| try out.appendSlice(arena, given.text),
                else => {},
            },
        },
        else => {},
    };
    const text = std.mem.trim(u8, out.items, &std.ascii.whitespace);
    return if (text.len == 0) null else text;
}

/// What the model is told where the person stopped a turn: what came before was cut off there, not finished.
pub const stopped_note = "The person stopped this turn here.";

/// A compaction's recap as the model is sent it: a developer message after what it is told, which stands for the
/// conversation before the window.
fn recapMessageOf(arena: Allocator, recap: []const u8) !vocabulary.items.InputMessage {
    return .{ .role = .developer, .content = .{ .text = try arena.print("<recap>\n{s}\n</recap>", .{recap}) } };
}

/// A system entry's sections as the model is sent them: a developer message, a part for each section, its text as the
/// entry holds it, or a note of a section no longer told.
fn messageOf(arena: Allocator, sections: []const log.Section) !vocabulary.items.InputMessage {
    const parts = try arena.alloc(vocabulary.content.InputContent, sections.len);
    for (sections, parts) |section, *part| {
        const text = section.text orelse try Tool.told(arena, .{ .text = "", .notes = &.{try arena.print("removed: {s}", .{section.name})} });
        part.* = .{ .input_text = .{ .text = text } };
    }
    return .{ .role = .developer, .content = .{ .parts = parts } };
}

/// A store of credentials that keeps none, for a host that gives no secrets.
pub const no_credentials: ai.driver.Credentials = .{ .context = @constCast(&nothing), .vtable = &.{ .read = readNone, .modify = modifyNone, .remove = removeNone } };

const nothing: u8 = 0;

fn readNone(_: *anyopaque, _: Allocator, _: []const u8) error{ Unavailable, OutOfMemory }!?ai.driver.Credential {
    return null;
}

fn modifyNone(_: *anyopaque, _: Allocator, _: []const u8, _: ai.driver.Credentials.Change) ai.driver.Credentials.ModifyError!?ai.driver.Credential {
    return error.Unavailable;
}

fn removeNone(_: *anyopaque, _: []const u8) error{Unavailable}!void {
    return error.Unavailable;
}
