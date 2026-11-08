//! Skills: files of instructions, each for one kind of task — a folder of its own holding `SKILL.md`, whose front
//! matter names the skill and says what it is for. The model is told of each by its name, its file and what it is for,
//! and reads the file when a task is of its kind. They are the person's own, for every project, as the host keeps
//! them, and each project folder's, in its `.agents/skills`, from the folder its repository is kept in — the machine's
//! root where there is none — down to the workspace; a skill of a nearer folder stands for one of its name farther
//! away.
const std = @import("std");
const Allocator = std.mem.Allocator;
const beak = @import("../beak.zig");
const h = beak.h;
const Machine = @import("../machine.zig");

const log = std.log.scoped(.siphon);

/// A skill, as the model is told of it.
pub const Skill = struct { name: []const u8, path: []const u8, description: []const u8 };

/// Where a project folder keeps its skills, below it.
const project_skills = ".agents/skills";
/// A skill's file, in its folder.
const skill_file = "SKILL.md";
/// The most of a skill's file read for its front matter.
const skill_bytes_max = 64 << 10;

/// The skills of a thread on `machine` working in the last of the folders `down`, which go from the machine's root
/// down to it: the person's own, kept in `own`, then each project folder's from its repository's root down; each by
/// its name, from the nearest folder that has one of the name, in the order of their names.
pub fn find(arena: Allocator, machine: Machine, own: ?[]const u8, down: []const []const u8) ![]const Skill {
    var found: std.StringArrayHashMapUnmanaged(Skill) = .empty;
    if (own) |folder| try gather(arena, machine, folder, &found);
    for (down[try repositoryAmong(arena, machine, down)..]) |folder| {
        try gather(arena, machine, try std.fs.path.join(arena, &.{ folder, project_skills }), &found);
    }
    const skills = found.values();
    std.mem.sortUnstable(Skill, skills, {}, byName);
    return skills;
}

fn byName(_: void, left: Skill, right: Skill) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

/// Where among the folders `down` the repository the last is in begins; the first where it is in none.
fn repositoryAmong(arena: Allocator, machine: Machine, down: []const []const u8) !usize {
    const root = try machine.repositoryOf(arena, down[down.len - 1]) orelse return 0;
    for (down, 0..) |folder, at| if (std.mem.eql(u8, folder, root)) return at;
    return 0;
}

/// The skills kept in `folder` put in `found` by their names, over any of a name farther away; a folder the machine
/// lets no one read, or a file that says not what its skill is for, left out.
fn gather(arena: Allocator, machine: Machine, folder: []const u8, found: *std.StringArrayHashMapUnmanaged(Skill)) !void {
    const entries = machine.list(&arena, folder) catch |err| switch (err) {
        error.Refused => return,
        else => return err,
    };
    for (entries) |entry| {
        if (entry.type == h.BEAK_ENTRY_FILE) continue;
        const named = beak.slice(entry.name);
        const path = try std.fs.path.join(arena, &.{ folder, named, skill_file });
        const text = machine.readAll(&arena, path, skill_bytes_max) catch |err| switch (err) {
            error.Refused => continue,
            else => return err,
        } orelse continue;
        const matter = try frontMatterOf(arena, text) orelse FrontMatter{};
        const description = matter.description orelse {
            log.warn("the skill {s} is left out: its front matter says not what it is for", .{path});
            continue;
        };
        const name = matter.name orelse named;
        try found.put(arena, name, .{ .name = name, .path = path, .description = description });
    }
}

/// The skills as the model is told of them: each by its name and its file, then what it is for.
pub fn told(arena: Allocator, skills: []const Skill) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (skills, 0..) |skill, index| {
        if (index > 0) try out.writer.writeByte('\n');
        try out.writer.print("<skill name=\"{s}\" path=\"{s}\">\n{s}\n</skill>", .{ skill.name, skill.path, skill.description });
    }
    return out.written();
}

/// What a skill's file says of it: its name and what it is for.
const FrontMatter = struct { name: ?[]const u8 = null, description: ?[]const u8 = null };

/// What a skill's file says of it in the front matter it begins with — the YAML between its `---` lines, of which a
/// skill's name and what it is for are read, each a plain, quoted or block scalar; null where it begins with none.
fn frontMatterOf(arena: Allocator, text: []const u8) !?FrontMatter {
    var lines = std.mem.splitScalar(u8, if (std.mem.startsWith(u8, text, bom)) text[bom.len..] else text, '\n');
    if (!isFence(lines.first())) return null;
    var matter: std.ArrayList([]const u8) = .empty;
    while (lines.next()) |line| {
        if (isFence(line)) return try fieldsOf(arena, matter.items);
        try matter.append(arena, std.mem.trimEnd(u8, line, "\r"));
    }
    return null;
}

const bom = "\xEF\xBB\xBF";

fn isFence(line: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, line, " \t\r"), "---");
}

/// The fields of the front matter's `lines`: each key at the start of a line, its value what follows it there and on
/// the lines after that are indented or blank.
fn fieldsOf(arena: Allocator, lines: []const []const u8) !FrontMatter {
    var matter: FrontMatter = .{};
    var at: usize = 0;
    while (at < lines.len) {
        const line = lines[at];
        at += 1;
        if (line.len == 0 or isIndented(line) or line[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const first = at;
        while (at < lines.len and (isIndented(lines[at]) or isBlank(lines[at]))) at += 1;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = try scalarOf(arena, std.mem.trim(u8, line[colon + 1 ..], " \t"), lines[first..at]);
        if (std.mem.eql(u8, key, "name")) matter.name = value;
        if (std.mem.eql(u8, key, "description")) matter.description = value;
    }
    return matter;
}

fn isIndented(line: []const u8) bool {
    return line.len > 0 and (line[0] == ' ' or line[0] == '\t');
}

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

/// A scalar of YAML, as it begins after its key, `head`, and goes on in the indented lines `more`: a literal or folded
/// block; a quoted scalar, double or single; or a plain one, a comment after it left out — lines of the last two
/// folded into one.
fn scalarOf(arena: Allocator, head: []const u8, more: []const []const u8) ![]const u8 {
    if (head.len > 0 and (head[0] == '|' or head[0] == '>')) return blockOf(arena, head[0] == '|', more);
    const whole = try foldedOf(arena, head, more);
    if (quotedBy(whole, '"')) |inner| return unescaped(arena, inner);
    if (quotedBy(whole, '\'')) |inner| return std.mem.replaceOwned(u8, arena, inner, "''", "'");
    return whole[0 .. std.mem.indexOf(u8, whole, " #") orelse whole.len];
}

/// What `text` holds between the quotes `quote` it is wholly in; null where it is not.
fn quotedBy(text: []const u8, quote: u8) ?[]const u8 {
    if (text.len < 2 or text[0] != quote or text[text.len - 1] != quote) return null;
    return text[1 .. text.len - 1];
}

/// The lines of a scalar folded as YAML folds them: each line's words joined to the next line's by a space, a blank
/// line a line break.
fn foldedOf(arena: Allocator, head: []const u8, more: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, head);
    for (more) |line| {
        const words = std.mem.trim(u8, line, " \t");
        if (words.len == 0) {
            try out.append(arena, '\n');
            continue;
        }
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(arena, ' ');
        try out.appendSlice(arena, words);
    }
    return std.mem.trim(u8, out.items, " \n");
}

/// A block scalar's lines, `more`, less the indentation of its first: as they stand where `literal`, else folded.
fn blockOf(arena: Allocator, literal: bool, more: []const []const u8) ![]const u8 {
    const indentation = for (more) |line| {
        if (!isBlank(line)) break line.len - std.mem.trimStart(u8, line, " \t").len;
    } else 0;
    var out: std.ArrayList(u8) = .empty;
    var after_blank = false;
    for (more, 0..) |line, index| {
        const text = if (isBlank(line)) "" else line[@min(indentation, line.len)..];
        if (index > 0) {
            if (literal or text.len == 0) try out.append(arena, '\n') else if (!after_blank) try out.append(arena, ' ');
        }
        try out.appendSlice(arena, text);
        after_blank = text.len == 0;
    }
    return std.mem.trimEnd(u8, out.items, "\n ");
}

/// The text of a double-quoted scalar, its escapes undone; an escape it knows not kept as it is.
fn unescaped(arena: Allocator, quoted: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < quoted.len) : (at += 1) {
        if (quoted[at] != '\\' or at + 1 == quoted.len) {
            try out.append(arena, quoted[at]);
            continue;
        }
        at += 1;
        const escaped: ?u8 = switch (quoted[at]) {
            'n' => '\n',
            't' => '\t',
            '"', '\\', '/' => quoted[at],
            else => null,
        };
        if (escaped) |byte| try out.append(arena, byte) else try out.appendSlice(arena, quoted[at - 1 .. at + 1]);
    }
    return out.items;
}

fn expectMatter(text: []const u8, name: ?[]const u8, description: ?[]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const matter = (try frontMatterOf(arena_state.allocator(), text)).?;
    if (name) |expected| try std.testing.expectEqualStrings(expected, matter.name.?) else try std.testing.expect(matter.name == null);
    if (description) |expected| try std.testing.expectEqualStrings(expected, matter.description.?) else try std.testing.expect(matter.description == null);
}

test "a skill's front matter gives its name and what it is for, as plain, quoted or block scalars of YAML" {
    try expectMatter("---\nname: pdf\ndescription: Fill PDF forms. # how\n---\n# PDF\n", "pdf", "Fill PDF forms.");
    // A plain scalar goes on in the lines indented after it, folded into one.
    try expectMatter("---\ndescription: Reads tables\n  out of PDF files.\nname: pdf\n---\n", "pdf", "Reads tables out of PDF files.");
    try expectMatter("---\r\nname: \"review\"\r\ndescription: \"Say \\\"why\\\",\\n then how.\"\r\n---\r\n", "review", "Say \"why\",\n then how.");
    try expectMatter("---\nname: 'it''s'\ndescription: 'a # in quotes'\n---\n", "it's", "a # in quotes");
    try expectMatter("---\ndescription: >\n  Folded into\n  one line.\n\n  A second.\n---\n", null, "Folded into one line.\nA second.");
    try expectMatter("---\ndescription: |-\n  Kept\n    as written.\n---\n", null, "Kept\n  as written.");
    // Keys under another are its value, never the skill's.
    try expectMatter(bom ++ "---\nmetadata:\n  name: other\nname: deploy\n---\n", "deploy", null);
}

test "a file that begins with no front matter, or never ends it, has none" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(try frontMatterOf(arena, "# PDF\nname: pdf\n") == null);
    try std.testing.expect(try frontMatterOf(arena, "---\nname: pdf\n") == null);
}

test "skills are told by their names and files, then what each is for" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const listed = [_]Skill{ .{ .name = "a", .path = "/s/a/SKILL.md", .description = "Does a." }, .{ .name = "b", .path = "/s/b/SKILL.md", .description = "Does b." } };
    try std.testing.expectEqualStrings(
        "<skill name=\"a\" path=\"/s/a/SKILL.md\">\nDoes a.\n</skill>\n<skill name=\"b\" path=\"/s/b/SKILL.md\">\nDoes b.\n</skill>",
        try told(arena_state.allocator(), &listed),
    );
}
