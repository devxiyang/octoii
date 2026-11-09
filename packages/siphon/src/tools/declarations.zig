//! The TypeScript a script's tools are told in: each a function under `tools` taking its arguments as one object, the
//! JSON Schema of its parameters written as the TypeScript type of that object, each description a doc comment beside
//! what it describes — as the model reads TypeScript best, and writes the script that calls the tools in it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Writer = std.Io.Writer;

/// The declaration of the tool at `path` — `group.name`, as a script's engine nests a tool's name at its dots: its
/// description as a doc comment, then the function as a script reaches it, `tools.group.name(arguments: T):
/// Promise<string>`.
pub fn declare(writer: *Writer, path: []const u8, description: ?[]const u8, parameters: Value) Writer.Error!void {
    if (description) |text| try docComment(writer, text, 0);
    try writer.writeAll("tools");
    var names = std.mem.splitScalar(u8, path, '.');
    while (names.next()) |name| try member(writer, name);
    try writer.writeAll("(arguments: ");
    try typeOf(writer, parameters, 0);
    try writer.writeAll("): Promise<string>;\n");
}

/// `.name`, or `["name"]` for a name no identifier spells.
fn member(writer: *Writer, name: []const u8) Writer.Error!void {
    if (isIdentifier(name)) return writer.print(".{s}", .{name});
    try writer.print("[{f}]", .{std.json.fmt(name, .{})});
}

fn isIdentifier(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |char| if (!(std.ascii.isAlphanumeric(char) or char == '_' or char == '$')) return false;
    return true;
}

/// `text` as a doc comment, on one line where it has one, else a line of it to each line of the comment.
fn docComment(writer: *Writer, text: []const u8, depth: usize) Writer.Error!void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return;
    if (std.mem.indexOfScalar(u8, trimmed, '\n') == null) {
        try writer.writeAll("/** ");
        try commented(writer, trimmed);
        return writer.writeAll(" */\n");
    }
    try writer.writeAll("/**\n");
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |line| {
        try indent(writer, depth);
        try writer.writeAll(" * ");
        try commented(writer, std.mem.trimEnd(u8, line, " \t\r"));
        try writer.writeByte('\n');
    }
    try indent(writer, depth);
    try writer.writeAll(" */\n");
}

/// `text` within a comment: a `*/` in it would end the comment, so its slash stands apart.
fn commented(writer: *Writer, text: []const u8) Writer.Error!void {
    var rest = text;
    while (std.mem.indexOf(u8, rest, "*/")) |at| {
        try writer.writeAll(rest[0 .. at + 1]);
        try writer.writeAll(" ");
        rest = rest[at + 1 ..];
    }
    try writer.writeAll(rest);
}

fn indent(writer: *Writer, depth: usize) Writer.Error!void {
    try writer.splatByteAll(' ', depth * 2);
}

/// `schema` as a TypeScript type, at `depth` of nesting: its constant or enumeration as literals, its alternatives as a
/// union and its parts as an intersection, else its JSON type — an object's properties each by name, those it does
/// not require optional; what the schema does not say, `unknown`.
fn typeOf(writer: *Writer, schema: Value, depth: usize) Writer.Error!void {
    const object = switch (schema) {
        .object => |object| object,
        else => return writer.writeAll("unknown"),
    };
    if (object.get("const")) |constant| return writer.print("{f}", .{std.json.fmt(constant, .{})});
    if (arrayOf(object, "enum")) |options| return joinedLiterals(writer, options);
    if (arrayOf(object, "anyOf") orelse arrayOf(object, "oneOf")) |options| return joined(writer, options, " | ", depth);
    if (arrayOf(object, "allOf")) |parts| return joined(writer, parts, " & ", depth);
    if (object.get("type")) |kind| switch (kind) {
        .string => |name| return typeNamed(writer, object, name, depth),
        .array => |names| {
            for (names.items, 0..) |name, index| {
                if (index > 0) try writer.writeAll(" | ");
                try typeNamed(writer, object, if (name == .string) name.string else "", depth);
            }
            return;
        },
        else => {},
    };
    if (object.get("properties") != null) return objectType(writer, object, depth);
    try writer.writeAll("unknown");
}

/// The non-empty array `object` has at `key`.
fn arrayOf(object: std.json.ObjectMap, key: []const u8) ?[]const Value {
    const found = object.get(key) orelse return null;
    if (found != .array or found.array.items.len == 0) return null;
    return found.array.items;
}

fn joinedLiterals(writer: *Writer, values: []const Value) Writer.Error!void {
    for (values, 0..) |value, index| {
        if (index > 0) try writer.writeAll(" | ");
        try writer.print("{f}", .{std.json.fmt(value, .{})});
    }
}

/// Each of `schemas` as a type, in parentheses where it joins others, with `separator` between.
fn joined(writer: *Writer, schemas: []const Value, separator: []const u8, depth: usize) Writer.Error!void {
    for (schemas, 0..) |schema, index| {
        if (index > 0) try writer.writeAll(separator);
        if (schemas.len > 1) try writer.writeByte('(');
        try typeOf(writer, schema, depth);
        if (schemas.len > 1) try writer.writeByte(')');
    }
}

/// The type the JSON type `name` is, as `object` says of it.
fn typeNamed(writer: *Writer, object: std.json.ObjectMap, name: []const u8, depth: usize) Writer.Error!void {
    if (std.mem.eql(u8, name, "string")) return writer.writeAll("string");
    if (std.mem.eql(u8, name, "number") or std.mem.eql(u8, name, "integer")) return writer.writeAll("number");
    if (std.mem.eql(u8, name, "boolean")) return writer.writeAll("boolean");
    if (std.mem.eql(u8, name, "null")) return writer.writeAll("null");
    if (std.mem.eql(u8, name, "object")) return objectType(writer, object, depth);
    if (std.mem.eql(u8, name, "array")) {
        try writer.writeAll("Array<");
        try typeOf(writer, object.get("items") orelse .null, depth);
        return writer.writeAll(">");
    }
    try writer.writeAll("unknown");
}

/// An object's type: each property on a line of its own, its description above it, optional where not required; with
/// no properties, a record of what its other properties are.
fn objectType(writer: *Writer, object: std.json.ObjectMap, depth: usize) Writer.Error!void {
    const properties = if (object.get("properties")) |found| (if (found == .object) found.object else null) else null;
    if (properties == null or properties.?.count() == 0) {
        try writer.writeAll("Record<string, ");
        const others = object.get("additionalProperties") orelse Value{ .bool = true };
        try typeOf(writer, others, depth);
        return writer.writeAll(">");
    }
    const required = arrayOf(object, "required") orelse &.{};
    try writer.writeAll("{\n");
    for (properties.?.keys(), properties.?.values()) |name, schema| {
        if (schema == .object) if (schema.object.get("description")) |described| if (described == .string) {
            try indent(writer, depth + 1);
            try docComment(writer, described.string, depth + 1);
        };
        try indent(writer, depth + 1);
        if (isIdentifier(name)) try writer.writeAll(name) else try writer.print("{f}", .{std.json.fmt(name, .{})});
        if (!isRequired(required, name)) try writer.writeByte('?');
        try writer.writeAll(": ");
        try typeOf(writer, schema, depth + 1);
        try writer.writeAll(";\n");
    }
    try indent(writer, depth);
    try writer.writeByte('}');
}

fn isRequired(required: []const Value, name: []const u8) bool {
    for (required) |each| if (each == .string and std.mem.eql(u8, each.string, name)) return true;
    return false;
}

fn declared(arena: Allocator, path: []const u8, description: ?[]const u8, parameters: []const u8) ![]const u8 {
    var out: Writer.Allocating = .init(arena);
    try declare(&out.writer, path, description, try std.json.parseFromSliceLeaky(Value, arena, parameters, .{}));
    return out.written();
}

test "a tool is declared as a function under tools, its parameters an object type, its descriptions doc comments" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const parameters =
        \\{"type":"object","properties":{
        \\ "owner":{"type":"string","description":"Who owns it"},
        \\ "labels":{"type":"array","items":{"type":"string"}},
        \\ "state":{"enum":["open","closed"]},
        \\ "limit":{"type":["integer","null"]},
        \\ "body-text":{"anyOf":[{"type":"string"},{"type":"object","properties":{"html":{"type":"string"}},"required":["html"]}]},
        \\ "extra":{"type":"object"}
        \\},"required":["owner"]}
    ;
    try std.testing.expectEqualStrings(
        \\/** Makes an issue: see * / above */
        \\tools.github.create_issue(arguments: {
        \\  /** Who owns it */
        \\  owner: string;
        \\  labels?: Array<string>;
        \\  state?: "open" | "closed";
        \\  limit?: number | null;
        \\  "body-text"?: (string) | ({
        \\    html: string;
        \\  });
        \\  extra?: Record<string, unknown>;
        \\}): Promise<string>;
        \\
    , try declared(arena, "github.create_issue", "Makes an issue: see */ above", parameters));
}

test "a name no identifier spells is reached in brackets, and a description of many lines is a comment of as many" {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    try std.testing.expectEqualStrings(
        \\/**
        \\ * Searches.
        \\ * Pages of ten.
        \\ */
        \\tools["my-docs"].search(arguments: Record<string, unknown>): Promise<string>;
        \\
    , try declared(arena, "my-docs.search", "Searches.\nPages of ten.", "{\"type\":\"object\"}"));
}
