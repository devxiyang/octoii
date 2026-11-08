//! `question`: the tool a thread's model asks the person by — some questions at once, each with options to choose one
//! of, or several, the person free to answer in words of their own instead; or with none, answered in words alone; any
//! of them left unanswered, as the person likes, or all dismissed, answered none. Its call runs as a fiber that makes a
//! durable `question` request the person answers, the JSON Schema of the answer made from the questions it asks; the
//! answers come back to the model as each question and what was chosen or written, dismissed questions as a call the
//! person declined. A stop reaches it as it reaches every call.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const typebox = @import("typebox");
const runtime_ = @import("../runtime.zig");
const Runtime = runtime_.Runtime;
const Phase = runtime_.Phase;
const Request = runtime_.Request;
const Tool = @import("Tool.zig");
const Table = @import("Table.zig");
const calls = @import("calls.zig");

/// The program of a question's fiber.
pub const program = "siphon.question";
/// The name of the request the person answers.
pub const request_name = "question";

pub const tool: Tool = .{
    .name = "question",
    .description =
    \\Asks the person questions while you work: to learn what they prefer or need, to clear up what is unclear, or to have them choose the way to go. Ask together the questions that belong together. A question with options is answered by choosing one, or several with multiple, and the person may always answer in words of their own instead, so give no option for that; a question with no options is answered in words. Put the option you recommend first, its label ending in "(Recommended)". The answers come back as each question and what was chosen or written, a question the person left unanswered as Unanswered. The person may dismiss the questions, answering none.
    ,
    .parameters = typebox.of(Arguments),
    .work = .{ .program = program },
};

/// What `question` is called with.
const Arguments = struct {
    questions: []const Question,

    pub const schema = .{
        .questions = .{ .description = "The questions, asked at once", .minItems = 1 },
    };
};

const Question = struct {
    question: []const u8,
    header: []const u8,
    options: []const Option = &.{},
    multiple: bool = false,

    pub const schema = .{
        .question = .{ .description = "The question, whole" },
        .header = .{ .description = "A very short label for it", .maxLength = 30 },
        .options = .{ .description = "The choices; none for a question answered in words" },
        .multiple = .{ .description = "Whether more than one choice may be chosen" },
    };
};

const Option = struct {
    label: []const u8,
    description: ?[]const u8 = null,

    pub const schema = .{
        .label = .{ .description = "The choice, in a few words" },
        .description = .{ .description = "What choosing it means" },
    };
};

/// The person's answer: each question's, in its order — the labels chosen and words of their own; none for a question
/// they left unanswered — or that they dismissed the questions, answering none.
const Answer = struct { dismissed: bool = false, answers: []const []const []const u8 = &.{} };

/// Adds `question` to the tools of `table`, its fiber's program to `runtime`, and has the person answer its requests.
pub fn register(runtime: *Runtime, table: *Table) !void {
    try runtime.register(.{ .kind = program, .stop_handler = true, .phase = asking });
    try runtime.askPerson(request_name, .{ .made = answerSchemaOf });
    try table.add(tool);
}

/// Where a question's fiber stands: its request waiting on the person, by its key.
const Asking = struct { key: []const u8 };

fn asking(_: ?*anyopaque, run: *Phase) anyerror!void {
    if (run.checkpoint.len == 0) {
        if (run.stop_handler) return calls.endWith(run, try Tool.stoppedBefore(run.arena));
        const key = try run.mint();
        try run.request(request_name, key, foundation.json.Raw{ .text = run.input });
        return run.waitForMail(Asking{ .key = key }, key);
    }
    if (run.stop_handler) return calls.endWith(run, try Tool.noted(run.arena, .stopped, "stopped before the person answered"));
    const waiting = try foundation.json.decode(Asking, run.arena, run.checkpoint);
    const mail = try run.mailOf(waiting.key) orelse return run.waitForMail(Phase.kept, waiting.key);
    try run.take(waiting.key);
    if (!std.mem.eql(u8, mail.name, Request.answered_name)) return calls.endWith(run, .{ .status = .@"tool-error", .output = mail.payload });
    const answer = try foundation.json.decode(Answer, run.arena, mail.payload);
    if (answer.dismissed) return calls.endWith(run, try Tool.noted(run.arena, .rejected, "the person dismissed the questions, answering none"));
    const asked = try foundation.json.decode(Arguments, run.arena, run.input);
    return calls.endWith(run, .{ .status = .ok, .output = try answered(run.arena, asked.questions, answer.answers) });
}

/// The answers as the model reads them: each question, then what was chosen or written of it, Unanswered for none —
/// an answer to each, as the answer's schema has it.
fn answered(arena: Allocator, questions: []const Question, answers: []const []const []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    try writer.writeAll("The person answered:");
    for (questions, answers) |question, given| {
        const text = if (given.len == 0) "Unanswered" else try std.mem.join(arena, ", ", given);
        try writer.print("\n\"{s}\"=\"{s}\"", .{ question.question, text });
    }
    return out.written();
}

/// The JSON Schema of the answer to the questions `payload` asks: dismissed, or an answer to each in its order — a list
/// of the labels chosen and words of the person's own, one at most where one is chosen, none where it is left.
fn answerSchemaOf(arena: Allocator, payload: []const u8) ![]const u8 {
    const asked = try foundation.json.decode(Arguments, arena, payload);
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    try writer.writeAll(
        \\{"anyOf":[{"type":"object","properties":{"dismissed":{"const":true}},"required":["dismissed"],"additionalProperties":false},
    );
    try writer.print("{{\"type\":\"object\",\"properties\":{{\"answers\":{{\"type\":\"array\",\"minItems\":{d},\"maxItems\":{d},\"prefixItems\":[", .{ asked.questions.len, asked.questions.len });
    for (asked.questions, 0..) |question, at| {
        if (at > 0) try writer.writeByte(',');
        try writer.writeAll(
            \\{"type":"array","items":{"type":"string","minLength":1}
        );
        if (!question.multiple) try writer.writeAll(
            \\,"maxItems":1
        );
        try writer.writeByte('}');
    }
    try writer.writeAll(
        \\]}},"required":["answers"],"additionalProperties":false}]}
    );
    return out.written();
}

test "the answer questions take: dismissed, or each question's choices and words, one at most for a single choice" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const payload =
        \\{"questions":[{"question":"Which stack?","header":"Stack","options":[{"label":"Bun"},{"label":"Node"}]},
        \\{"question":"Which checks?","header":"Checks","options":[{"label":"lint"},{"label":"test"}],"multiple":true},
        \\{"question":"Anything else?","header":"Notes"}]}
    ;
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena, try answerSchemaOf(arena, payload), .{});
    const fits = struct {
        fn of(a: Allocator, s: std.json.Value, given: []const u8) !bool {
            return (try typebox.problems(a, s, try std.json.parseFromSliceLeaky(std.json.Value, a, given, .{}))).len == 0;
        }
    };
    try std.testing.expect(try fits.of(arena, schema, "{\"dismissed\":true}"));
    try std.testing.expect(!try fits.of(arena, schema, "{\"dismissed\":false}"));
    try std.testing.expect(try fits.of(arena, schema, "{\"answers\":[[\"Bun\"],[\"lint\",\"test\",\"also e2e\"],[]]}"));
    try std.testing.expect(!try fits.of(arena, schema, "{\"answers\":[[\"Bun\",\"Node\"],[],[]]}"));
    try std.testing.expect(!try fits.of(arena, schema, "{\"answers\":[[\"Bun\"]]}"));
    const asked = try foundation.json.decode(Arguments, arena, payload);
    try std.testing.expectEqualStrings(
        \\The person answered:
        \\"Which stack?"="Bun"
        \\"Which checks?"="lint, also e2e"
        \\"Anything else?"="Unanswered"
    , try answered(arena, asked.questions, &.{ &.{"Bun"}, &.{ "lint", "also e2e" }, &.{} }));
}
