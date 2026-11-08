//! Text as files hold it: a page of its lines, a file's bytes as text and text as a file's bytes, an edit that finds
//! its text by tiers, and the diff between two texts — on none of Siphon's other parts, as each is a computation on
//! the text alone.
const lines = @import("text/lines.zig");
const file = @import("text/file.zig");
const edit = @import("text/edit.zig");
const diff = @import("text/diff.zig");
pub const Line = lines.Line;
pub const Bounds = lines.Bounds;
pub const Pager = lines.Pager;
pub const Text = file.Text;
pub const byte_order_mark = file.byte_order_mark;
pub const textOf = file.textOf;
pub const bytesOf = file.bytesOf;
pub const replacing = file.replacing;
pub const Tier = edit.Tier;
pub const Request = edit.Request;
pub const Refusal = edit.Refusal;
pub const Edited = edit.Edited;
pub const edited = edit.edited;
pub const unified = diff.unified;
pub const linesOf = diff.linesOf;
pub const runsOf = diff.runsOf;
pub const countsOf = diff.countsOf;
pub const exactly = diff.exactly;

test {
    _ = lines;
    _ = file;
    _ = edit;
    _ = diff;
}
