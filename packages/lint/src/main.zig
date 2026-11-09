//! The lint of Octoii's Zig: what neither the compiler nor the tests see of how the code holds memory, read from each
//! file's syntax tree, by the ways Zig's own code keeps to.
//!
//! - **Allocations.** What releases an allocation directly follows it, as Zig's documentation of `errdefer` has it. An
//!   allocation is kept by what its value goes to — through a `try`, a `catch`, parentheses, a literal's field or element,
//!   an `if`'s or a `switch`'s branch: a name, a `defer` or an `errdefer` releasing it, or a `return` giving it back, the
//!   very next statement; a `return`; a field, what a pointer points at, or an element; or a call that keeps it and
//!   cannot fail — one that assumes room made for it before, or whose name ends in `Owned`, taking what it is given
//!   over. Nothing after it in the statement may fail. One among the
//!   arguments of a call that may fail is lost as the call fails (`allocation-in-fallible-arguments`); one kept any
//!   other way is one a failure may lose, or that nothing frees (`allocation-unguarded`).
//! - **Names.** An allocator is named as Zig names one, so that its name says whether what it allocates is freed one
//!   by one or goes with an arena (`allocator-name`): an arena's allocator `arena` or `<what>_arena`; any other `gpa`,
//!   `allocator` or `<what>_allocator`; an `ArenaAllocator` itself `arena_allocator`, or `arena` or `<what>_arena`. The
//!   lint knows an arena by its name alone.
//!
//! Each finding is told as the compiler tells an error — where, what, its line with what it is about marked — with a
//! note on how to set it right, and the lint fails where it found any.
const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var found: usize = 0;
    for (args[1..]) |root| found += try lintTree(init.gpa, init.io, root);
    if (found > 0) std.debug.print("{d} finding{s}\n", .{ found, if (found == 1) "" else "s" });
    return if (found == 0) 0 else 1;
}

/// Lints every Zig file under the directory `root`, telling each finding, and gives how many there were.
fn lintTree(gpa: Allocator, io: std.Io, root: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var found: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const source = try dir.readFileAllocOptions(io, entry.path, gpa, .limited(16 << 20), .of(u8), 0);
        defer gpa.free(source);
        found += try lintFile(gpa, .{ .root = root, .path = entry.path }, source);
    }
    return found;
}

/// Where a file is, as a finding names it.
const Named = struct { root: []const u8, path: []const u8 };

/// Lints one file, telling each finding, and gives how many there were.
fn lintFile(gpa: Allocator, named: Named, source: [:0]const u8) !usize {
    var arena_allocator: std.heap.ArenaAllocator = .init(gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var tree = try Ast.parse(gpa, source, .{});
    defer tree.deinit(gpa);
    const findings = try lint(arena, &tree);
    for (findings) |finding| std.debug.print("{s}", .{try render(arena, &tree, named, finding)});
    return findings.len;
}

/// The findings in a file's syntax tree, in the order of the file.
fn lint(arena: Allocator, tree: *const Ast) ![]const Finding {
    var file: File = try .read(arena, tree);
    for (0..tree.nodes.len) |at| {
        const node = nodeAt(at);
        if (allocationOf(tree, node)) |allocation| try file.judgeAllocation(allocation);
        try file.judgeNames(node);
    }
    std.mem.sort(Finding, file.findings.items, {}, Finding.before);
    return file.findings.items;
}

const Rule = enum { @"allocation-in-fallible-arguments", @"allocation-unguarded", @"allocator-name" };

/// What the lint found: the rule, the tokens it is about, what is wrong, and how to set it right — its first line said
/// in the note, the code it suggests on the lines after.
const Finding = struct {
    rule: Rule,
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
    what: []const u8,
    help: []const u8,

    fn before(_: void, a: Finding, b: Finding) bool {
        return a.first < b.first;
    }
};

/// An allocation from an allocator no arena's: its call, the allocator as written, and what gives it back.
const Allocation = struct {
    node: Ast.Node.Index,
    allocator: []const u8,
    release: []const u8,
};

/// Where an allocation's value goes: up through what passes a value on whole, to what takes it.
const Way = struct {
    /// The allocation with its own `try` or `catch`.
    unit: Ast.Node.Index,
    /// The first token after which a step that fails would lose the allocation: past its own `catch`, and past the
    /// branches of an `if` or a `switch` it came out of.
    after: Ast.TokenIndex,
    to: To,

    const To = union(enum) {
        /// Among the arguments of a call.
        call: Ast.Node.Index,
        /// The value of a `return`.
        returned: Ast.Node.Index,
        /// What is put in a field, in what a pointer points at, or in an element.
        held: Ast.Node.Index,
        /// Bound to a name, by a declaration or an assignment.
        bound: Bound,
        /// Anything else: an operand, a condition, what is thrown away.
        nothing,
    };

    const Bound = struct { statement: Ast.Node.Index, name: []const u8 };
};

/// A file as the lint reads it: its syntax tree, each node's parent, the calls whose failure is taken, and what it found.
const File = struct {
    arena: Allocator,
    tree: *const Ast,
    parents: []const Ast.Node.OptionalIndex,
    /// The operands of a `try` or a `catch`.
    fallible: std.AutoHashMapUnmanaged(Ast.Node.Index, void),
    findings: std.ArrayList(Finding) = .empty,

    fn read(arena: Allocator, tree: *const Ast) !File {
        var fallible: std.AutoHashMapUnmanaged(Ast.Node.Index, void) = .empty;
        for (0..tree.nodes.len) |at| {
            const node = nodeAt(at);
            switch (tree.nodeTag(node)) {
                .@"try" => try fallible.put(arena, tree.nodeData(node).node, {}),
                .@"catch" => try fallible.put(arena, tree.nodeData(node).node_and_node[0], {}),
                else => {},
            }
        }
        return .{ .arena = arena, .tree = tree, .parents = try parentsOf(arena, tree), .fallible = fallible };
    }

    fn parentOf(file: *const File, node: Ast.Node.Index) ?Ast.Node.Index {
        return file.parents[@backingInt(node)].unwrap();
    }

    /// Tells `allocation` where what its value goes to does not keep it as Zig keeps one.
    fn judgeAllocation(file: *File, allocation: Allocation) !void {
        const tree = file.tree;
        const way = file.wayOf(allocation.node);
        switch (way.to) {
            .call => |call| {
                if (file.fallible.contains(call)) return file.tellFallibleCall(allocation, way, call);
                if (!keepsArguments(tree, call)) return file.tellUnkept(allocation, way);
                if (failsWithin(tree, way.after, tree.lastToken(call))) return file.tellLaterFailure(allocation, way);
            },
            .returned, .held => |holder| if (failsWithin(tree, way.after, tree.lastToken(holder))) {
                return file.tellLaterFailure(allocation, way);
            },
            .bound => |bound| {
                if (failsWithin(tree, way.after, tree.lastToken(bound.statement))) return file.tellLaterFailure(allocation, way);
                if (file.nextStatement(bound.statement)) |next| if (releases(tree, next, bound.name)) return;
                return file.tellUnreleased(allocation, way, bound);
            },
            .nothing => return file.tellUnkept(allocation, way),
        }
    }

    /// Follows the value of `allocation` up to what takes it.
    fn wayOf(file: *const File, allocation: Ast.Node.Index) Way {
        const tree = file.tree;
        var unit = allocation;
        if (file.parentOf(allocation)) |parent| switch (tree.nodeTag(parent)) {
            .@"try" => unit = parent,
            .@"catch" => if (tree.nodeData(parent).node_and_node[0] == allocation) {
                unit = parent;
            },
            else => {},
        };
        var top = unit;
        var after = tree.lastToken(unit) + 1;
        while (file.parentOf(top)) |parent| : (top = parent) {
            if (!passesOn(tree, parent, top)) break;
            switch (tree.nodeTag(parent)) {
                .@"catch", .@"if", .if_simple, .@"switch", .switch_comma => after = tree.lastToken(parent) + 1,
                else => {},
            }
        }
        return .{ .unit = unit, .after = after, .to = file.takerOf(top) };
    }

    /// What takes the value of `top`, which passes it on to nothing further.
    fn takerOf(file: *const File, top: Ast.Node.Index) Way.To {
        const tree = file.tree;
        const taker = file.parentOf(top) orelse return .nothing;
        var buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&buffer, taker)) |call| {
            return if (isAmong(Ast.Node.Index, top, call.ast.params)) .{ .call = taker } else .nothing;
        }
        if (tree.fullVarDecl(taker)) |declaration| {
            if (declaration.ast.init_node.unwrap() != top) return .nothing;
            return .{ .bound = .{ .statement = taker, .name = tree.tokenSlice(declaration.ast.mut_token + 1) } };
        }
        switch (tree.nodeTag(taker)) {
            .@"return" => return .{ .returned = taker },
            .assign => {
                const target, const value = tree.nodeData(taker).node_and_node;
                if (value != top) return .nothing;
                return switch (tree.nodeTag(target)) {
                    .field_access, .deref, .array_access => .{ .held = taker },
                    .identifier => if (std.mem.eql(u8, tree.getNodeSource(target), "_")) .nothing else .{ .bound = .{ .statement = taker, .name = tree.getNodeSource(target) } },
                    else => .nothing,
                };
            },
            else => return .nothing,
        }
    }

    /// The statement after `statement` in its block; null for the last, or for one in no block.
    fn nextStatement(file: *const File, statement: Ast.Node.Index) ?Ast.Node.Index {
        const block = file.parentOf(statement) orelse return null;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = file.tree.blockStatements(&buffer, block) orelse return null;
        for (statements, 0..) |each, index| {
            if (each == statement) return if (index + 1 < statements.len) statements[index + 1] else null;
        }
        return null;
    }

    /// The statement of a block that `node` is part of; null for a node in no block.
    fn statementOf(file: *const File, node: Ast.Node.Index) ?Ast.Node.Index {
        var statement = node;
        var buffer: [2]Ast.Node.Index = undefined;
        while (file.parentOf(statement)) |parent| : (statement = parent) {
            if (file.tree.blockStatements(&buffer, parent) != null) return statement;
        }
        return null;
    }

    fn tellFallibleCall(file: *File, allocation: Allocation, way: Way, call: Ast.Node.Index) !void {
        const what = try file.arena.print("'{s}' is allocated among the arguments of '{s}', which may fail: as it fails, nothing frees what was allocated", .{ file.shown(allocation.node), file.shown(calleeOf(file.tree, call)) });
        const help = try file.roomFirst(call, null) orelse try file.bindFirst(allocation, way);
        try file.tell(.@"allocation-in-fallible-arguments", way, what, help);
    }

    fn tellUnreleased(file: *File, allocation: Allocation, way: Way, bound: Way.Bound) !void {
        const what = try file.arena.print("'{s}' holds what '{s}' allocated, but the statement after it does not release it: a failure before it is released loses it", .{ bound.name, file.shown(allocation.node) });
        const insert = if (file.nextStatement(bound.statement)) |next| file.insertOf(next, bound.name) else null;
        const help = if (insert) |call| try file.roomFirst(call, bound.statement) else null;
        try file.tell(.@"allocation-unguarded", way, what, help orelse try file.arena.print(
            "release it on the very next statement, 'errdefer' where it is kept past this scope, 'defer' where it is done with in it:\n    errdefer {s}.{s}({s});",
            .{ allocation.allocator, allocation.release, bound.name },
        ));
    }

    fn tellLaterFailure(file: *File, allocation: Allocation, way: Way) !void {
        const what = try file.arena.print("'{s}' is kept by its statement, but a step after it there may fail first, which loses it", .{file.shown(allocation.node)});
        try file.tell(.@"allocation-unguarded", way, what, try file.bindFirst(allocation, way));
    }

    fn tellUnkept(file: *File, allocation: Allocation, way: Way) !void {
        const what = switch (way.to) {
            .call => |call| try file.arena.print("'{s}' is handed to '{s}', which does not keep it as a call that assumes room for it does, so nothing frees it", .{ file.shown(allocation.node), file.shown(calleeOf(file.tree, call)) }),
            else => try file.arena.print("'{s}' goes to nothing that keeps it — a name, a 'return', a field or a call that keeps it — so nothing frees it", .{file.shown(allocation.node)}),
        };
        try file.tell(.@"allocation-unguarded", way, what, try file.bindFirst(allocation, way));
    }

    /// The help that makes room first: where `call` puts something in a list or a map, the call that makes room for it,
    /// `made` the statement between them where there is one, and the call that assumes the room; null for another call.
    fn roomFirst(file: *File, call: Ast.Node.Index, made: ?Ast.Node.Index) !?[]const u8 {
        const tree = file.tree;
        var buffer: [1]Ast.Node.Index = undefined;
        const full = tree.fullCall(&buffer, call).?;
        if (tree.nodeTag(full.ast.fn_expr) != .field_access) return null;
        const holder, const method_token = tree.nodeData(full.ast.fn_expr).node_and_token;
        const assuming = assumingOf(tree.tokenSlice(method_token)) orelse return null;
        const gpa = if (full.ast.params.len > 0 and isAllocator(tree.getNodeSource(full.ast.params[0]))) tree.getNodeSource(full.ast.params[0]) else null;
        var arguments: std.ArrayList(u8) = .empty;
        for (full.ast.params[@intFromBool(gpa != null)..], 0..) |param, index| {
            if (index > 0) try arguments.appendSlice(file.arena, ", ");
            try arguments.appendSlice(file.arena, tree.getNodeSource(param));
        }
        const room = try file.arena.print("try {s}.ensureUnusedCapacity({s}{s}1);", .{ tree.getNodeSource(holder), gpa orelse "", if (gpa != null) ", " else "" });
        const between = if (made) |statement| try file.arena.print("\n    {s}", .{file.statementLine(statement, null, "") orelse "…"}) else "";
        return try file.arena.print("make room first, so that putting it in cannot fail, and put it in with the call that assumes the room:\n    {s}{s}\n    {s}.{s}({s});", .{ room, between, tree.getNodeSource(holder), assuming, arguments.items });
    }

    /// The help that binds an allocation first, a release beside it, and uses the name where it was.
    fn bindFirst(file: *File, allocation: Allocation, way: Way) ![]const u8 {
        const binding = try file.arena.print("const owned = {s};\n    errdefer {s}.{s}(owned);", .{ file.tree.getNodeSource(way.unit), allocation.allocator, allocation.release });
        const statement = file.statementOf(way.unit) orelse return try file.arena.print("allocate it on a statement of its own, freed should a later step fail, and use the name in its place:\n    {s}", .{binding});
        const rewritten = file.statementLine(statement, way.unit, "owned") orelse "… owned …";
        return try file.arena.print("allocate it on a statement of its own, freed should a later step fail, and use the name in its place:\n    {s}\n    {s}", .{ binding, rewritten });
    }

    /// `statement` on one line, `replaced` in it given as `with`, and its `;`; null for a statement on several lines.
    fn statementLine(file: *const File, statement: Ast.Node.Index, replaced: ?Ast.Node.Index, with: []const u8) ?[]const u8 {
        const tree = file.tree;
        const text = tree.getNodeSource(statement);
        if (std.mem.indexOfScalar(u8, text, '\n') != null) return null;
        const start = tree.tokenStart(tree.firstToken(statement));
        const last = tree.lastToken(statement);
        const ended = last + 1 < tree.tokens.len and tree.tokenTag(last + 1) == .semicolon;
        const semicolon = if (ended) ";" else "";
        const node = replaced orelse return file.arena.print("{s}{s}", .{ text, semicolon }) catch null;
        const from = tree.tokenStart(tree.firstToken(node)) - start;
        const to = from + tree.getNodeSource(node).len;
        return file.arena.print("{s}{s}{s}{s}", .{ text[0..from], with, text[to..], semicolon }) catch null;
    }

    /// The call of `statement` that puts what `name` holds in a list or a map, and may fail; null for none.
    fn insertOf(file: *const File, statement: Ast.Node.Index, name: []const u8) ?Ast.Node.Index {
        const tree = file.tree;
        if (tree.nodeTag(statement) != .@"try") return null;
        const call = tree.nodeData(statement).node;
        var buffer: [1]Ast.Node.Index = undefined;
        const full = tree.fullCall(&buffer, call) orelse return null;
        if (tree.nodeTag(full.ast.fn_expr) != .field_access) return null;
        _, const method_token = tree.nodeData(full.ast.fn_expr).node_and_token;
        if (assumingOf(tree.tokenSlice(method_token)) == null) return null;
        for (full.ast.params) |param| if (std.mem.eql(u8, tree.getNodeSource(param), name)) return call;
        return null;
    }

    /// Tells a declaration of an allocator, or of an `ArenaAllocator`, named as Zig names neither.
    fn judgeNames(file: *File, node: Ast.Node.Index) !void {
        const tree = file.tree;
        var buffer: [1]Ast.Node.Index = undefined;
        if (tree.nodeTag(node) == .fn_decl) return;
        if (tree.fullFnProto(&buffer, node)) |proto| {
            var params = proto.iterate(tree);
            while (params.next()) |param| {
                const name_token = param.name_token orelse continue;
                const type_node: Ast.Node.OptionalIndex = if (param.type_expr) |type_expr| type_expr.toOptional() else .none;
                try file.judgeName(name_token, type_node, .none);
            }
        } else if (tree.fullContainerField(node)) |field| {
            if (!field.ast.tuple_like) try file.judgeName(field.ast.main_token, field.ast.type_expr, .none);
        } else if (tree.fullVarDecl(node)) |declaration| {
            try file.judgeName(declaration.ast.mut_token + 1, declaration.ast.type_node, declaration.ast.init_node);
        }
    }

    fn judgeName(file: *File, name_token: Ast.TokenIndex, type_node: Ast.Node.OptionalIndex, init_node: Ast.Node.OptionalIndex) !void {
        const tree = file.tree;
        const name = tree.tokenSlice(name_token);
        if (std.mem.eql(u8, name, "_")) return;
        const kind = kindOf(tree, type_node, init_node) orelse return;
        const well_named = switch (kind) {
            .allocator => isAllocatorName(name),
            .arena => isArenaName(name),
            .arena_state => isArenaStateName(name),
        };
        if (well_named) return;
        const what = switch (kind) {
            .allocator => try file.arena.print("an allocator named '{s}': Zig names an arena's allocator 'arena' or '<what>_arena', and any other 'gpa', 'allocator' or '<what>_allocator', so that the name says whether what it allocates is freed", .{name}),
            .arena => try file.arena.print("'{s}' is an arena's allocator, but is named as one whose every allocation is freed", .{name}),
            .arena_state => try file.arena.print("an 'ArenaAllocator' named '{s}': Zig names one 'arena_allocator', or 'arena' or '<what>_arena' as a field", .{name}),
        };
        const help = switch (kind) {
            .allocator => "name it 'arena' if what it allocates goes with an arena, else 'gpa'",
            .arena => "name it 'arena', or '<what>_arena' beside another arena",
            .arena_state => "name it 'arena_allocator', and its allocator 'arena'",
        };
        try file.findings.append(file.arena, .{ .rule = .@"allocator-name", .first = name_token, .last = name_token, .what = what, .help = help });
    }

    fn tell(file: *File, rule: Rule, way: Way, what: []const u8, help: []const u8) !void {
        const tree = file.tree;
        try file.findings.append(file.arena, .{ .rule = rule, .first = tree.firstToken(way.unit), .last = tree.lastToken(way.unit), .what = what, .help = help });
    }

    /// The source of `node` as a finding quotes it: its first line.
    fn shown(file: *const File, node: Ast.Node.Index) []const u8 {
        const text = file.tree.getNodeSource(node);
        const end = std.mem.indexOfScalar(u8, text, '\n') orelse return text;
        return file.arena.print("{s} …", .{std.mem.trimEnd(u8, text[0..end], " ")}) catch text[0..end];
    }
};

/// A finding as the compiler tells an error: where and what, its line with what it is about marked, and a note on how
/// to set it right.
fn render(arena: Allocator, tree: *const Ast, named: Named, finding: Finding) ![]const u8 {
    const at = tree.tokenLocation(0, finding.first);
    const line = tree.source[at.line_start..at.line_end];
    const last = tree.tokenLocation(0, finding.last);
    const end = if (last.line == at.line) last.column + tree.tokenSlice(finding.last).len else line.len;
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    try writer.print("{s}/{s}:{d}:{d}: error: {s} [{s}]\n{s}\n", .{ named.root, named.path, at.line + 1, at.column + 1, finding.what, @tagName(finding.rule), line });
    try writer.splatByteAll(' ', at.column);
    try writer.writeByte('^');
    try writer.splatByteAll('~', end -| (at.column + 1));
    try writer.print("\n{s}/{s}:{d}:{d}: note: {s}\n", .{ named.root, named.path, at.line + 1, at.column + 1, finding.help });
    return out.written();
}

/// Each node's parent: the nearest node around it, by the tokens nodes span.
fn parentsOf(arena: Allocator, tree: *const Ast) ![]const Ast.Node.OptionalIndex {
    const spans = try arena.alloc(Span, tree.nodes.len);
    for (spans, 0..) |*span, at| span.* = .{ .node = nodeAt(at), .first = tree.firstToken(nodeAt(at)), .last = tree.lastToken(nodeAt(at)) };
    std.mem.sort(Span, spans, {}, Span.outerFirst);
    const parents = try arena.alloc(Ast.Node.OptionalIndex, tree.nodes.len);
    var around: std.ArrayList(Span) = .empty;
    for (spans) |span| {
        while (around.items.len > 0 and around.items[around.items.len - 1].last < span.last) _ = around.pop();
        parents[@backingInt(span.node)] = if (around.items.len > 0) around.items[around.items.len - 1].node.toOptional() else .none;
        try around.append(arena, span);
    }
    return parents;
}

/// The tokens a node spans.
const Span = struct {
    node: Ast.Node.Index,
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,

    /// Orders spans by where they begin, the wider of two that begin together first.
    fn outerFirst(_: void, a: Span, b: Span) bool {
        if (a.first != b.first) return a.first < b.first;
        if (a.last != b.last) return a.last > b.last;
        return @backingInt(a.node) < @backingInt(b.node);
    }
};

/// Whether `parent` passes on the value of its child `child` whole, as its own.
fn passesOn(tree: *const Ast, parent: Ast.Node.Index, child: Ast.Node.Index) bool {
    switch (tree.nodeTag(parent)) {
        .@"try", .grouped_expression => return true,
        .@"catch" => return tree.nodeData(parent).node_and_node[0] == child,
        else => {},
    }
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&buffer, parent)) |literal| return isAmong(Ast.Node.Index, child, literal.ast.fields);
    if (tree.fullArrayInit(&buffer, parent)) |literal| return isAmong(Ast.Node.Index, child, literal.ast.elements);
    if (tree.fullIf(parent)) |branches| return child == branches.ast.then_expr or child.toOptional() == branches.ast.else_expr;
    if (tree.fullSwitchCase(parent)) |case| return child == case.ast.target_expr;
    if (tree.fullSwitch(parent)) |whole| return isAmong(Ast.Node.Index, child, whole.ast.cases);
    return false;
}

/// Whether a step among the tokens from `from` to `to` may fail: a `try`, or a `return` out of it.
fn failsWithin(tree: *const Ast, from: Ast.TokenIndex, to: Ast.TokenIndex) bool {
    var token = from;
    while (token <= to) : (token += 1) switch (tree.tokenTag(token)) {
        .keyword_try, .keyword_return => return true,
        else => {},
    };
    return false;
}

/// Whether `statement` releases what `name` holds, or gives it back: a `defer`, an `errdefer` or a `return` that says it.
fn releases(tree: *const Ast, statement: Ast.Node.Index, name: []const u8) bool {
    return switch (tree.nodeTag(statement)) {
        .@"defer", .@"errdefer", .@"return" => mentions(tree, statement, name),
        else => false,
    };
}

/// Whether a call keeps what it is given and cannot fail: one that assumes room made before, or one whose name says it
/// takes what it is given over, as `fromOwnedSlice` does — a name ending in `Owned`.
fn keepsArguments(tree: *const Ast, call: Ast.Node.Index) bool {
    const callee = lastName(tree.getNodeSource(calleeOf(tree, call)));
    return std.mem.indexOf(u8, callee, "AssumeCapacity") != null or std.mem.startsWith(u8, callee, "fromOwned") or std.mem.endsWith(u8, callee, "Owned");
}

fn calleeOf(tree: *const Ast, call: Ast.Node.Index) Ast.Node.Index {
    var buffer: [1]Ast.Node.Index = undefined;
    return tree.fullCall(&buffer, call).?.ast.fn_expr;
}

/// The method that puts in what `method` puts in, assuming room made before; null for a method of no list or map.
fn assumingOf(method: []const u8) ?[]const u8 {
    const pairs = [_][2][]const u8{
        .{ "append", "appendAssumeCapacity" },
        .{ "put", "putAssumeCapacity" },
        .{ "putNoClobber", "putAssumeCapacityNoClobber" },
        .{ "getOrPut", "getOrPutAssumeCapacity" },
    };
    for (pairs) |pair| if (std.mem.eql(u8, pair[0], method)) return pair[1];
    return null;
}

/// The functions that allocate what they give, their allocator their first argument.
const allocating_functions = [_][]const u8{ "std.mem.concat", "std.mem.concatWithSentinel", "std.mem.join", "std.mem.joinZ", "std.fs.path.join", "std.fs.path.joinZ" };

/// The methods of an allocator that allocate what they give.
const allocating_methods = [_][]const u8{ "alloc", "allocSentinel", "alignedAlloc", "create", "dupe", "dupeZ", "dupeSentinel", "print", "printSentinel", "realloc" };

/// The methods of a list that give what it holds over to the caller, their allocator their first argument.
const owning_methods = [_][]const u8{ "toOwnedSlice", "toOwnedSliceSentinel" };

/// `node` as an allocation from an allocator no arena's; null for any other node.
fn allocationOf(tree: *const Ast, node: Ast.Node.Index) ?Allocation {
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return null;
    const callee = tree.getNodeSource(call.ast.fn_expr);
    const by_argument = isAmong([]const u8, callee, &allocating_functions) or
        (tree.nodeTag(call.ast.fn_expr) == .field_access and isAmong([]const u8, lastName(callee), &owning_methods));
    if (by_argument) {
        if (call.ast.params.len == 0) return null;
        return allocationBy(node, tree.getNodeSource(call.ast.params[0]), "free");
    }
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
    const receiver, const method_token = tree.nodeData(call.ast.fn_expr).node_and_token;
    const method = tree.tokenSlice(method_token);
    if (!isAmong([]const u8, method, &allocating_methods)) return null;
    return allocationBy(node, tree.getNodeSource(receiver), if (std.mem.eql(u8, method, "create")) "destroy" else "free");
}

fn allocationBy(node: Ast.Node.Index, allocator: []const u8, release: []const u8) ?Allocation {
    if (!isAllocator(allocator) or isArena(allocator)) return null;
    return .{ .node = node, .allocator = allocator, .release = release };
}

/// What a declaration declares, by its type or the value it is given: an allocator — an arena's, where it is the
/// `allocator()` of an `ArenaAllocator` — or an `ArenaAllocator`; null for anything else.
const Kind = enum { allocator, arena, arena_state };

fn kindOf(tree: *const Ast, type_node: Ast.Node.OptionalIndex, init_node: Ast.Node.OptionalIndex) ?Kind {
    const value = if (init_node.unwrap()) |node| tree.getNodeSource(node) else "";
    if (allocatorOfState(value)) |state| if (isArenaStateName(lastName(state))) return .arena;
    if (type_node.unwrap()) |node| {
        var written = std.mem.trimStart(u8, tree.getNodeSource(node), "*");
        if (std.mem.startsWith(u8, written, "const ")) written = written["const ".len..];
        if (isAmong([]const u8, written, &.{ "Allocator", "mem.Allocator", "std.mem.Allocator" })) return .allocator;
        if (isAmong([]const u8, written, &.{ "ArenaAllocator", "heap.ArenaAllocator", "std.heap.ArenaAllocator" })) return .arena_state;
        return null;
    }
    for ([_][]const u8{ "ArenaAllocator.init(", "heap.ArenaAllocator.init(", "std.heap.ArenaAllocator.init(" }) |made| {
        if (std.mem.startsWith(u8, value, made)) return .arena_state;
    }
    if (isNamePath(value) and isAllocator(value)) return .allocator;
    return null;
}

/// Whether the expression is names joined by `.` alone, as `std.testing.allocator`.
fn isNamePath(expression: []const u8) bool {
    if (expression.len == 0) return false;
    for (expression) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '.') return false;
    return true;
}

/// The state an expression is the `allocator()` of; null for an expression that is no such call.
fn allocatorOfState(expression: []const u8) ?[]const u8 {
    const suffix = ".allocator()";
    if (!std.mem.endsWith(u8, expression, suffix)) return null;
    return expression[0 .. expression.len - suffix.len];
}

/// Whether the expression is an allocator: by its name, as Zig names one, or as the `allocator()` of something.
fn isAllocator(expression: []const u8) bool {
    return allocatorOfState(expression) != null or isAllocatorName(lastName(expression));
}

/// Whether the expression is an arena's allocator, whose allocations go with the arena: by its name, or by the name of
/// the `ArenaAllocator` it is the `allocator()` of.
fn isArena(expression: []const u8) bool {
    if (allocatorOfState(expression)) |state| return isArenaStateName(lastName(state));
    return isArenaName(lastName(expression));
}

fn isAllocatorName(name: []const u8) bool {
    return std.mem.eql(u8, name, "gpa") or std.mem.eql(u8, name, "allocator") or std.mem.endsWith(u8, name, "_allocator") or isArenaName(name);
}

fn isArenaName(name: []const u8) bool {
    return std.mem.eql(u8, name, "arena") or std.mem.endsWith(u8, name, "_arena");
}

fn isArenaStateName(name: []const u8) bool {
    return std.mem.eql(u8, name, "arena_allocator") or isArenaName(name);
}

/// The last name of an expression, after its last `.`.
fn lastName(expression: []const u8) []const u8 {
    return expression[if (std.mem.lastIndexOfScalar(u8, expression, '.')) |dot| dot + 1 else 0..];
}

fn isAmong(comptime T: type, item: T, items: []const T) bool {
    for (items) |each| {
        if (if (T == []const u8) std.mem.eql(u8, each, item) else each == item) return true;
    }
    return false;
}

/// Whether `node` says `name`, as an identifier anywhere in it.
fn mentions(tree: *const Ast, node: Ast.Node.Index, name: []const u8) bool {
    var token = tree.firstToken(node);
    while (token <= tree.lastToken(node)) : (token += 1) {
        if (tree.tokenTag(token) == .identifier and std.mem.eql(u8, tree.tokenSlice(token), name)) return true;
    }
    return false;
}

fn nodeAt(at: usize) Ast.Node.Index {
    return @fromBackingInt(@as(u32, @intCast(at)));
}

/// Lints `source`, expecting findings of the rules `expected` on the lines `lines`, in order.
fn expectFindings(source: [:0]const u8, expected: []const struct { Rule, usize }) !void {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var tree = try Ast.parse(arena, source, .{});
    const findings = try lint(arena, &tree);
    const found = try arena.alloc(struct { Rule, usize }, findings.len);
    for (findings, found) |finding, *each| each.* = .{ finding.rule, tree.tokenLocation(0, finding.first).line + 1 };
    try std.testing.expectEqualSlices(struct { Rule, usize }, expected, found);
}

test "an allocation among the arguments of a call that may fail is told, a try's or a catch's, and an arena's is not" {
    try expectFindings(
        \\fn f(gpa: Allocator, arena: Allocator, map: anytype) !void {
        \\    try map.put(gpa, try gpa.dupe(u8, "k"), {});
        \\    map.put(gpa, try gpa.dupe(u8, "k"), {}) catch {};
        \\    try map.put(arena, try arena.dupe(u8, "k"), {});
        \\    var arena_allocator: std.heap.ArenaAllocator = .init(gpa);
        \\    try map.put(gpa, try arena_allocator.allocator().dupe(u8, "k"), {});
        \\    try map.put(gpa, .{ .name = try gpa.dupe(u8, "k") }, {});
        \\}
    , &.{ .{ .@"allocation-in-fallible-arguments", 2 }, .{ .@"allocation-in-fallible-arguments", 3 }, .{ .@"allocation-in-fallible-arguments", 7 } });
}

test "an allocation is kept as Zig keeps one: bound with its release beside it, returned, held, or put in room made for it" {
    try expectFindings(
        \\fn f(gpa: Allocator, list: anytype, self: anytype) ![]u8 {
        \\    const kept = try gpa.dupe(u8, "x");
        \\    errdefer gpa.free(kept);
        \\    const freed = try gpa.dupe(u8, "y");
        \\    defer gpa.free(freed);
        \\    try list.ensureUnusedCapacity(gpa, 1);
        \\    list.appendAssumeCapacity(try gpa.dupe(u8, "z"));
        \\    self.sendOwned(try gpa.dupe(u8, "s"));
        \\    self.name = try gpa.dupe(u8, "w");
        \\    if (self.more) self.other = try gpa.dupe(u8, "o");
        \\    self.* = .{ .name = try gpa.dupe(u8, "n"), .count = 1 };
        \\    const node = try gpa.create(u8);
        \\    errdefer gpa.destroy(node);
        \\    const chosen = if (self.more) try gpa.dupe(u8, "a") else try gpa.dupe(u8, "b");
        \\    defer gpa.free(chosen);
        \\    const given = gpa.dupe(u8, "g") catch return error.OutOfMemory;
        \\    errdefer gpa.free(given);
        \\    return try gpa.dupe(u8, "r");
        \\}
    , &.{});
}

test "an allocation a failure may lose, or that nothing frees, is told" {
    try expectFindings(
        \\fn f(gpa: Allocator, list: anytype, self: anytype) !void {
        \\    const unguarded = try gpa.dupe(u8, "u");
        \\    try list.append(gpa, unguarded);
        \\    const pair = .{ .a = try gpa.dupe(u8, "a"), .b = try gpa.dupe(u8, "b") };
        \\    defer gpa.free(pair.a);
        \\    _ = try gpa.dupe(u8, "lost");
        \\    const length = (try gpa.dupe(u8, "l")).len;
        \\    self.name = std.mem.trim(u8, try gpa.dupe(u8, "t"), " ");
        \\    return .{ .a = try gpa.dupe(u8, "a"), .b = try gpa.dupe(u8, "b") };
        \\}
    , &.{
        .{ .@"allocation-unguarded", 2 }, .{ .@"allocation-unguarded", 4 }, .{ .@"allocation-unguarded", 6 },
        .{ .@"allocation-unguarded", 7 }, .{ .@"allocation-unguarded", 8 }, .{ .@"allocation-unguarded", 9 },
    });
}

test "an allocator is named as Zig names one, an arena's apart from any other's" {
    try expectFindings(
        \\const Holder = struct {
        \\    allocator: Allocator,
        \\    ranges: std.heap.ArenaAllocator,
        \\    fn f(a: Allocator, gpa: Allocator, arena: Allocator, backing_allocator: Allocator, text_arena: Allocator) void {
        \\        var arena_allocator: std.heap.ArenaAllocator = .init(gpa);
        \\        const scratch = arena_allocator.allocator();
        \\        const s = std.testing.allocator;
        \\        var arena_state = std.heap.ArenaAllocator.init(gpa);
        \\        const lines_arena = arena_state.allocator();
        \\        _ = .{ a, arena, backing_allocator, text_arena, scratch, s, lines_arena };
        \\    }
        \\};
    , &.{
        .{ .@"allocator-name", 3 }, .{ .@"allocator-name", 4 }, .{ .@"allocator-name", 6 },
        .{ .@"allocator-name", 7 }, .{ .@"allocator-name", 8 },
    });
}

test "a finding is told as the compiler tells an error, with a note on how to set it right" {
    const source =
        \\fn f(gpa: Allocator, list: anytype) !void {
        \\    try list.append(gpa, try gpa.dupe(u8, "k"));
        \\}
    ;
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var tree = try Ast.parse(arena, source, .{});
    const findings = try lint(arena, &tree);
    try std.testing.expectEqual(1, findings.len);
    try std.testing.expectEqualStrings(
        \\src/a.zig:2:26: error: 'gpa.dupe(u8, "k")' is allocated among the arguments of 'list.append', which may fail: as it fails, nothing frees what was allocated [allocation-in-fallible-arguments]
        \\    try list.append(gpa, try gpa.dupe(u8, "k"));
        \\                         ^~~~~~~~~~~~~~~~~~~~~
        \\src/a.zig:2:26: note: make room first, so that putting it in cannot fail, and put it in with the call that assumes the room:
        \\    try list.ensureUnusedCapacity(gpa, 1);
        \\    list.appendAssumeCapacity(try gpa.dupe(u8, "k"));
        \\
    , try render(arena, &tree, .{ .root = "src", .path = "a.zig" }, findings[0]));
}
