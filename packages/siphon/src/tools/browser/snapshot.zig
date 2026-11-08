//! A page's accessibility tree as an agent reads it, as a screen reader reads a page: a line for each thing a person
//! perceives on it, nested as they are — its role, its name, what state it is in, its value — and the element that is
//! each, by a ref the browser tools act on; what no one perceives passed over, its children read in its place: what the
//! tree leaves out, a container that is only a container, and text its parent is already named by.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Cdp = @import("../../browser.zig").Cdp;

/// How deep the tree is read; below, its things are read at that depth.
const depth_max = 64;

/// The roles of what is only a container, read through to its children, where it has no name of its own.
const containers = [_][]const u8{ "generic", "none", "presentation", "LabelText", "Section", "group" };

/// The roles of what a person perceives nothing of: pieces of text the browser lays out, and markers of lists.
const unperceived = [_][]const u8{ "InlineTextBox", "LineBreak", "ListMarker" };

/// The states shown of a thing, by the property the browser names each by.
const states = [_][]const u8{ "level", "checked", "pressed", "selected", "expanded", "disabled", "required", "readonly", "invalid" };

/// The roles whose value is shown after them, as what is in them.
const valued = [_][]const u8{ "textbox", "searchbox", "combobox", "spinbutton", "slider", "ListBoxOption" };

/// A ref to the element with the browser's node id `node`.
pub fn refOf(arena: Allocator, node: i64) ![]const u8 {
    return std.fmt.allocPrint(arena, "e{d}", .{node});
}

/// The browser's node id of the element `ref` names; null where it names none.
pub fn nodeOf(ref: []const u8) ?i64 {
    if (ref.len < 2 or ref[0] != 'e') return null;
    return std.fmt.parseInt(i64, ref[1..], 10) catch null;
}

/// The tree the browser gave — `Accessibility.getFullAXTree`'s result — as the agent reads it.
pub fn written(arena: Allocator, tree: std.json.Value) ![]const u8 {
    const nodes = Cdp.memberOf(tree, "nodes") orelse return "";
    if (nodes != .array or nodes.array.items.len == 0) return "";
    var by_id: std.StringHashMapUnmanaged(std.json.Value) = .empty;
    for (nodes.array.items) |node| if (Cdp.textOf(node, "nodeId")) |id| try by_id.put(arena, id, node);
    var writer: Writer = .{ .arena = arena, .by_id = &by_id };
    try writer.children(nodes.array.items[0], 0, "");
    return writer.out.items;
}

const Writer = struct {
    arena: Allocator,
    by_id: *const std.StringHashMapUnmanaged(std.json.Value),
    out: std.ArrayList(u8) = .empty,

    /// Reads the children of `node` at `depth`, what was read of the thing they are in — its name, its value — `named`.
    fn children(writer: *Writer, node: std.json.Value, depth: usize, named: []const u8) Allocator.Error!void {
        const ids = Cdp.memberOf(node, "childIds") orelse return;
        if (ids != .array) return;
        for (ids.array.items) |id| {
            if (id != .string) continue;
            const child = writer.by_id.get(id.string) orelse continue;
            try writer.thing(child, depth, named);
        }
    }

    /// Reads `node` at `depth` — a line of its own, or its children in its place — inside a thing whose name, and value,
    /// `named` holds.
    fn thing(writer: *Writer, node: std.json.Value, depth: usize, named: []const u8) Allocator.Error!void {
        const role = valueOf(Cdp.memberOf(node, "role")) orelse "";
        const name = valueOf(Cdp.memberOf(node, "name")) orelse "";
        const ignored = if (Cdp.memberOf(node, "ignored")) |flag| flag == .bool and flag.bool else false;
        if (ignored) return writer.children(node, depth, named);
        if (among(&unperceived, role)) return;
        if (std.mem.eql(u8, role, "StaticText")) {
            if (name.len == 0 or std.mem.indexOf(u8, named, name) != null) return;
            return writer.line(depth, "- text: {f}\n", .{std.json.fmt(name, .{})});
        }
        if (name.len == 0 and among(&containers, role)) return writer.children(node, depth, named);
        try writer.line(depth, "- {s}", .{role});
        if (name.len > 0) try writer.print(" {f}", .{std.json.fmt(name, .{})});
        try writer.statesOf(node);
        if (Cdp.numberOf(node, "backendDOMNodeId")) |element| try writer.print(" [ref=e{d}]", .{@as(i64, @intFromFloat(element))});
        const value = valueOf(Cdp.memberOf(node, "value")) orelse "";
        const shows_value = value.len > 0 and among(&valued, role);
        if (shows_value) try writer.print(": {f}", .{std.json.fmt(value, .{})});
        try writer.out.append(writer.arena, '\n');
        // The text of what is in a field is its value, read already.
        const read = if (shows_value) try std.mem.concat(writer.arena, u8, &.{ name, "\n", value }) else name;
        try writer.children(node, @min(depth + 1, depth_max), read);
    }

    /// The states of `node` that hold, each in brackets: a level by its number, a state that is mixed so.
    fn statesOf(writer: *Writer, node: std.json.Value) Allocator.Error!void {
        const properties = Cdp.memberOf(node, "properties") orelse return;
        if (properties != .array) return;
        for (properties.array.items) |property| {
            const name = Cdp.textOf(property, "name") orelse continue;
            if (!among(&states, name)) continue;
            const value = Cdp.memberOf(Cdp.memberOf(property, "value") orelse continue, "value") orelse continue;
            switch (value) {
                .bool => |holds| if (holds) try writer.print(" [{s}]", .{name}),
                .integer => |number| try writer.print(" [{s}={d}]", .{ name, number }),
                .string => |state| {
                    if (std.mem.eql(u8, state, "true")) try writer.print(" [{s}]", .{name});
                    if (std.mem.eql(u8, state, "mixed")) try writer.print(" [{s}=mixed]", .{name});
                },
                else => {},
            }
        }
    }

    fn line(writer: *Writer, depth: usize, comptime format: []const u8, arguments: anytype) Allocator.Error!void {
        try writer.out.appendNTimes(writer.arena, ' ', depth * 2);
        try writer.print(format, arguments);
    }

    fn print(writer: *Writer, comptime format: []const u8, arguments: anytype) Allocator.Error!void {
        try writer.out.print(writer.arena, format, arguments);
    }
};

/// The value an accessibility value holds, where it is text or a number.
fn valueOf(value: ?std.json.Value) ?[]const u8 {
    const held = Cdp.memberOf(value orelse return null, "value") orelse return null;
    return switch (held) {
        .string => |text| text,
        .number_string => |text| text,
        else => null,
    };
}

fn among(names: []const []const u8, name: []const u8) bool {
    for (names) |each| if (std.mem.eql(u8, each, name)) return true;
    return false;
}

test "a tree is read as a person perceives it: containers read through, text its parent is named by passed over, refs to the elements" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tree = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"nodes":[
        \\ {"nodeId":"1","role":{"value":"RootWebArea"},"name":{"value":"Demo"},"childIds":["2","3"],"backendDOMNodeId":1},
        \\ {"nodeId":"2","role":{"value":"generic"},"name":{"value":""},"childIds":["4","5","7"],"backendDOMNodeId":5},
        \\ {"nodeId":"3","ignored":true,"role":{"value":"none"},"childIds":["8"]},
        \\ {"nodeId":"4","role":{"value":"heading"},"name":{"value":"Hello"},"properties":[{"name":"level","value":{"type":"integer","value":1}}],"childIds":["6"],"backendDOMNodeId":7},
        \\ {"nodeId":"6","role":{"value":"StaticText"},"name":{"value":"Hello"},"childIds":["9"],"backendDOMNodeId":8},
        \\ {"nodeId":"9","role":{"value":"InlineTextBox"},"name":{"value":"Hello"}},
        \\ {"nodeId":"5","role":{"value":"textbox"},"name":{"value":"Name"},"value":{"value":"Ada"},"properties":[{"name":"required","value":{"value":true}},{"name":"disabled","value":{"value":false}}],"backendDOMNodeId":12},
        \\ {"nodeId":"7","role":{"value":"StaticText"},"name":{"value":"line one\nline two"},"backendDOMNodeId":13},
        \\ {"nodeId":"8","role":{"value":"checkbox"},"name":{"value":"Agree"},"properties":[{"name":"checked","value":{"type":"tristate","value":"mixed"}}],"backendDOMNodeId":20}
        \\]}
    , .{});
    try std.testing.expectEqualStrings(
        \\- heading "Hello" [level=1] [ref=e7]
        \\- textbox "Name" [required] [ref=e12]: "Ada"
        \\- text: "line one\nline two"
        \\- checkbox "Agree" [checked=mixed] [ref=e20]
        \\
    , try written(arena, tree));
    try std.testing.expectEqual(@as(?i64, 12), nodeOf("e12"));
    try std.testing.expectEqual(@as(?i64, null), nodeOf("12"));
}
