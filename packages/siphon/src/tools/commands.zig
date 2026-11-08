//! A command line as a call that runs it says what it does: each simple command in it, as the shell's language reads it
//! — the variables it sets, its program, its words and its redirections — and the pattern an always grants of each: its
//! program and the words that name what it does, as many as its arity says, then ` *` — `git push *` of `git push
//! origin main`. A grant covers a command by its words alone; so a line no reading knows whole — a syntax error, a
//! substitution, a function defined, a program an expansion names — or one that writes a file by a redirection says
//! nothing a grant could cover, and is asked of the person each time. A line each of whose commands is a program known
//! to read alone — as `ls`, `cat`, `rg`, `git status` — with no variable set and no file written, reads alone.
const std = @import("std");
const Allocator = std.mem.Allocator;
const shell = @import("../shell.zig");

/// What a command line runs: each simple command, as it reads, and the pattern an always grants of each — none of
/// either where no reading knows the line whole — and whether each reads alone.
pub const Commands = struct { resources: []const []const u8 = &.{}, save: []const []const u8 = &.{}, reads_alone: bool = false };

/// What `line` runs.
pub fn read(arena: Allocator, line: []const u8) !Commands {
    const commands = switch (try shell.parse(arena, line)) {
        .commands => |read_| read_,
        .unknowable => return .{},
    };
    if (commands.len == 0) return .{};
    const resources = try arena.alloc([]const u8, commands.len);
    const save = try arena.alloc([]const u8, commands.len);
    var reads = true;
    for (commands, resources, save) |command, *resource, *pattern| {
        if (command.program.len == 0) return .{};
        for (command.redirections) |redirection| if (writesFile(redirection)) return .{};
        var words: std.ArrayList([]const u8) = .empty;
        try words.append(arena, command.program);
        // The words a prefix may take: the program, then the literal words straight after it.
        var literal: usize = 1;
        for (command.arguments) |word| {
            if (word.literal and literal == words.items.len) literal += 1;
            try words.append(arena, word.text);
        }
        resource.* = try textOf(arena, command, words.items);
        pattern.* = try std.mem.concat(arena, u8, &.{ try std.mem.join(arena, " ", prefixOf(words.items[0..literal])), " *" });
        if (command.assignments.len > 0 or !readsAlone(words.items)) reads = false;
    }
    return .{ .resources = resources, .save = save, .reads_alone = reads };
}

/// The programs known to read alone, whatever their words: what they write is their output.
const readers = [_][]const u8{
    "ls",       "cat",      "head",   "tail",   "wc",    "pwd",  "echo",   "printf", "grep",     "egrep",
    "fgrep",    "which",    "whoami", "id",     "file",  "stat", "du",     "df",     "basename", "dirname",
    "realpath", "readlink", "uname",  "true",   "false", "test", "[",      "diff",   "cmp",      "comm",
    "nl",       "cut",      "tr",     "column", "jq",    "md5",  "md5sum", "shasum", "sha1sum",  "sha256sum",
};

/// What git does that reads alone.
const git_readers = [_][]const u8{ "status", "diff", "log", "show", "rev-parse", "ls-files", "blame", "describe", "grep" };

/// The words that make a git that reads write or run: what writes its output to a file, or opens what it found in a
/// pager.
const git_actors = [_][]const u8{ "--output", "-O", "--open-files-in-pager" };

/// The words that make `find` act or write: what it runs, deletes or prints to a file.
const find_actors = [_][]const u8{ "-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls" };

/// Whether the simple command of `words`, its program first, reads alone: a reader's; ripgrep's but with a
/// preprocessor, which runs one; find's that acts on nothing; or git's that reads, writing nothing and running nothing.
fn readsAlone(words: []const []const u8) bool {
    const program = words[0];
    for (readers) |each| if (std.mem.eql(u8, program, each)) return true;
    if (std.mem.eql(u8, program, "rg")) {
        for (words[1..]) |word| if (std.mem.startsWith(u8, word, "--pre")) return false;
        return true;
    }
    if (std.mem.eql(u8, program, "find")) {
        for (words[1..]) |word| for (find_actors) |actor| if (std.mem.eql(u8, word, actor)) return false;
        return true;
    }
    if (std.mem.eql(u8, program, "git") and words.len > 1) {
        for (words[2..]) |word| for (git_actors) |actor| if (std.mem.startsWith(u8, word, actor)) return false;
        for (git_readers) |each| if (std.mem.eql(u8, words[1], each)) return true;
    }
    return false;
}

/// A simple command as a grant is matched against it: the variables it sets, then its words, then its redirections —
/// so a grant of its program covers it only where it sets none.
fn textOf(arena: Allocator, command: shell.Command, words: []const []const u8) ![]const u8 {
    var text: std.Io.Writer.Allocating = .init(arena);
    for (command.assignments) |assignment| try text.writer.print("{s}={s} ", .{ assignment.name, assignment.value.text });
    try text.writer.writeAll(try std.mem.join(arena, " ", words));
    for (command.redirections) |redirection| try text.writer.print(" {s}{s} {s}", .{ redirection.descriptor, redirection.operator, redirection.target.text });
    return text.written();
}

/// Whether a redirection writes a file: one that sends output, but to `/dev/null` or to another descriptor.
fn writesFile(redirection: shell.Redirection) bool {
    const sends = for ([_][]const u8{ ">", ">>", ">|", "&>", "&>>", "<>", ">&" }) |each| {
        if (std.mem.eql(u8, redirection.operator, each)) break true;
    } else false;
    if (!sends) return false;
    const target = redirection.target.text;
    if (!redirection.target.literal) return true;
    if (std.mem.eql(u8, redirection.operator, ">&") and isDescriptor(target)) return false;
    return !std.mem.eql(u8, target, "/dev/null");
}

/// Whether `target` names a descriptor, as `1` of `2>&1`, or closes one, as `-`.
fn isDescriptor(target: []const u8) bool {
    if (std.mem.eql(u8, target, "-")) return true;
    for (target) |byte| if (!std.ascii.isDigit(byte)) return false;
    return target.len > 0;
}

/// The words of a command that name what it does: as many as its program's arity, by the longest of its known
/// beginnings; its program alone where none is known.
fn prefixOf(words: []const []const u8) []const []const u8 {
    var length = @min(words.len, arity_words_max);
    while (length > 0) : (length -= 1) {
        for (arities) |known| {
            if (known.words.len != length) continue;
            const same = for (known.words, words[0..length]) |a, b| {
                if (!std.mem.eql(u8, a, b)) break false;
            } else true;
            if (same) return words[0..@min(known.arity, words.len)];
        }
    }
    return words[0..@min(1, words.len)];
}

/// How many words name what a command does, by the words it begins with: `git push` of `git push origin main`.
const Arity = struct { words: []const []const u8, arity: usize };

const arity_words_max = 2;

const arities = [_]Arity{
    .{ .words = &.{"git"}, .arity = 2 },             .{ .words = &.{ "git", "config" }, .arity = 3 },
    .{ .words = &.{ "git", "remote" }, .arity = 3 }, .{ .words = &.{ "git", "stash" }, .arity = 3 },
    .{ .words = &.{"npm"}, .arity = 2 },             .{ .words = &.{ "npm", "run" }, .arity = 3 },
    .{ .words = &.{ "npm", "exec" }, .arity = 3 },   .{ .words = &.{"npx"}, .arity = 2 },
    .{ .words = &.{"pnpm"}, .arity = 2 },            .{ .words = &.{ "pnpm", "run" }, .arity = 3 },
    .{ .words = &.{ "pnpm", "dlx" }, .arity = 3 },   .{ .words = &.{"yarn"}, .arity = 2 },
    .{ .words = &.{ "yarn", "run" }, .arity = 3 },   .{ .words = &.{"bun"}, .arity = 2 },
    .{ .words = &.{ "bun", "run" }, .arity = 3 },    .{ .words = &.{ "bun", "x" }, .arity = 3 },
    .{ .words = &.{"bunx"}, .arity = 2 },            .{ .words = &.{"deno"}, .arity = 2 },
    .{ .words = &.{ "deno", "task" }, .arity = 3 },  .{ .words = &.{"cargo"}, .arity = 2 },
    .{ .words = &.{ "cargo", "run" }, .arity = 3 },  .{ .words = &.{"go"}, .arity = 2 },
    .{ .words = &.{"zig"}, .arity = 2 },             .{ .words = &.{"make"}, .arity = 2 },
    .{ .words = &.{"python"}, .arity = 2 },          .{ .words = &.{"python3"}, .arity = 2 },
    .{ .words = &.{"pip"}, .arity = 2 },             .{ .words = &.{"uv"}, .arity = 2 },
    .{ .words = &.{ "uv", "run" }, .arity = 3 },     .{ .words = &.{"poetry"}, .arity = 2 },
    .{ .words = &.{"docker"}, .arity = 2 },          .{ .words = &.{ "docker", "compose" }, .arity = 3 },
    .{ .words = &.{"kubectl"}, .arity = 2 },         .{ .words = &.{"helm"}, .arity = 2 },
    .{ .words = &.{"terraform"}, .arity = 2 },       .{ .words = &.{"gh"}, .arity = 3 },
    .{ .words = &.{"brew"}, .arity = 2 },            .{ .words = &.{"swift"}, .arity = 2 },
    .{ .words = &.{"gradle"}, .arity = 2 },          .{ .words = &.{"mvn"}, .arity = 2 },
    .{ .words = &.{"systemctl"}, .arity = 2 },       .{ .words = &.{"tmux"}, .arity = 2 },
};

test "a line runs each of its simple commands, each granted always by the words that name what it does" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const both = try read(arena, "npm install left-pad && git push origin main 2>&1 | tail -5");
    try std.testing.expectEqual(@as(usize, 3), both.resources.len);
    try std.testing.expectEqualStrings("npm install left-pad", both.resources[0]);
    try std.testing.expectEqualStrings("npm install *", both.save[0]);
    try std.testing.expectEqualStrings("git push origin main 2>& 1", both.resources[1]);
    try std.testing.expectEqualStrings("git push *", both.save[1]);
    try std.testing.expectEqualStrings("tail *", both.save[2]);
    // A program of no known arity is named by itself; one of a longer known beginning by as many words as it says.
    try std.testing.expectEqualStrings("ls *", (try read(arena, "ls -la src > /dev/null")).save[0]);
    try std.testing.expectEqualStrings("npm run build *", (try read(arena, "npm run build --watch")).save[0]);
    try std.testing.expectEqualStrings("gh pr view *", (try read(arena, "gh pr view 12")).save[0]);
    // The variables a command sets come before its words, so a grant of its program alone does not cover it.
    try std.testing.expectEqualStrings("NODE_OPTIONS=--inspect npm test", (try read(arena, "NODE_OPTIONS=--inspect npm test")).resources[0]);
}

test "a line no reading knows whole, or one that writes a file by a redirection, says nothing a grant could cover" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = [_][]const u8{
        "npm install $(cat list)",              "f() { rm -rf /; }; f",         "$tool --help",           "if then fi (",
        "echo x > ~/.bashrc",                   "make && git log >> notes.txt", "(echo x) > /etc/passwd", "{ echo x; } > out",
        "echo x &> log",                        "echo x >| forced",             "cat < in.txt > $OUT",    "cmd >& file.txt",
        "cat <<EOF > /etc/passwd\nline\nEOF\n",
    };
    for (lines) |line| {
        const found = try read(arena, line);
        try std.testing.expectEqual(@as(usize, 0), found.resources.len);
        try std.testing.expectEqual(@as(usize, 0), found.save.len);
    }
}

test "a line reads alone where each of its commands is a known reader with no variable set and no file written" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reading = [_][]const u8{ "ls -la src", "cat README.md | head -20", "rg -n TODO src", "git status --short && git diff HEAD~1", "find . -name '*.zig' -type f", "wc -l build.zig 2>/dev/null" };
    for (reading) |line| try std.testing.expect((try read(arena, line)).reads_alone);
    const acting = [_][]const u8{
        "npm test",               "git push origin main", "find . -name '*.o' -delete",  "rg --pre ./decode TODO",
        "GIT_PAGER=less git log", "cat a > b",            "git -C other status",         "ls $(pwd)",
        "find . -exec rm {} \\;", "ls && rm -rf build",   "git diff --output=patch.txt", "git grep -Ovim TODO",
    };
    for (acting) |line| try std.testing.expect(!(try read(arena, line)).reads_alone);
}
