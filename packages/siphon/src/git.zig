//! The repositories on the machine, as git tells of them: the program asked each question, run to its end as an editor
//! runs it, its files never read behind its back — which repository a folder is in, its branch, how it stands against
//! its upstream and the branch its work was taken from; what changed between two of its trees, file by file, with the
//! lines each gained and lost, untracked files counted with the working tree; a file's patch; a file's two versions;
//! the commits of a branch. Git runs taking no optional lock, so it never holds the index the person's own git wants,
//! asking for nothing, in C's locale. A revision the asker names is taken as an object's id or a ref's name alone, never
//! as an option.
const Git = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const Machine = @import("machine.zig");
const Waits = @import("runtime.zig").Waits;

const log = std.log.scoped(.siphon);

machine: Machine,
io: std.Io,
/// What git's runs sleep on, which a stop wakes.
waits: *Waits,
/// Memory for what git tells, which lasts the asking.
arena: Allocator,

/// The variables git runs with.
const variables = [_]Machine.Variable{
    .{ .name = "GIT_OPTIONAL_LOCKS", .value = "0" },
    .{ .name = "GIT_TERMINAL_PROMPT", .value = "0" },
    .{ .name = "LC_ALL", .value = "C" },
};

/// How much of what git writes is taken at most, past which what was asked is too large to tell.
const output_max = 32 << 20;
/// How large a file of the working tree is read at most, to count its lines or to show it.
const file_bytes_max = 8 << 20;
/// How many untracked files have their lines counted, the rest told without.
const untracked_counted_max = 1000;
/// How many commits of a branch are told at most.
const commits_max = 200;
/// The bytes git looks at for a NUL to call a file binary, as it does.
const binary_probe_bytes = 8000;

/// git run with `args` in the folder `cwd`, to its end.
fn run(git: Git, cwd: []const u8, args: []const []const u8) !Machine.Ran {
    const argv = try git.arena.alloc([]const u8, args.len + 1);
    argv[0] = "git";
    @memcpy(argv[1..], args);
    return git.machine.run(git.io, git.arena, git.waits, .{ .argv = argv, .cwd = cwd, .variables = &variables, .output_max = output_max });
}

/// What git wrote, run with `args` in `cwd`, where it exited 0; `GitFailed` where it did not, what it said logged.
fn output(git: Git, cwd: []const u8, args: []const []const u8) ![]const u8 {
    const ran = try git.run(cwd, args);
    if (!succeeded(ran)) return failed(args, ran);
    return ran.output;
}

fn succeeded(ran: Machine.Ran) bool {
    return ran.ended == .code and ran.ended.code == 0;
}

fn failed(args: []const []const u8, ran: Machine.Ran) error{GitFailed} {
    log.warn("git {s} failed: {s}", .{ args[0], std.mem.trimEnd(u8, ran.errors, "\n") });
    return error.GitFailed;
}

/// A repository, as a folder in it is: the folder its work tree begins at; its branch, none where its head is detached;
/// its head's commit, none before the first; its upstream, how many commits it is ahead of it and behind; and the
/// branch its work was taken from, as its changes are told against unless one is asked for.
pub const Repository = struct {
    root: []const u8,
    branch: ?[]const u8 = null,
    head: ?[]const u8 = null,
    upstream: ?[]const u8 = null,
    ahead: u64 = 0,
    behind: u64 = 0,
    base: ?[]const u8 = null,
};

/// The repository the folder `folder` is in; none where it is in none.
pub fn repositoryOf(git: Git, folder: []const u8) !?Repository {
    const root = try git.rootOf(folder) orelse return null;
    var repository: Repository = .{ .root = root };
    const status = try git.output(root, &.{ "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=no" });
    var fields = std.mem.tokenizeScalar(u8, status, 0);
    while (fields.next()) |field| {
        const header = std.mem.cutPrefix(u8, field, "# branch.") orelse continue;
        const space = std.mem.indexOfScalar(u8, header, ' ') orelse continue;
        const name = header[0..space];
        const value = header[space + 1 ..];
        if (std.mem.eql(u8, name, "oid")) {
            if (!std.mem.eql(u8, value, "(initial)")) repository.head = value;
        } else if (std.mem.eql(u8, name, "head")) {
            if (!std.mem.eql(u8, value, "(detached)")) repository.branch = value;
        } else if (std.mem.eql(u8, name, "upstream")) {
            repository.upstream = value;
        } else if (std.mem.eql(u8, name, "ab")) {
            var counts = std.mem.tokenizeScalar(u8, value, ' ');
            repository.ahead = countOf(counts.next());
            repository.behind = countOf(counts.next());
        }
    }
    repository.base = try git.baseOf(root, repository.upstream);
    return repository;
}

/// A count git writes after its sign, `+3` or `-0`; none read as 0.
fn countOf(written: ?[]const u8) u64 {
    const count = written orelse return 0;
    if (count.len < 2) return 0;
    return std.fmt.parseInt(u64, count[1..], 10) catch 0;
}

/// The folder the work tree of the repository `folder` is in begins at; none where it is in none.
fn rootOf(git: Git, folder: []const u8) !?[]const u8 {
    const top = try git.run(folder, &.{ "rev-parse", "--show-toplevel" });
    if (!succeeded(top)) return null;
    return std.mem.trimEnd(u8, top.output, "\n");
}

/// The branch a repository's work was taken from: the default branch of its upstream's remote, else origin's, else the
/// first there is of origin/main, origin/master, main and master; none where there is none.
fn baseOf(git: Git, root: []const u8, upstream: ?[]const u8) !?[]const u8 {
    const remote = if (upstream) |name| name[0 .. std.mem.indexOfScalar(u8, name, '/') orelse name.len] else "origin";
    const remote_head = try std.mem.concat(git.arena, u8, &.{ "refs/remotes/", remote, "/HEAD" });
    const candidates = [_][]const u8{ remote_head, "refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/remotes/origin/master", "refs/heads/main", "refs/heads/master" };
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(git.arena, &.{ "for-each-ref", "--format=%(refname)%00%(symref)" });
    try args.appendSlice(git.arena, &candidates);
    const listed = try git.output(root, args.items);
    for (candidates) |candidate| {
        var lines = std.mem.tokenizeScalar(u8, listed, '\n');
        while (lines.next()) |line| {
            const nul = std.mem.indexOfScalar(u8, line, 0) orelse continue;
            if (!std.mem.eql(u8, line[0..nul], candidate)) continue;
            const symref = line[nul + 1 ..];
            return shortName(if (symref.len > 0) symref else candidate);
        }
    }
    return null;
}

/// A ref's name as a person writes it: `origin/main` for refs/remotes/origin/main, `main` for refs/heads/main.
fn shortName(ref: []const u8) []const u8 {
    return std.mem.cutPrefix(u8, ref, "refs/remotes/") orelse std.mem.cutPrefix(u8, ref, "refs/heads/") orelse ref;
}

/// Which changes are asked for: those not yet committed, against the head; a branch's, against where it parted from
/// `base` — its automatic one where none is given — the working tree's own included; or one commit's, against its
/// parent.
pub const Scope = union(enum) {
    uncommitted: struct { type: enum { uncommitted } },
    branch: struct { type: enum { branch }, base: ?[]const u8 = null },
    commit: struct { type: enum { commit }, commit: []const u8 },

    const variants = foundation.json.Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// Two trees of a repository's, as changes are told between: an older, a commit's or the empty tree's, by its object's
/// id; and a newer, a commit's by its id, or the working tree's where none.
pub const Comparison = struct { old: []const u8, new: ?[]const u8 = null };

/// What became of a file between two trees, as git tells it; untracked, one in the working tree git does not keep.
pub const Status = enum { added, deleted, modified, renamed, copied, @"type-changed", untracked };

/// A file changed: its path from the repository's root, and the one it had where it was renamed or copied; what became
/// of it; the lines it gained and lost, none where they were not counted; and whether it is binary.
pub const Changed = struct {
    path: []const u8,
    old_path: ?[]const u8 = null,
    status: Status,
    additions: ?u64 = null,
    deletions: ?u64 = null,
    binary: bool = false,
};

/// The changes asked for: the repository's root, the two trees they are between, the branch they are told against,
/// where they are a branch's, and the files changed, by their paths.
pub const Changes = struct {
    root: []const u8,
    comparison: Comparison,
    base: ?[]const u8 = null,
    files: []const Changed,
};

/// The changes `scope` asks for, of the repository the folder `folder` is in.
pub fn changesOf(git: Git, folder: []const u8, scope: Scope) !Changes {
    const root = try git.rootOf(folder) orelse return error.NotARepository;
    var base: ?[]const u8 = null;
    const comparison: Comparison = switch (scope) {
        .uncommitted => .{ .old = try git.headOrEmpty(root) },
        .branch => |branch| compared: {
            base = branch.base orelse (try git.repositoryOf(root)).?.base orelse return error.NoBase;
            try checkRef(base.?);
            break :compared .{ .old = std.mem.trimEnd(u8, try git.output(root, &.{ "merge-base", base.?, "HEAD" }), "\n") };
        },
        .commit => |picked| compared: {
            try checkObjectId(picked.commit);
            const parent = try git.run(root, &.{ "rev-parse", "-q", "--verify", try std.mem.concat(git.arena, u8, &.{ picked.commit, "^" }) });
            const old = if (succeeded(parent)) std.mem.trimEnd(u8, parent.output, "\n") else try git.emptyTree(root);
            break :compared .{ .old = old, .new = picked.commit };
        },
    };
    var files: std.ArrayList(Changed) = .empty;
    try git.addDiffed(root, comparison, &files);
    if (comparison.new == null) try git.addUntracked(root, &files);
    std.mem.sort(Changed, files.items, {}, byPath);
    return .{ .root = root, .comparison = comparison, .base = base, .files = files.items };
}

fn byPath(_: void, a: Changed, b: Changed) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// The head's commit, or the empty tree where the repository has no commit yet.
fn headOrEmpty(git: Git, root: []const u8) ![]const u8 {
    const head = try git.run(root, &.{ "rev-parse", "-q", "--verify", "HEAD^{commit}" });
    return if (succeeded(head)) std.mem.trimEnd(u8, head.output, "\n") else git.emptyTree(root);
}

/// The id of the empty tree, in the repository's own hash.
fn emptyTree(git: Git, root: []const u8) ![]const u8 {
    return std.mem.trimEnd(u8, try git.output(root, &.{ "hash-object", "-t", "tree", "/dev/null" }), "\n");
}

/// Adds the files git tells changed between the comparison's trees, each with the lines it gained and lost: its raw
/// records first, then its counts, in the same order.
fn addDiffed(git: Git, root: []const u8, comparison: Comparison, files: *std.ArrayList(Changed)) !void {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(git.arena, &.{ "diff", "--raw", "--numstat", "-z", "--find-renames", "--no-color", "--no-ext-diff", comparison.old });
    if (comparison.new) |new| try args.append(git.arena, new);
    const told = try git.output(root, args.items);
    var fields = std.mem.splitScalar(u8, told, 0);
    const first = files.items.len;
    while (fields.peek()) |field| {
        if (!std.mem.startsWith(u8, field, ":")) break;
        _ = fields.next();
        const letter = field[std.mem.lastIndexOfScalar(u8, field, ' ').? + 1];
        const status = statusOf(letter);
        const path = fields.next() orelse return error.GitFailed;
        if (status == .renamed or status == .copied) {
            try files.append(git.arena, .{ .path = fields.next() orelse return error.GitFailed, .old_path = path, .status = status });
        } else try files.append(git.arena, .{ .path = path, .status = status });
    }
    for (files.items[first..]) |*file| {
        const counts = fields.next() orelse return error.GitFailed;
        var parts = std.mem.splitScalar(u8, counts, '\t');
        const added = parts.next() orelse "-";
        const deleted = parts.next() orelse "-";
        if (file.old_path != null) {
            _ = fields.next();
            _ = fields.next();
        }
        file.binary = std.mem.eql(u8, added, "-");
        file.additions = std.fmt.parseInt(u64, added, 10) catch null;
        file.deletions = std.fmt.parseInt(u64, deleted, 10) catch null;
    }
}

/// What became of a file, by git's letter for it; one unmerged told as modified.
fn statusOf(letter: u8) Status {
    return switch (letter) {
        'A' => .added,
        'D' => .deleted,
        'R' => .renamed,
        'C' => .copied,
        'T' => .@"type-changed",
        else => .modified,
    };
}

/// Adds the files of the working tree git does not keep and its ignore files leave in, each with its lines counted —
/// so many at most — as all gained.
fn addUntracked(git: Git, root: []const u8, files: *std.ArrayList(Changed)) !void {
    const listed = try git.output(root, &.{ "ls-files", "--others", "--exclude-standard", "-z" });
    var paths = std.mem.tokenizeScalar(u8, listed, 0);
    var counted: usize = 0;
    while (paths.next()) |path| : (counted += 1) {
        var file: Changed = .{ .path = path, .status = .untracked };
        if (counted < untracked_counted_max) if (try git.workingFile(root, path)) |bytes| {
            file.binary = std.mem.indexOfScalar(u8, bytes[0..@min(bytes.len, binary_probe_bytes)], 0) != null;
            if (!file.binary) {
                file.additions = linesIn(bytes);
                file.deletions = 0;
            }
        };
        try files.append(git.arena, file);
    }
}

/// How many lines `bytes` holds, a last one without its newline counted.
fn linesIn(bytes: []const u8) u64 {
    const newlines = std.mem.count(u8, bytes, "\n");
    return newlines + @intFromBool(bytes.len > 0 and bytes[bytes.len - 1] != '\n');
}

/// The bytes of the working tree's file at `path` from `root`, where it is there and no larger than is read.
fn workingFile(git: Git, root: []const u8, path: []const u8) !?[]const u8 {
    const whole = try std.fs.path.join(git.arena, &.{ root, path });
    const bytes = try git.machine.readAll(&git.arena, whole, file_bytes_max + 1) orelse return null;
    return if (bytes.len > file_bytes_max) null else bytes;
}

/// The file a client names of the changes it was told: its path, the one it had, and what became of it.
pub const File = struct { path: []const u8, old_path: ?[]const u8 = null, status: Status };

/// The patch of `file` between the comparison's trees, as git writes it, `context` lines of context about each change;
/// one untracked as all its lines gained.
pub fn patchOf(git: Git, folder: []const u8, comparison: Comparison, file: File, context: u32) ![]const u8 {
    const root = try git.rootOf(folder) orelse return error.NotARepository;
    const unified = try std.fmt.allocPrint(git.arena, "-U{d}", .{context});
    if (file.status == .untracked) {
        const args = [_][]const u8{ "diff", "--no-index", "--no-color", "--no-ext-diff", unified, "--", "/dev/null", file.path };
        const ran = try git.run(root, &args);
        // Comparing files, git exits 1 where they differ.
        if (ran.ended != .code or ran.ended.code > 1) return failed(&args, ran);
        return ran.output;
    }
    try checkComparison(comparison);
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(git.arena, &.{ "diff", "--no-color", "--no-ext-diff", "--find-renames", unified, comparison.old });
    if (comparison.new) |new| try args.append(git.arena, new);
    try args.append(git.arena, "--");
    if (file.old_path) |old_path| try args.append(git.arena, old_path);
    try args.append(git.arena, file.path);
    return git.output(root, args.items);
}

/// A file's two versions, as the comparison's trees hold it: the older, none where it was added; the newer, none where
/// it was deleted.
pub const Versions = struct { old: ?[]const u8 = null, new: ?[]const u8 = null };

/// The two versions of `file` between the comparison's trees.
pub fn versionsOf(git: Git, folder: []const u8, comparison: Comparison, file: File) !Versions {
    const root = try git.rootOf(folder) orelse return error.NotARepository;
    try checkComparison(comparison);
    var versions: Versions = .{};
    if (file.status != .added and file.status != .untracked) {
        versions.old = try git.blobOf(root, comparison.old, file.old_path orelse file.path);
    }
    if (file.status != .deleted) {
        versions.new = if (comparison.new) |new| try git.blobOf(root, new, file.path) else try git.workingFile(root, file.path) orelse return error.TooLarge;
    }
    return versions;
}

/// The bytes the tree of `revision` holds at `path`.
fn blobOf(git: Git, root: []const u8, revision: []const u8, path: []const u8) ![]const u8 {
    return git.output(root, &.{ "cat-file", "blob", try std.mem.concat(git.arena, u8, &.{ revision, ":", path }) });
}

/// A commit of a branch: its id, when it was committed, in s since the epoch, and its subject.
pub const Commit = struct { commit: []const u8, time: i64, subject: []const u8 };

/// The commits of the branch of the repository `folder` is in since it parted from `base` — its automatic one where
/// none is given — newest first, so many at most, and whether there are more.
pub fn commitsOf(git: Git, folder: []const u8, base: ?[]const u8) !struct { commits: []const Commit, truncated: bool } {
    const root = try git.rootOf(folder) orelse return error.NotARepository;
    const from = base orelse (try git.repositoryOf(root)).?.base orelse return error.NoBase;
    try checkRef(from);
    const parted = std.mem.trimEnd(u8, try git.output(root, &.{ "merge-base", from, "HEAD" }), "\n");
    const range = try std.mem.concat(git.arena, u8, &.{ parted, "..HEAD" });
    const limit = try std.fmt.allocPrint(git.arena, "--max-count={d}", .{commits_max + 1});
    const told = try git.output(root, &.{ "log", "-z", "--format=%H%x1f%ct%x1f%s", limit, range });
    var commits: std.ArrayList(Commit) = .empty;
    var records = std.mem.tokenizeScalar(u8, told, 0);
    while (records.next()) |record| {
        var fields = std.mem.splitScalar(u8, record, 0x1f);
        const id = fields.next() orelse continue;
        const time = std.fmt.parseInt(i64, fields.next() orelse "0", 10) catch 0;
        try commits.append(git.arena, .{ .commit = id, .time = time, .subject = fields.rest() });
    }
    const truncated = commits.items.len > commits_max;
    return .{ .commits = commits.items[0..@min(commits.items.len, commits_max)], .truncated = truncated };
}

/// Refuses a comparison whose trees are not named by objects' ids.
fn checkComparison(comparison: Comparison) !void {
    try checkObjectId(comparison.old);
    if (comparison.new) |new| try checkObjectId(new);
}

/// Refuses what is not an object's id, written whole in hex — SHA-1's, or SHA-256's.
fn checkObjectId(id: []const u8) !void {
    if (id.len != 40 and id.len != 64) return error.InvalidRevision;
    for (id) |char| if (!std.ascii.isHex(char)) return error.InvalidRevision;
}

/// Refuses what is no ref's name a person writes — one that would read as an option among them.
fn checkRef(name: []const u8) !void {
    if (name.len == 0 or name[0] == '-') return error.InvalidRevision;
    for (name) |char| if (char <= ' ' or char == 0x7f or std.mem.indexOfScalar(u8, "~^:?*[\\", char) != null) return error.InvalidRevision;
}
