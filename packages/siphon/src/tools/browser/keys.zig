//! The keys an agent presses on a page, by the names the DOM gives them — `Enter`, `ArrowDown`, `a` — with the
//! modifiers it holds: each as the browser is told a key pressed, the key it is on, its key code and the text it types,
//! and the editing a shortcut of Control or Meta stands for, which a headless browser binds none of.
const std = @import("std");
const Browser = @import("../../browser.zig");

/// A modifier held, as the browser counts them.
pub const Modifier = enum {
    Alt,
    Control,
    Meta,
    Shift,

    fn bit(modifier: Modifier) u32 {
        return switch (modifier) {
            .Alt => 1,
            .Control => 2,
            .Meta => 4,
            .Shift => 8,
        };
    }
};

/// A key of a name of its own: the key it is on, its key code, and the text it types.
const Named = struct { name: []const u8, code: []const u8, key_code: u32, text: ?[]const u8 = null };

const named = [_]Named{
    .{ .name = "Enter", .code = "Enter", .key_code = 13, .text = "\r" },
    .{ .name = "Tab", .code = "Tab", .key_code = 9 },
    .{ .name = "Escape", .code = "Escape", .key_code = 27 },
    .{ .name = "Backspace", .code = "Backspace", .key_code = 8 },
    .{ .name = "Delete", .code = "Delete", .key_code = 46 },
    .{ .name = " ", .code = "Space", .key_code = 32, .text = " " },
    .{ .name = "ArrowLeft", .code = "ArrowLeft", .key_code = 37 },
    .{ .name = "ArrowUp", .code = "ArrowUp", .key_code = 38 },
    .{ .name = "ArrowRight", .code = "ArrowRight", .key_code = 39 },
    .{ .name = "ArrowDown", .code = "ArrowDown", .key_code = 40 },
    .{ .name = "Home", .code = "Home", .key_code = 36 },
    .{ .name = "End", .code = "End", .key_code = 35 },
    .{ .name = "PageUp", .code = "PageUp", .key_code = 33 },
    .{ .name = "PageDown", .code = "PageDown", .key_code = 34 },
    .{ .name = "Insert", .code = "Insert", .key_code = 45 },
};

/// Names that mean one key alone, though the DOM names it otherwise.
const aliases = [_]struct { []const u8, []const u8 }{ .{ "Space", " " }, .{ "Esc", "Escape" } };

/// The editing commands of the shortcuts Control or Meta holds, by the key and whether Shift is held.
const editing = [_]struct { key: u8, shift: bool, command: []const u8 }{
    .{ .key = 'a', .shift = false, .command = "selectAll" },
    .{ .key = 'z', .shift = false, .command = "undo" },
    .{ .key = 'z', .shift = true, .command = "redo" },
    .{ .key = 'y', .shift = false, .command = "redo" },
};

/// The key `name` pressed with `modifiers` held, as the browser is told it, its words in `buffer`; error.NoSuchKey
/// where no key has that name.
pub fn pressed(name: []const u8, modifiers: []const Modifier, buffer: *[8]u8) error{NoSuchKey}!Browser.Key {
    var held: u32 = 0;
    for (modifiers) |modifier| held |= modifier.bit();
    const shortcut = held & (Modifier.Control.bit() | Modifier.Meta.bit()) != 0;
    const shifted = held & Modifier.Shift.bit() != 0;
    var key = name;
    for (aliases) |alias| if (std.mem.eql(u8, alias[0], name)) {
        key = alias[1];
    };
    for (named) |each| if (std.mem.eql(u8, each.name, key)) {
        return .{ .type = .down, .key = each.name, .code = each.code, .key_code = each.key_code, .modifiers = held, .text = if (shortcut) null else each.text };
    };
    if (functionKey(key)) |number| return .{ .type = .down, .key = key, .code = key, .key_code = 111 + number, .modifiers = held };
    if (std.unicode.utf8CountCodepoints(key) catch 0 != 1) return error.NoSuchKey;
    const lower = std.ascii.toLower(key[0]);
    const letter = key.len == 1 and std.ascii.isAlphabetic(key[0]);
    const digit = key.len == 1 and std.ascii.isDigit(key[0]);
    const code = if (letter) std.fmt.bufPrint(buffer, "Key{c}", .{std.ascii.toUpper(key[0])}) catch unreachable else if (digit) std.fmt.bufPrint(buffer, "Digit{c}", .{key[0]}) catch unreachable else "";
    var commands: []const []const u8 = &.{};
    if (shortcut and letter) for (&editing) |*each| if (each.key == lower and each.shift == shifted) {
        commands = (&each.command)[0..1];
    };
    return .{
        .type = .down,
        .key = key,
        .code = code,
        .key_code = if (letter) std.ascii.toUpper(key[0]) else if (digit) key[0] else 0,
        .modifiers = held,
        .text = if (shortcut) null else key,
        .commands = commands,
    };
}

/// The number of the function key `name` names, F1 to F12.
fn functionKey(name: []const u8) ?u32 {
    if (name.len < 2 or name[0] != 'F') return null;
    const number = std.fmt.parseInt(u32, name[1..], 10) catch return null;
    return if (number >= 1 and number <= 12) number else null;
}

test "a key is pressed by its name, with what it types and what a shortcut stands for" {
    var buffer: [8]u8 = undefined;
    const enter = try pressed("Enter", &.{}, &buffer);
    try std.testing.expectEqual(@as(u32, 13), enter.key_code);
    try std.testing.expectEqualStrings("\r", enter.text.?);
    const space = try pressed("Space", &.{}, &buffer);
    try std.testing.expectEqualStrings(" ", space.key);
    const shifted = try pressed("A", &.{.Shift}, &buffer);
    try std.testing.expectEqualStrings("KeyA", shifted.code);
    try std.testing.expectEqualStrings("A", shifted.text.?);
    try std.testing.expectEqual(@as(u32, 8), shifted.modifiers);
    const all = try pressed("a", &.{.Meta}, &buffer);
    try std.testing.expectEqual(@as(?[]const u8, null), all.text);
    try std.testing.expectEqualStrings("selectAll", all.commands[0]);
    const redo = try pressed("z", &.{ .Control, .Shift }, &buffer);
    try std.testing.expectEqualStrings("redo", redo.commands[0]);
    try std.testing.expectEqual(@as(u32, 116), (try pressed("F5", &.{}, &buffer)).key_code);
    try std.testing.expectEqualStrings("中", (try pressed("中", &.{}, &buffer)).text.?);
    try std.testing.expectError(error.NoSuchKey, pressed("Enterr", &.{}, &buffer));
}
