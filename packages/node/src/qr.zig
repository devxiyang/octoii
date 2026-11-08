//! A QR code drawn in a terminal: a link a phone's camera reads off the screen. Each character holds two of the code's
//! rows, in black on white whatever the terminal's own colours are, as a camera reads a dark code on a light ground.
const std = @import("std");
const Writer = std.Io.Writer;

/// The room qrcodegen asks for a code of its largest version, and for its working.
const buffer_length = 3918;
const error_correction_low = 0;
const version_min = 1;
const version_max = 40;
const mask_auto = -1;

/// The light margin a code needs around it, in modules.
const quiet_zone = 4;

/// Black on white, by the two colours of the 256 that no terminal's theme redefines.
const colours = "\x1b[38;5;16;48;5;231m";
const reset = "\x1b[0m";

extern fn qrcodegen_encodeText(text: [*:0]const u8, temp: [*]u8, code: [*]u8, correction: c_int, min: c_int, max: c_int, mask: c_int, boost: bool) bool;
extern fn qrcodegen_getSize(code: [*]const u8) c_int;
extern fn qrcodegen_getModule(code: [*]const u8, x: c_int, y: c_int) bool;

/// Draws the code of `text` on `out`, its margin with it; `error.TextTooLong` where no code holds it.
pub fn draw(out: *Writer, text: [:0]const u8) !void {
    var temp: [buffer_length]u8 = undefined;
    var code: [buffer_length]u8 = undefined;
    if (!qrcodegen_encodeText(text, &temp, &code, error_correction_low, version_min, version_max, mask_auto, false)) return error.TextTooLong;
    const size = qrcodegen_getSize(&code);
    var y: c_int = -quiet_zone;
    while (y < size + quiet_zone) : (y += 2) {
        try out.writeAll(colours);
        var x: c_int = -quiet_zone;
        while (x < size + quiet_zone) : (x += 1) {
            // Outside the code qrcodegen answers light, so the margin needs no case of its own.
            try out.writeAll(halfBlocks(qrcodegen_getModule(&code, x, y), qrcodegen_getModule(&code, x, y + 1)));
        }
        try out.writeAll(reset ++ "\n");
    }
}

/// The character of a column's two rows, each dark or light.
fn halfBlocks(top: bool, bottom: bool) []const u8 {
    if (top and bottom) return "█";
    if (top) return "▀";
    if (bottom) return "▄";
    return " ";
}

test "a code is drawn with its margin, two rows to a line, its finder dark at the corner" {
    var buffer: [8192]u8 = undefined;
    var out: Writer = .fixed(&buffer);
    try draw(&out, "A");
    var lines = std.mem.splitScalar(u8, out.buffered(), '\n');
    var count: usize = 0;
    var second: []const u8 = "";
    while (lines.next()) |line| : (count += 1) {
        if (line.len == 0) continue;
        if (count == 2) second = line;
        try std.testing.expect(std.mem.startsWith(u8, line, colours));
        try std.testing.expect(std.mem.endsWith(u8, line, reset));
    }
    // Version 1 is 21 modules; with its margin, 29 rows make 15 lines, and the split leaves one empty piece after them.
    try std.testing.expectEqual(@as(usize, 16), count);
    // The third line holds rows 0 and 1: past the margin, the finder's top edge, dark over dark at its corner's second row.
    try std.testing.expect(std.mem.startsWith(u8, second[colours.len..], "    "));
    try std.testing.expect(std.mem.startsWith(u8, second[colours.len + 4 ..], "█"));
}

test "a text no code holds is refused" {
    var buffer: [64]u8 = undefined;
    var out: Writer = .fixed(&buffer);
    const text: [4000:0]u8 = @splat('a');
    try std.testing.expectError(error.TextTooLong, draw(&out, &text));
}

test "the characters of two rows" {
    try std.testing.expectEqualStrings("█", halfBlocks(true, true));
    try std.testing.expectEqualStrings("▀", halfBlocks(true, false));
    try std.testing.expectEqualStrings("▄", halfBlocks(false, true));
    try std.testing.expectEqualStrings(" ", halfBlocks(false, false));
}
