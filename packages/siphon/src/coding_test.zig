//! The coding tools on a workspace in a test's folder, on the local machine: each run as a call runs it, then a model
//! that writes a file through a turn.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vocabulary = @import("vocabulary");
const ai = @import("ai");
const Siphon = @import("Siphon.zig");
const threads = @import("threads.zig");
const tools = @import("tools.zig");
const Waits = @import("runtime.zig").Waits;
const coding = @import("tools.zig").coding;
const log = @import("threads.zig").log;
const testing = @import("testing.zig");
const beak = @import("beak.zig");
const h = beak.h;

/// Images to read: one a model reads whole, and one past what it does.
const small_png = testing.pngOf(64, 32);
const wide_png = testing.pngOf(1600, 8);

/// A tool of Siphon's run on `arguments` for the thread `tid`, as a call runs it.
fn runTool(siphon: *Siphon, arena: Allocator, tid: []const u8, name: []const u8, arguments: []const u8) !tools.Tool.Output {
    const tool = siphon.tools.named(name) orelse return error.NoSuchTool;
    const key = try arena.dupe(u8, &try siphon.runtime.volume.mint(siphon.runtime.now()));
    var waits: Waits = .{};
    defer waits.close();
    const run: tools.Tool.Run = .{ .arena = arena, .runtime = siphon.runtime, .host = &siphon.tools.host, .thread = tid, .arguments = arguments, .key = key, .writes = .anywhere, .waits = &waits };
    return tool.work.task(tool.context, &run);
}

/// That a tool's run gave `expected`, as the model reads it.
fn expectTold(expected: []const u8, output: tools.Tool.Output, arena: Allocator) !void {
    try std.testing.expectEqualStrings(expected, try tools.Tool.told(arena, output));
}

fn expectRefused(expected: []const u8, output: tools.Tool.Output) !void {
    try std.testing.expectEqual(.refused, output.outcome);
    try std.testing.expectEqualStrings(expected, output.text);
}

test "the coding tools work on the machine's files, a path taken in every spelling, what they give told as it is" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "work");
    try tmp.dir.createDirPath(std.testing.io, "lib");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/x.txt", .data = "beside\n" });
    try tmp.dir.createDirPath(std.testing.io, "outputs");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const workspace = try std.fs.path.join(arena, &.{ root, "work" });
    const outputs = try std.fs.path.join(arena, &.{ root, "outputs" });
    const machine = try testing.openLocalMachine();
    defer _ = h.beak_close(machine);
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = clock.clock(), .machine = machine, .home = root, .outputs = outputs }, .{});
    defer siphon.close();
    const thread = try threads.create(siphon.runtime, arena, .{ .workspace = workspace }, "create");

    try expectTold("created src/notes.txt +2", try runTool(siphon, arena, thread, "write", "{\"path\":\"src/notes.txt\",\"content\":\"one\\ntwo\\n\"}"), arena);
    try expectTold("one\ntwo\n", try runTool(siphon, arena, thread, "read", "{\"path\":\"src/notes.txt\"}"), arena);
    const edited = try runTool(siphon, arena, thread, "edit", "{\"path\":\"src/notes.txt\",\"old\":\"two\",\"new\":\"three\"}");
    try std.testing.expect(std.mem.startsWith(u8, edited.text, "--- src/notes.txt\n+++ src/notes.txt\n@@"));
    try std.testing.expect(std.mem.indexOf(u8, edited.text, "-two\n+three") != null);
    try std.testing.expectEqual(@as(usize, 0), edited.notes.len);

    // A path is taken in every spelling of the one place it names, and outside the workspace as well.
    const absolute = try arena.print("{{\"path\":\"{s}/src/notes.txt\"}}", .{workspace});
    for ([_][]const u8{ absolute, "{\"path\":\"./src//notes.txt\"}", "{\"path\":\"src/../src/notes.txt/\"}" }) |arguments| {
        try expectTold("one\nthree\n", try runTool(siphon, arena, thread, "read", arguments), arena);
    }
    try expectTold("beside\n", try runTool(siphon, arena, thread, "read", "{\"path\":\"../lib/x.txt\"}"), arena);
    try expectTold("beside\n", try runTool(siphon, arena, thread, "read", "{\"path\":\"~/lib/x.txt\"}"), arena);
    try expectTold(try arena.print("{s}/lib/x.txt\n", .{root}), try runTool(siphon, arena, thread, "glob", "{\"pattern\":\"*.txt\",\"path\":\"../lib\"}"), arena);
    try expectTold("src/notes.txt\n", try runTool(siphon, arena, thread, "glob", "{\"pattern\":\"**/*.txt\"}"), arena);
    try expectTold("src/notes.txt:2: three\n", try runTool(siphon, arena, thread, "grep", "{\"pattern\":\"thr\"}"), arena);
    try expectTold("notes.txt\n", try runTool(siphon, arena, thread, "read", "{\"path\":\"src\"}"), arena);
    try expectTold("[no match]", try runTool(siphon, arena, thread, "glob", "{\"pattern\":\"*.zig\"}"), arena);

    // A page notes what it leaves out, with the offset to read on from.
    _ = try runTool(siphon, arena, thread, "write", "{\"path\":\"five.txt\",\"content\":\"a\\nb\\nc\\nd\\ne\\n\"}");
    try expectTold("b\nc\n[lines 2-3; more from offset 4]", try runTool(siphon, arena, thread, "read", "{\"path\":\"five.txt\",\"offset\":2,\"limit\":2}"), arena);
    try expectTold("d\ne\n[lines 4-5 of 5]", try runTool(siphon, arena, thread, "read", "{\"path\":\"five.txt\",\"offset\":4}"), arena);

    // An edit matched past the exact tier is told so.
    _ = try runTool(siphon, arena, thread, "write", "{\"path\":\"quote.txt\",\"content\":\"it\u{2019}s here\\n\"}");
    const typographic = try runTool(siphon, arena, thread, "edit", "{\"path\":\"quote.txt\",\"old\":\"it's here\",\"new\":\"it is here\"}");
    try std.testing.expectEqualStrings("tier typographic", typographic.notes[0]);

    try expectTold("hi\n[exit 3]", try runTool(siphon, arena, thread, "shell", "{\"command\":\"printf 'hi\\\\n'; exit 3\"}"), arena);
    try expectTold("notes.txt\n[exit 0]", try runTool(siphon, arena, thread, "shell", "{\"command\":\"ls src\"}"), arena);
    // A long output keeps its head and newest tail, the line between saying where its log keeps all of it.
    const long = try runTool(siphon, arena, thread, "shell", "{\"command\":\"seq 1 20000\"}");
    const marker = try arena.print("bytes left out; all of it in {s}/", .{outputs});
    const at = std.mem.indexOf(u8, long.text, marker).?;
    const log_path = long.text[at + marker.len - outputs.len - 1 .. std.mem.indexOfScalarPos(u8, long.text, at, ']').?];
    const logged = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, log_path, arena, .unlimited);
    try std.testing.expectEqual(@as(usize, 108_894), logged.len);
    try std.testing.expect(std.mem.endsWith(u8, logged, "19999\n20000\n"));

    // What Beak throws is told as it throws it.
    try expectRefused("refused: not-found", try runTool(siphon, arena, thread, "edit", "{\"path\":\"src/notes.txt\",\"old\":\"four\",\"new\":\"five\"}"));
    try expectRefused("refused: many: 5", try runTool(siphon, arena, thread, "edit", "{\"path\":\"five.txt\",\"old\":\"\\n\",\"new\":\";\"}"));
    try expectRefused("not-found", try runTool(siphon, arena, thread, "read", "{\"path\":\"src/nope.txt\"}"));
    try expectRefused("invalid: past-end: 5", try runTool(siphon, arena, thread, "read", "{\"path\":\"five.txt\",\"offset\":9}"));
    const bad_pattern = try runTool(siphon, arena, thread, "grep", "{\"pattern\":\"(open\"}");
    try std.testing.expect(std.mem.startsWith(u8, bad_pattern.text, "invalid: bad-pattern: "));
    try std.testing.expect(std.mem.endsWith(u8, bad_pattern.text, "(offset 5)"));
}

test "a file is written and edited as it held its text, a name found by its canonical form, and a long file paged" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "work/folder");
    try tmp.dir.writeFile(io, .{ .sub_path = "work/windows.txt", .data = "\xef\xbb\xbfone\r\ntwo\r\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "work/blob.bin", .data = "a\x00b" });
    try tmp.dir.writeFile(io, .{ .sub_path = "work/Screenshot\u{202f}at noon.txt", .data = "seen\n" });
    var long: std.Io.Writer.Allocating = .init(arena);
    for (1..70_001) |number| try long.writer.print("line {d}\n", .{number});
    try tmp.dir.writeFile(io, .{ .sub_path = "work/long.txt", .data = long.written() });
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const workspace = try std.fs.path.join(arena, &.{ root, "work" });
    const machine = try testing.openLocalMachine();
    defer _ = h.beak_close(machine);
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = io, .clock = clock.clock(), .machine = machine, .home = root, .outputs = root }, .{});
    defer siphon.close();
    const thread = try threads.create(siphon.runtime, arena, .{ .workspace = workspace }, "create");

    // A text file keeps its byte-order mark and its `\r\n` through a write and an edit, which find its lines as `\n`.
    try expectTold("wrote windows.txt +2 -2", try runTool(siphon, arena, thread, "write", "{\"path\":\"windows.txt\",\"content\":\"uno\\ndos\\n\"}"), arena);
    _ = try runTool(siphon, arena, thread, "edit", "{\"path\":\"windows.txt\",\"old\":\"uno\\ndos\\n\",\"new\":\"uno\\ndos\\ntres\\n\"}");
    try std.testing.expectEqualStrings("\xef\xbb\xbfuno\r\ndos\r\ntres\r\n", try tmp.dir.readFileAlloc(io, "work/windows.txt", arena, .unlimited));
    try expectTold("uno\ndos\ntres\n", try runTool(siphon, arena, thread, "read", "{\"path\":\"windows.txt\"}"), arena);
    // A name typed with a plain space is read as the one file whose name holds another, and told so.
    try expectTold("seen\n[read as Screenshot\u{202f}at noon.txt]", try runTool(siphon, arena, thread, "read", "{\"path\":\"Screenshot at noon.txt\"}"), arena);
    // What is no text file is refused as what it is.
    try expectRefused("unsupported: not-text", try runTool(siphon, arena, thread, "edit", "{\"path\":\"blob.bin\",\"old\":\"a\",\"new\":\"c\"}"));
    try expectRefused("is-a-directory", try runTool(siphon, arena, thread, "edit", "{\"path\":\"folder\",\"old\":\"a\",\"new\":\"c\"}"));
    try expectRefused("is-a-directory", try runTool(siphon, arena, thread, "write", "{\"path\":\"folder\",\"content\":\"x\"}"));
    try expectTold("[binary: not shown]", try runTool(siphon, arena, thread, "read", "{\"path\":\"blob.bin\"}"), arena);
    // A file of many ranges is paged from deep within it, every line counted to its end.
    try expectTold("line 69999\nline 70000\n[lines 69999-70000 of 70000]", try runTool(siphon, arena, thread, "read", "{\"path\":\"long.txt\",\"offset\":69999}"), arena);
}

test "glob and grep give every match a page at a time, the ignore files from outside the tree taken too" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "work/.git/info");
    try tmp.dir.createDirPath(io, "work/many");
    try tmp.dir.writeFile(io, .{ .sub_path = "ignore", .data = "*.tmp\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "work/.git/info/exclude", .data = "*.local\n" });
    for ([_][]const u8{ "work/a.tmp", "work/b.local", "work/keep.c" }) |name| try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "x\n" });
    for (0..205) |index| try tmp.dir.writeFile(io, .{ .sub_path = try arena.print("work/many/f{d:0>3}.txt", .{index}), .data = "x\n" });
    var hits: std.Io.Writer.Allocating = .init(arena);
    for (1..301) |number| try hits.writer.print("hit {d}\n", .{number});
    try tmp.dir.writeFile(io, .{ .sub_path = "work/hits.txt", .data = hits.written() });
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const machine = try testing.openLocalMachine();
    defer _ = h.beak_close(machine);
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = io, .clock = clock.clock(), .machine = machine, .home = root, .outputs = root, .excludes = try std.fs.path.join(arena, &.{ root, "ignore" }) }, .{});
    defer siphon.close();
    const thread = try threads.create(siphon.runtime, arena, .{ .workspace = try std.fs.path.join(arena, &.{ root, "work" }) }, "create");

    const first = try tools.Tool.told(arena, try runTool(siphon, arena, thread, "glob", "{\"pattern\":\"**/*.txt\"}"));
    try std.testing.expect(std.mem.endsWith(u8, first, "[files 1-200 of 206, the newest first; more from offset 201]"));
    const rest = try tools.Tool.told(arena, try runTool(siphon, arena, thread, "glob", "{\"pattern\":\"**/*.txt\",\"offset\":201}"));
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, rest, ".txt\n"));
    try std.testing.expect(std.mem.endsWith(u8, rest, "[files 201-206 of 206]"));
    try expectRefused("invalid: past-end: 206", try runTool(siphon, arena, thread, "glob", "{\"pattern\":\"**/*.txt\",\"offset\":300}"));
    // The person's own ignore file and the repository's info/exclude leave out what they name.
    try expectTold("keep.c\n", try runTool(siphon, arena, thread, "glob", "{\"pattern\":\"*.{c,tmp,local}\"}"), arena);
    const matched = try tools.Tool.told(arena, try runTool(siphon, arena, thread, "grep", "{\"pattern\":\"^hit\"}"));
    try std.testing.expectEqual(@as(usize, 250), std.mem.count(u8, matched, ": hit "));
    try std.testing.expect(std.mem.endsWith(u8, matched, "[matches 1-250; more from offset 251]"));
    const after = try tools.Tool.told(arena, try runTool(siphon, arena, thread, "grep", "{\"pattern\":\"^hit\",\"offset\":251}"));
    try std.testing.expect(std.mem.startsWith(u8, after, "hits.txt:251: hit 251\n"));
    try std.testing.expect(std.mem.endsWith(u8, after, "hits.txt:300: hit 300\n[matches 251-300]"));
}

test "a turn's model, told of its workspace and the instructions it follows, writes a file through the write tool" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "work");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "work/AGENTS.md", .data = "Indent with tabs.\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "own.md", .data = "Answer briefly.\n" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const workspace = try std.fs.path.join(arena, &.{ root, "work" });
    const own = try std.fs.path.join(arena, &.{ root, "own.md" });
    const machine = try testing.openLocalMachine();
    defer _ = h.beak_close(machine);

    const write_call: vocabulary.OutputItem = .{ .function_call = .{ .id = "c1", .call_id = "c1", .name = "write", .arguments = "{\"path\":\"hello.txt\",\"content\":\"hello\\n\"}" } };
    const said = try arena.dupe(vocabulary.OutputContent, &.{.{ .output_text = .{ .text = "Written." } }});
    const done: vocabulary.OutputItem = .{ .output_message = .{ .id = "m1", .content = .{ .parts = said } } };
    var fake: ai.testing.Fake = .init(arena, &.{
        .{ .events = &.{.{ .completed = .{ .response = .{ .id = "r1", .status = .completed, .output = &.{write_call} }, .sequence_number = 0 } }} },
        .{ .events = &.{.{ .completed = .{ .response = .{ .id = "r2", .status = .completed, .output = &.{done} }, .sequence_number = 0 } }} },
    });
    const model: ai.Model = .{ .id = "m", .name = "M", .architecture = .{ .input_modalities = &.{.text}, .output_modalities = &.{.text} }, .octoii = .{ .provider = "fake", .kinds = &.{.text} } };
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = clock.clock(), .machine = machine, .instructions = own }, .{ .providers = &providers });
    defer siphon.close();
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m", .workspace = workspace }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, .{ .message = .{ .role = .user, .content = .{ .text = "write hello.txt" } } }, "op-1");

    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    const written = try tmp.dir.readFileAlloc(std.testing.io, "work/hello.txt", arena, .unlimited);
    try std.testing.expectEqualStrings("hello\n", written);
    // The model is told, ahead of every input, the instructions it follows — the person's own first, then each
    // folder's from the root down, the workspace's the nearest, last — and its environment, in the log as sent.
    const told = fake.requests.items[0].input.?.parts[0].input_message.content.parts;
    try std.testing.expect(std.mem.indexOf(u8, told[2].input_text.text, workspace) != null);
    const instructions = told[1].input_text.text;
    try std.testing.expect(std.mem.startsWith(u8, instructions, try arena.print("<instructions path=\"{s}\">\nAnswer briefly.\n</instructions>", .{own})));
    try std.testing.expect(std.mem.endsWith(u8, instructions, try arena.print("<instructions path=\"{s}/AGENTS.md\">\nIndent with tabs.\n</instructions>", .{workspace})));
}

test "a stop ends a command the shell runs, its group killed, and its call is answered stopped" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const machine = try testing.openLocalMachine();
    defer _ = h.beak_close(machine);
    const sleep_call: vocabulary.OutputItem = .{ .function_call = .{ .id = "c1", .call_id = "c1", .name = "shell", .arguments = "{\"command\":\"sleep 30\"}" } };
    var fake: ai.testing.Fake = .init(arena, &.{.{ .events = &.{.{ .completed = .{ .response = .{ .id = "r1", .status = .completed, .output = &.{sleep_call} }, .sequence_number = 0 } }} }});
    const model: ai.Model = .{ .id = "m", .name = "M", .architecture = .{ .input_modalities = &.{.text}, .output_modalities = &.{.text} }, .octoii = .{ .provider = "fake", .kinds = &.{.text} } };
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = clock.clock(), .machine = machine }, .{ .providers = &providers });
    defer siphon.close();
    // Unsandboxed, as the stop alone is weighed here.
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m", .mode = .@"full-access", .workspace = workspace }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, .{ .message = .{ .role = .user, .content = .{ .text = "wait" } } }, "op-1");
    const Running = struct {
        siphon: *Siphon,
        fn command(running: *const @This()) bool {
            return running.siphon.runtime.acting.items.len > 0 and std.mem.eql(u8, running.siphon.runtime.acting.items[0].name, tools.Tool.request_name);
        }
    };
    const running: Running = .{ .siphon = siphon };
    try testing.pumpUntil(siphon, &running, Running.command);
    const began = std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
    try threads.stop(siphon.runtime, arena, tid, "person");
    const settled = try testing.pumpUntilSettled(siphon, arena, tid);
    try std.testing.expect(std.Io.Clock.awake.now(std.testing.io).toMilliseconds() - began < 5_000);
    try std.testing.expectEqual(threads.Status.stopped, settled.status);
    const lines = try log.lines(siphon.runtime.volume, &arena, try threads.pathOf(arena, tid));
    try std.testing.expectEqual(log.CallStatus.stopped, (try @import("foundation").json.decode(log.Result, arena, lines[3])).status);
}

test "what a command prints is told on its call's stream as it comes, and the stream let go once its call ended" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const machine = try testing.openLocalMachine();
    defer _ = h.beak_close(machine);
    const printing: vocabulary.OutputItem = .{ .function_call = .{ .id = "c1", .call_id = "c1", .name = "shell", .arguments = "{\"command\":\"printf 'one\\\\n'; sleep 0.4; printf 'two \\u00e9\\\\n'\"}" } };
    var fake: ai.testing.Fake = .init(arena, &.{
        .{ .events = &.{.{ .completed = .{ .response = .{ .id = "r1", .status = .completed, .output = &.{printing} }, .sequence_number = 0 } }} },
        try testing.message(arena, "printed"),
    });
    const model: ai.Model = .{ .id = "m", .name = "M", .architecture = .{ .input_modalities = &.{.text}, .output_modalities = &.{.text} }, .octoii = .{ .provider = "fake", .kinds = &.{.text} } };
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = clock.clock(), .machine = machine }, .{ .providers = &providers });
    defer siphon.close();
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m", .mode = .@"full-access", .workspace = workspace }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, .{ .message = .{ .role = .user, .content = .{ .text = "print" } } }, "op-1");
    // The stream is the call's request's, kept while it runs: each piece as it came, apart as the command printed them.
    const Told = struct {
        siphon: *Siphon,
        key: ?[]const u8 = null,
        fn twice(told: *@This()) bool {
            const runtime = told.siphon.runtime;
            if (told.key == null) for (runtime.acting.items) |request| {
                if (std.mem.eql(u8, request.name, tools.Tool.request_name)) told.key = std.testing.allocator.dupe(u8, request.key) catch return false;
            };
            const stream = runtime.streams.by_key.get(told.key orelse return false) orelse return false;
            return stream.kept.items.len >= 2;
        }
    };
    var told: Told = .{ .siphon = siphon };
    defer if (told.key) |key| std.testing.allocator.free(key);
    try testing.pumpUntil(siphon, &told, Told.twice);
    const kept = siphon.runtime.streams.by_key.get(told.key.?).?.kept.items;
    try std.testing.expectEqualStrings("{\"text\":\"one\\n\"}", kept[0]);
    try std.testing.expectEqualStrings("{\"text\":\"two \u{e9}\\n\"}", kept[1]);
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
    try std.testing.expect(siphon.runtime.streams.by_key.get(told.key.?) == null);
}

test "an image read is handed the model as the file it is, fitted to what every model reads, kept by its content" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "small.png", .data = &small_png });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "wide.png", .data = &wide_png });
    const workspace = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const machine = try testing.openLocalMachine();
    defer _ = h.beak_close(machine);
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = clock.clock(), .machine = machine }, .{});
    defer siphon.close();
    const thread = try threads.create(siphon.runtime, arena, .{ .workspace = workspace }, "create");

    const read = try runTool(siphon, arena, thread, "read", "{\"path\":\"small.png\"}");
    try expectTold("[image/png 64x32]", read, arena);
    try std.testing.expectEqual(@as(usize, 1), read.files.len);
    try std.testing.expectEqualStrings("image/png", read.files[0].media_type);
    try std.testing.expectEqualSlices(u8, &small_png, try threads.stored.read(siphon.runtime.volume, arena, read.files[0].ref));
    // One past what a model reads whole is fitted, its shape kept — opaque, written again as a JPEG — told as it is shown.
    try expectTold("[image/png 1600x8, shown as image/png 1568x7]", try runTool(siphon, arena, thread, "read", "{\"path\":\"wide.png\"}"), arena);
}

test "an image a call handed the model is its result's by reference, and told in words to a model that reads no images" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "shot.png", .data = &small_png });
    const workspace = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const machine = try testing.openLocalMachine();
    defer _ = h.beak_close(machine);
    const reading: vocabulary.OutputItem = .{ .function_call = .{ .id = "c1", .call_id = "c1", .name = "read", .arguments = "{\"path\":\"shot.png\"}" } };
    const answers = [_]ai.testing.fake.Answer{
        .{ .events = &.{.{ .completed = .{ .response = .{ .id = "r1", .status = .completed, .output = &.{reading} }, .sequence_number = 0 } }} },
        try testing.message(arena, "a grey picture"),
    };
    var seeing: ai.testing.Fake = .init(arena, &answers);
    var blind: ai.testing.Fake = .init(arena, &answers);
    const eyes: ai.Model = .{ .id = "eyes", .name = "Eyes", .architecture = .{ .input_modalities = &.{ .text, .image }, .output_modalities = &.{.text} }, .octoii = .{ .provider = "seeing", .kinds = &.{.text} } };
    const words: ai.Model = .{ .id = "words", .name = "Words", .architecture = .{ .input_modalities = &.{.text}, .output_modalities = &.{.text} }, .octoii = .{ .provider = "blind", .kinds = &.{.text} } };
    const providers = [_]ai.driver.Provider{
        .{ .id = "seeing", .name = "Seeing", .driver = seeing.bound(), .models = &.{ai.facts.asFacts(eyes)} },
        .{ .id = "blind", .name = "Blind", .driver = blind.bound(), .models = &.{ai.facts.asFacts(words)} },
    };
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = clock.clock(), .machine = machine }, .{ .providers = &providers });
    defer siphon.close();
    for ([_][]const u8{ "seeing/eyes", "blind/words" }, 0..) |model, place| {
        const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = model, .mode = .@"full-access", .workspace = workspace }, try arena.print("create-{d}", .{place}));
        _ = try threads.deliver(siphon.runtime, arena, tid, .{ .message = .{ .role = .user, .content = .{ .text = "look" } } }, try arena.print("op-{d}", .{place}));
        try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);
        // The log holds the image by its reference, never its bytes.
        const lines = try log.lines(siphon.runtime.volume, &arena, try threads.pathOf(arena, tid));
        try std.testing.expect(std.mem.indexOf(u8, lines[3], "\"ref\":\"sha256:") != null);
        try std.testing.expect(std.mem.indexOf(u8, lines[3], "base64") == null);
    }
    const handed = (try outputOf(seeing.requests.items[1].input.?.parts)).parts;
    try std.testing.expectEqualStrings("[image/png 64x32]", handed[0].input_text.text);
    try std.testing.expectEqualStrings("image/png", handed[1].input_image.octoii.?.media_type.?);
    const told = (try outputOf(blind.requests.items[1].input.?.parts)).parts;
    try std.testing.expectEqualStrings("[an image, not shown: the model blind/words reads no images]", told[1].input_text.text);
}

/// The output of the one call's result among a request's items.
fn outputOf(items: []const vocabulary.Item) !vocabulary.content.TextOr(vocabulary.content.InputContent) {
    for (items) |item| if (item == .function_call_output) return item.function_call_output.output;
    return error.NoResult;
}

/// A tool that gives `lines` numbered lines, as a long output.
const Long = struct {
    const lines = 10_000;

    fn tool() @import("tools.zig").Tool {
        return .{ .name = "long", .description = "Gives many lines.", .parameters = "{\"type\":\"object\"}", .work = .{ .task = run } };
    }

    fn run(_: ?*anyopaque, given: *const tools.Tool.Run) anyerror!tools.Tool.Output {
        var out: std.Io.Writer.Allocating = .init(given.arena);
        for (1..lines + 1) |n| try out.writer.print("line {d}\n", .{n});
        return .{ .text = out.written() };
    }
};

test "an output past what the model is told is cut after its last line that fits, the whole of it kept for the model" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "outputs");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const outputs = try std.fs.path.join(arena, &.{ root, "outputs" });
    const machine = try testing.openLocalMachine();
    defer _ = h.beak_close(machine);
    const long_call: vocabulary.OutputItem = .{ .function_call = .{ .id = "c1", .call_id = "c1", .name = "long", .arguments = "{}" } };
    const said = try arena.dupe(vocabulary.OutputContent, &.{.{ .output_text = .{ .text = "Read." } }});
    const done: vocabulary.OutputItem = .{ .output_message = .{ .id = "m1", .content = .{ .parts = said } } };
    var fake: ai.testing.Fake = .init(arena, &.{
        .{ .events = &.{.{ .completed = .{ .response = .{ .id = "r1", .status = .completed, .output = &.{long_call} }, .sequence_number = 0 } }} },
        .{ .events = &.{.{ .completed = .{ .response = .{ .id = "r2", .status = .completed, .output = &.{done} }, .sequence_number = 0 } }} },
    });
    const model: ai.Model = .{ .id = "m", .name = "M", .architecture = .{ .input_modalities = &.{.text}, .output_modalities = &.{.text} }, .octoii = .{ .provider = "fake", .kinds = &.{.text} } };
    const providers = [_]ai.driver.Provider{.{ .id = "fake", .name = "Fake", .driver = fake.bound(), .models = &.{ai.facts.asFacts(model)} }};
    var clock: testing.Clock = .{ .now_ms = 1_000 };
    const siphon = try Siphon.open(std.testing.allocator, .{ .io = std.testing.io, .clock = clock.clock(), .machine = machine, .outputs = outputs }, .{ .providers = &providers });
    defer siphon.close();
    try siphon.tools.add(Long.tool());
    const tid = try threads.create(siphon.runtime, arena, .{ .title = "Test", .model = "fake/m", .workspace = root }, "create");
    _ = try threads.deliver(siphon.runtime, arena, tid, .{ .message = .{ .role = .user, .content = .{ .text = "read it all" } } }, "op-1");
    try std.testing.expectEqual(threads.Status.replied, (try testing.pumpUntilSettled(siphon, arena, tid)).status);

    const sent = fake.requests.items[1].input.?.parts;
    const output = sent[sent.len - 1].function_call_output.output.text;
    try std.testing.expect(output.len < tools.Tool.told_bytes_max + 200);
    const note_at = std.mem.lastIndexOf(u8, output, "\n[cut at ").?;
    try std.testing.expect(std.mem.endsWith(u8, output[0 .. note_at + 1], "\n"));
    var kept = (try tmp.dir.openDir(std.testing.io, "outputs", .{ .iterate = true })).iterate();
    const file = (try kept.next(std.testing.io)).?;
    try std.testing.expect(std.mem.endsWith(u8, file.name, ".txt"));
    const whole = try std.fs.path.join(arena, &.{ outputs, file.name });
    try std.testing.expect(std.mem.endsWith(u8, output, try arena.print("; all of it in {s}]", .{whole})));
    const kept_text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, whole, arena, .unlimited);
    try std.testing.expect(std.mem.endsWith(u8, kept_text, "line 10000\n"));
}
