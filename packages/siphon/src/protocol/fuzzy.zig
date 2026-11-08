//! How well a path matches what a person types to find it, as a fuzzy finder scores it: the characters typed, in order,
//! case aside, anywhere in the path — best where they run together, begin a name or a word, and lie in the last name.
//! A match is the shortest stretch of the path holding them, found as fzf's first algorithm finds it: forward to where
//! they are first all met, then back to the latest start. A query without `/` is looked for in the last name first, the
//! whole path where that holds it not.
const std = @import("std");

/// What a character matched scores, and what more where it follows the one matched before, or begins a name or a word.
const char_score = 16;
const run_bonus = 16;
const word_bonus = 8;
/// What a character passed over within the match costs.
const gap_cost = 1;
/// What more a match within the last name scores.
const name_bonus = 32;

/// How well `path` matches `query`, higher better; null where the path holds not the query's characters in order. An
/// empty query matches every path alike.
pub fn score(path: []const u8, query: []const u8) ?i32 {
    if (query.len == 0) return 0;
    const name_start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| slash + 1 else 0;
    if (std.mem.indexOfScalar(u8, query, '/') == null) {
        if (scoreFrom(path, name_start, query)) |in_name| return in_name + name_bonus;
    }
    return scoreFrom(path, 0, query);
}

/// The score of the shortest stretch of `path`, from `from` on, that holds `query`'s characters in order; null where
/// none does.
fn scoreFrom(path: []const u8, from: usize, query: []const u8) ?i32 {
    var at = from;
    for (query) |char| {
        while (at < path.len and !same(path[at], char)) at += 1;
        if (at == path.len) return null;
        at += 1;
    }
    const end = at;
    var start = end;
    var left = query.len;
    while (left > 0) {
        start -= 1;
        if (same(path[start], query[left - 1])) left -= 1;
    }
    var total: i32 = 0;
    var matched: usize = 0;
    var previous: ?usize = null;
    for (start..end) |index| {
        if (matched == query.len or !same(path[index], query[matched])) {
            total -= gap_cost;
            continue;
        }
        total += char_score;
        if (previous) |before| {
            if (before + 1 == index) total += run_bonus;
        }
        if (beginsWord(path, index)) total += word_bonus;
        previous = index;
        matched += 1;
    }
    return total;
}

/// Whether two characters are the same, case aside.
fn same(a: u8, b: u8) bool {
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

/// Whether the character at `index` begins a name or a word: the path's first, one after a separator, or a capital
/// after a small letter.
fn beginsWord(path: []const u8, index: usize) bool {
    if (index == 0) return true;
    const before = path[index - 1];
    return switch (before) {
        '/', '_', '-', '.', ' ' => true,
        else => std.ascii.isLower(before) and std.ascii.isUpper(path[index]),
    };
}

test "a path holding the query's characters in order matches, best where they run together in its last name" {
    try std.testing.expectEqual(null, score("src/main.zig", "mz x"));
    try std.testing.expectEqual(null, score("src/main.zig", "zm"));
    try std.testing.expectEqual(@as(?i32, 0), score("anything", ""));
    // Case aside.
    try std.testing.expect(score("src/README.md", "readme") != null);
    // In the last name before within a folder's name; at a name's start before within it.
    try std.testing.expect(score("src/main.zig", "main").? > score("src/domain/x.zig", "main").?);
    try std.testing.expect(score("lib/maintain.zig", "main").? > score("lib/remain.zig", "main").?);
    // Together before apart.
    try std.testing.expect(score("app/button.tsx", "butt").? > score("app/b-u-t-t.tsx", "butt").?);
    // Where words begin: a camel-cased name's capitals.
    try std.testing.expect(score("src/FileBrowserPanel.tsx", "fbp").? > score("src/fabulous-patterns.tsx", "fbp").?);
    // A query with `/` is looked for along the whole path.
    try std.testing.expect(score("apps/web/src/main.tsx", "web/main") != null);
    try std.testing.expectEqual(null, score("apps/web/src/main.tsx", "main/web"));
}
