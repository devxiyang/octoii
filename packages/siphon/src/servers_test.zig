//! The MCP servers on the local machine: mcp's example server, its tools told in the catalog and called from a script,
//! its variables set over the machine's own; what a configuration names but cannot be run, told too; a project's
//! servers, run once the person trusts them; and the servers as a client is shown them, the person deciding unasked.
const std = @import("std");
const ai = @import("ai");
const Siphon = @import("Siphon.zig");
const threads = @import("threads.zig");
const testing = @import("testing.zig");
const tools = @import("tools.zig");
const scripts = tools.scripts;
const trust = tools.trust;
const Changes = @import("runtime.zig").Changes;
const beak = @import("beak.zig");
const h = beak.h;

const server_path = @import("test_options").example_stdio_server;

test "a server's tools are told in the catalog and called from a script, the server run on the machine with its variables" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "work");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const program = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, server_path, arena);
    const configuration = try std.fmt.allocPrint(arena,
        \\{{"mcpServers":{{
        \\  "example":{{"command":{f},"args":["both"],"env":{{"OCTOII_GIVEN":"1"}}}},
        \\  "remote":{{"url":"https://example.invalid/mcp"}}
        \\}}}}
    , .{std.json.fmt(program, .{})});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "mcp.json", .data = configuration });
    const machine = try testing.openLocalMachine();
    defer _ = h.beak_close(machine);

    const code =
        \\const names = (await tools.example.env({})).split(",");
        \\return names.includes("OCTOII_GIVEN") && names.includes("PATH");
    ;
    var fake: ai.testing.Fake = .init(arena, &.{ try testing.streamed(arena, &.{try testing.executing(arena, "c1", code)}), try testing.message(arena, "It has both.") });
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(testing.model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{
        .io = std.testing.io,
        .clock = clock.clock(),
        .machine = machine,
        .home = root,
        .mcp = try std.fs.path.join(arena, &.{ root, "mcp.json" }),
    }, .{ .providers = &providers });
    defer siphon.close();
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m", .mode = .@"full-access", .workspace = try std.fs.path.join(arena, &.{ root, "work" }) }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, testing.said("has the server both variables?"), "op-1");

    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try testing.expectEntries(siphon, arena, tid, &.{ "system", "input", "reply", "calls example.env under c1", "result ok under c1", "result ok", "reply", "turn-end" });
    try std.testing.expectEqualStrings("true", (try testing.toldOutputs(&fake, arena, 1))[0]);
    // The model was told the server's tools, as a script calls them, and of the server it could not be told of.
    const told = fake.requests.items[0].input.?.parts[0].input_message.content.parts;
    const catalog = for (told) |part| {
        if (std.mem.startsWith(u8, part.input_text.text, "<catalog>")) break part.input_text.text;
    } else return error.NoCatalog;
    try std.testing.expect(std.mem.indexOf(u8, catalog, "tools.example.env(arguments: Record<string, unknown>): Promise<string>;") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "the server remote is not run: a server reached by its URL is not taken yet") != null);
}

test "a project's servers run once the person trusts them, asked as its thread first gathers what its model is told" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/work");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const program = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, server_path, arena);
    // The person's server and the project's of the same name, told apart by the variable each is given.
    const configuration = "{{\"mcpServers\":{{\"example\":{{\"command\":{f},\"args\":[\"both\"],\"env\":{{\"{s}\":\"1\"}}}}}}}}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "mcp.json", .data = try std.fmt.allocPrint(arena, configuration, .{ std.json.fmt(program, .{}), "OCTOII_PERSON" }) });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/.mcp.json", .data = try std.fmt.allocPrint(arena, configuration, .{ std.json.fmt(program, .{}), "OCTOII_PROJECT" }) });
    const machine = try testing.openLocalMachine();
    defer _ = h.beak_close(machine);

    const code =
        \\return (await tools.example.env({})).split(",").filter((name) => name.startsWith("OCTOII_")).join(",");
    ;
    var fake: ai.testing.Fake = .init(arena, &.{
        try testing.streamed(arena, &.{try testing.executing(arena, "c1", code)}), try testing.message(arena, "The person's."),
        try testing.streamed(arena, &.{try testing.executing(arena, "c2", code)}), try testing.message(arena, "The project's."),
    });
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(testing.model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{
        .io = std.testing.io,
        .clock = clock.clock(),
        .machine = machine,
        .home = root,
        .mcp = try std.fs.path.join(arena, &.{ root, "mcp.json" }),
    }, .{ .providers = &providers });
    defer siphon.close();
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m", .mode = .@"full-access", .workspace = try std.fs.path.join(arena, &.{ root, "repo", "work" }), .project = try std.fs.path.join(arena, &.{ root, "repo" }) }, "create");

    // Not trusted yet, the project's servers are not run: the person's stands, and the person is asked.
    _ = try threads.deliver(siphon.runtime, arena, tid, testing.said("whose server is it?"), "op-1");
    const first = try testing.pumpUntilSettled(siphon, arena, tid);
    try std.testing.expectEqualStrings("\"OCTOII_PERSON\"", (try testing.toldOutputs(&fake, arena, 1))[0]);
    const catalog = (try catalogTold(&fake, 0)) orelse return error.NoCatalog;
    try std.testing.expect(std.mem.indexOf(u8, catalog, "repo/.mcp.json: its servers are not run till the person trusts them; they are asked") != null);
    const asking = for (first.processes) |process| {
        if (std.mem.eql(u8, process.program, "siphon.trust")) break process;
    } else return error.NotAsked;
    try std.testing.expect(asking.parent == null);
    try std.testing.expectEqualStrings("trust", asking.requests[0].name);
    const asked = try std.json.parseFromSliceLeaky(std.json.Value, arena, asking.requests[0].payload.?.text, .{});
    try std.testing.expectEqualStrings(try std.fs.path.join(arena, &.{ root, "repo" }), asked.object.get("folder").?.string);
    try std.testing.expectEqualStrings("example", asked.object.get("servers").?.array.items[0].object.get("name").?.string);

    // An answer that does not fit is refused; a request no person answers cannot be answered by one.
    const key = asking.requests[0].key;
    try std.testing.expect((try threads.answer(siphon.runtime, arena, tid, key, .{ .text = "{\"trusted\":\"yes\"}" })) == .unfit);
    try std.testing.expectError(error.NoSuchRequest, threads.answer(siphon.runtime, arena, tid, "none", .{ .text = "{\"trusted\":true}" }));
    try std.testing.expect((try threads.answer(siphon.runtime, arena, tid, key, .{ .text = "{\"trusted\":true}" })) == .given);
    const fiber = try beak.childPath(arena, try threads.pathOf(arena, tid), asking.key);
    try std.testing.expect((try testing.pumpUntilEnded(siphon, &arena, fiber)).status == .completed);

    // Trusted, the project's server stands for the person's of its name.
    _ = try threads.deliver(siphon.runtime, arena, tid, testing.said("and now?"), "op-2");
    const second = try testing.pumpUntilSettled(siphon, arena, tid);
    try std.testing.expectEqual(threads.Status.replied, second.status);
    const outputs = try testing.toldOutputs(&fake, arena, 3);
    try std.testing.expectEqualStrings("\"OCTOII_PROJECT\"", outputs[outputs.len - 1]);
    const trusted = (try catalogTold(&fake, 2)) orelse return error.NoCatalog;
    try std.testing.expect(std.mem.indexOf(u8, trusted, "not run") == null);
}

test "a client is shown the servers a folder's threads would use, nothing started for it; the person decides unasked, and again" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/work");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const program = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, server_path, arena);
    const configuration = try std.fmt.allocPrint(arena, "{{\"mcpServers\":{{\"example\":{{\"command\":{f},\"args\":[\"both\"]}}}}}}", .{std.json.fmt(program, .{})});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "mcp.json", .data = configuration });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/.mcp.json", .data = configuration });
    const machine = try testing.openLocalMachine();
    defer _ = h.beak_close(machine);
    var fake: ai.testing.Fake = .init(arena, &.{});
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(testing.model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const person = try std.fs.path.join(arena, &.{ root, "mcp.json" });
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = clock.clock(), .machine = machine, .home = root, .mcp = person }, .{ .providers = &providers });
    defer siphon.close();
    const servers = &siphon.tools.servers;
    const place: tools.Servers.Place = .{ .workspace = try std.fs.path.join(arena, &.{ root, "repo", "work" }), .project = try std.fs.path.join(arena, &.{ root, "repo" }) };

    // Undecided, the project's server is shown as it would be run, the person's in its stead; nothing is started.
    const undecided = try servers.list(arena, place);
    try std.testing.expectEqual(@as(usize, 1), undecided.servers.len);
    try std.testing.expectEqualStrings(person, undecided.servers[0].source);
    try std.testing.expect(!undecided.servers[0].connected);
    const project = undecided.project.?;
    try std.testing.expectEqual(@as(?bool, null), project.trusted);
    try std.testing.expectEqualStrings("example", project.named.servers[0].name);
    try std.testing.expect(!(try servers.list(arena, place)).servers[0].connected);

    // Trusted unasked, the project's stands for the person's; connected as a thread first needs its tools, it is
    // shown with them.
    try decide(siphon, arena, project.named, true);
    const trusted = try servers.list(arena, place);
    try std.testing.expectEqualStrings(project.named.path, trusted.servers[0].source);
    try std.testing.expectEqual(@as(?bool, true), trusted.project.?.trusted);
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m", .mode = .@"full-access", .workspace = place.workspace, .project = place.project }, "create");
    try std.testing.expect((try servers.toolNames(arena, tid)).len > 0);
    const connected = (try servers.list(arena, place)).servers[0];
    try std.testing.expect(connected.connected);
    try std.testing.expect(connected.tools.len > 0);

    // Decided again, no longer trusted: the person's stands once more.
    try decide(siphon, arena, project.named, false);
    const declined = try servers.list(arena, place);
    try std.testing.expectEqualStrings(person, declined.servers[0].source);
    try std.testing.expectEqual(@as(?bool, false), declined.project.?.trusted);
}

/// Records what the person decided on the configuration `named`, as a client's decision is.
fn decide(siphon: *Siphon, arena: std.mem.Allocator, named: trust.Asked, trusted: bool) !void {
    var changes: Changes = .{ .arena = arena };
    try trust.record(&changes, arena, .{ .folder = named.folder, .digest = named.digest, .trusted = trusted });
    _ = try siphon.runtime.commit(&changes);
}

/// The catalog the model holds in its request `index`: the last it was told, where it was told one.
fn catalogTold(fake: *const ai.testing.Fake, index: usize) !?[]const u8 {
    var last: ?[]const u8 = null;
    for (fake.requests.items[index].input.?.parts) |item| {
        if (item != .input_message or item.input_message.content != .parts) continue;
        for (item.input_message.content.parts) |part| {
            if (part == .input_text and std.mem.startsWith(u8, part.input_text.text, "<catalog>")) last = part.input_text.text;
        }
    }
    return last;
}
