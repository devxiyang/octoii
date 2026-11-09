//! JSON as Octoii writes it: one value, one encoding — fields in their declared order, an absent optional left out, no
//! whitespace, numbers in their shortest exact form — so that what is built twice from the same data is the same bytes,
//! as a provider's prompt cache needs. JSON whose shape is another's to say is kept as `Raw`, written as it came.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// How a value is written: minified, absent optionals left out.
pub const options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };

/// `value` encoded, in `allocator`.
pub fn encode(allocator: Allocator, value: anytype) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    std.json.Stringify.value(value, options, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// How a decoding takes JSON another wrote: a field it does not know is passed over, any other mismatch refused.
pub const decode_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

/// `bytes` decoded as a `T`; what it holds lives in `arena`.
pub fn decode(comptime T: type, arena: Allocator, bytes: []const u8) std.json.ParseError(std.json.Scanner)!T {
    return std.json.parseFromSliceLeaky(T, arena, bytes, decode_options);
}

/// `value` decoded as a `T`, as `decode` takes bytes; what it holds lives in `arena`.
pub fn decodeValue(comptime T: type, arena: Allocator, value: std.json.Value) std.json.ParseFromValueError!T {
    return std.json.parseFromValueLeaky(T, arena, value, decode_options);
}

/// `value` as a JSON value to change as JSON: its canonical encoding, read back.
pub fn toValue(arena: Allocator, value: anytype) Allocator.Error!std.json.Value {
    const text = try encode(arena, value);
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // What was just encoded reads back.
        else => unreachable,
    };
}

/// One object of several parts' members, in order: each part a struct, whose absent optionals are left out, or an
/// object map; a member of a later part stands in place of an earlier part's of its name. A wire request is made of
/// typed parts so, never of JSON shaped by hand.
pub fn Merged(comptime Parts: type) type {
    return struct {
        parts: Parts,

        pub fn jsonStringify(object: @This(), writer: *std.json.Stringify) std.json.Stringify.Error!void {
            try writer.beginObject();
            inline for (@typeInfo(Parts).@"struct".field_names, 0..) |_, index| try writeMembers(object.parts, index, writer);
            try writer.endObject();
        }
    };
}

/// The object `parts`, a tuple, make.
pub fn merged(parts: anytype) Merged(@TypeOf(parts)) {
    return .{ .parts = parts };
}

fn writeMembers(parts: anytype, comptime index: usize, writer: *std.json.Stringify) std.json.Stringify.Error!void {
    const given = parts[index];
    if (@typeInfo(@TypeOf(given)) == .optional and @TypeOf(given) != ?std.json.ObjectMap) {
        if (given == null) return;
    }
    const part = if (@typeInfo(@TypeOf(given)) == .optional and @TypeOf(given) != ?std.json.ObjectMap) given.? else given;
    const Part = @TypeOf(part);
    if (Part == std.json.ObjectMap or Part == ?std.json.ObjectMap) {
        const map: std.json.ObjectMap = if (Part == ?std.json.ObjectMap) part orelse return else part;
        var it = map.iterator();
        while (it.next()) |member| {
            if (laterHas(parts, index, member.key_ptr.*)) continue;
            try writer.objectField(member.key_ptr.*);
            try writer.write(member.value_ptr.*);
        }
        return;
    }
    inline for (@typeInfo(Part).@"struct".field_names) |name| {
        const member = @field(part, name);
        const absent = @typeInfo(@TypeOf(member)) == .optional and member == null and !writer.options.emit_null_optional_fields;
        if (!absent and !laterHas(parts, index, name)) {
            try writer.objectField(name);
            try writer.write(member);
        }
    }
}

/// Whether a part after `index` has a member `name` it writes.
fn laterHas(parts: anytype, comptime index: usize, name: []const u8) bool {
    inline for (@typeInfo(@TypeOf(parts)).@"struct".field_names, 0..) |_, later| {
        if (later > index and partHas(parts[later], name)) return true;
    }
    return false;
}

fn partHas(given: anytype, name: []const u8) bool {
    if (@TypeOf(given) == ?std.json.ObjectMap) return if (given) |map| map.contains(name) else false;
    if (@typeInfo(@TypeOf(given)) == .optional) return if (given) |part| partHas(part, name) else false;
    const part = given;
    const Part = @TypeOf(part);
    if (Part == std.json.ObjectMap) return part.contains(name);
    inline for (@typeInfo(Part).@"struct".field_names) |field| {
        if (std.mem.eql(u8, field, name)) {
            const member = @field(part, field);
            return @typeInfo(@TypeOf(member)) != .optional or member != null;
        }
    }
    return false;
}

/// A member that may be given as `null`, which says something its absence does not, such as a setting turned off
/// rather than left to the provider. As `?Nullable(T)`, null is absent, `.null` is given as `null`; a struct that has
/// such members decodes with `KeepingNulls`, as a plain decoding reads a `null` as absent.
pub fn Nullable(comptime T: type) type {
    return union(enum) {
        null,
        value: T,

        pub const Value = T;

        pub fn jsonStringify(nullable: @This(), writer: *std.json.Stringify) std.json.Stringify.Error!void {
            switch (nullable) {
                .null => try writer.write(null),
                .value => |value| try writer.write(value),
            }
        }

        pub fn jsonParse(allocator: Allocator, source: anytype, parse_options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!@This() {
            const value = try std.json.Value.jsonParse(allocator, source, parse_options);
            return jsonParseFromValue(allocator, value, parse_options);
        }

        pub fn jsonParseFromValue(allocator: Allocator, value: std.json.Value, parse_options: std.json.ParseOptions) std.json.ParseFromValueError!@This() {
            if (value == .null) return .null;
            return .{ .value = try std.json.innerParseFromValue(T, allocator, value, parse_options) };
        }

        /// The value given; null where it is `null`.
        pub fn given(nullable: @This()) ?T {
            return switch (nullable) {
                .null => null,
                .value => |value| value,
            };
        }
    };
}

/// The decoding of a struct `T` whose `?Nullable` members tell `null` from absent: a member given as `null` is
/// `.null`; every other member decodes as it would.
pub fn KeepingNulls(comptime T: type) type {
    return struct {
        pub fn jsonParse(allocator: Allocator, source: anytype, parse_options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!T {
            const value = try std.json.Value.jsonParse(allocator, source, parse_options);
            return jsonParseFromValue(allocator, value, parse_options);
        }

        pub fn jsonParseFromValue(allocator: Allocator, value: std.json.Value, parse_options: std.json.ParseOptions) std.json.ParseFromValueError!T {
            if (value != .object) return error.UnexpectedToken;
            const info = @typeInfo(T).@"struct";
            var made: T = undefined;
            inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
                if (value.object.get(name)) |member| {
                    // A nullable member's own decoding takes `null`, which an optional's would read as absent.
                    const Decoded = if (comptime isNullable(Field)) @typeInfo(Field).optional.child else Field;
                    @field(made, name) = try std.json.innerParseFromValue(Decoded, allocator, member, parse_options);
                } else if (attrs.defaultValue(Field)) |default| {
                    @field(made, name) = default;
                } else return error.MissingField;
            }
            if (!parse_options.ignore_unknown_fields) {
                var it = value.object.iterator();
                while (it.next()) |member| if (!hasField(T, member.key_ptr.*)) return error.UnknownField;
            }
            return made;
        }
    };
}

fn isNullable(comptime Field: type) bool {
    if (@typeInfo(Field) != .optional) return false;
    const Child = @typeInfo(Field).optional.child;
    return @typeInfo(Child) == .@"union" and @hasDecl(Child, "Value") and Child == Nullable(Child.Value);
}

fn hasField(comptime T: type, name: []const u8) bool {
    inline for (@typeInfo(T).@"struct".field_names) |field| if (std.mem.eql(u8, field, name)) return true;
    return false;
}

/// Bytes as JSON carries them: a string of their base64, as JSON has no bytes of its own — what a terminal wrote, an
/// image read.
pub const Base64 = struct {
    bytes: []const u8,

    pub fn jsonStringify(base64: Base64, writer: *std.json.Stringify) std.Io.Writer.Error!void {
        try writer.beginWriteRaw();
        try writer.writer.writeByte('"');
        try std.base64.standard.Encoder.encodeWriter(writer.writer, base64.bytes);
        try writer.writer.writeByte('"');
        writer.endWriteRaw();
    }
};

test "bytes are written as a string of their base64" {
    const written = try encode(std.testing.allocator, .{ .data = Base64{ .bytes = "hi\x00" } });
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("{\"data\":\"aGkA\"}", written);
}

/// JSON kept whole, whatever its shape: a schema, metadata, a provider's own data. It is held in its canonical
/// encoding — read, then written minified with its members in the order they came — and written back as it is held.
pub const Raw = struct {
    text: []const u8,

    pub fn jsonStringify(raw: Raw, writer: *std.json.Stringify) std.Io.Writer.Error!void {
        try writer.beginWriteRaw();
        try writer.writer.writeAll(raw.text);
        writer.endWriteRaw();
    }

    pub fn jsonParse(allocator: Allocator, source: anytype, parse_options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!Raw {
        const value = try std.json.Value.jsonParse(allocator, source, parse_options);
        return .{ .text = encode(allocator, value) catch return error.OutOfMemory };
    }

    pub fn jsonParseFromValue(allocator: Allocator, value: std.json.Value, _: std.json.ParseOptions) std.json.ParseFromValueError!Raw {
        return .{ .text = encode(allocator, value) catch return error.OutOfMemory };
    }

    /// The JSON `text` holds, checked and made canonical.
    pub fn of(arena: Allocator, text: []const u8) !Raw {
        const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
        return .{ .text = try encode(arena, value) };
    }
};

/// Whether two JSON values are one value: an object's members in any order, a number by what it is worth.
pub fn equal(a: std.json.Value, b: std.json.Value) bool {
    return switch (a) {
        .null => b == .null,
        .bool => |value| b == .bool and b.bool == value,
        .string => |text| b == .string and std.mem.eql(u8, text, b.string),
        .integer, .float, .number_string => numberOf(a) != null and numberOf(a) == numberOf(b),
        .array => |items| b == .array and b.array.items.len == items.items.len and for (items.items, b.array.items) |left, right| {
            if (!equal(left, right)) break false;
        } else true,
        .object => |members| b == .object and b.object.count() == members.count() and objectsEqual(members, b.object),
    };
}

fn objectsEqual(a: std.json.ObjectMap, b: std.json.ObjectMap) bool {
    var it = a.iterator();
    while (it.next()) |member| {
        const other = b.get(member.key_ptr.*) orelse return false;
        if (!equal(member.value_ptr.*, other)) return false;
    }
    return true;
}

/// What a JSON number is worth; null for a value that is no number.
fn numberOf(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        .number_string => |text| std.fmt.parseFloat(f64, text) catch null,
        else => null,
    };
}

/// The JSON of a union: its variant's own, told apart by its kind — a string, a number, a boolean, an array or an
/// object — and an object by its member `key`, which a variant's struct declares as an enum of the names it takes,
/// optional where the member may be left out. The first variant that fits and decodes is the one, and one with a
/// `valid` function decodes only where it holds; a value no variant takes is refused. A union takes it as its own:
///
///     const variants = json.Variants(@This(), "type");
///     pub const jsonParse = variants.jsonParse;
///     pub const jsonParseFromValue = variants.jsonParseFromValue;
///     pub const jsonStringify = variants.jsonStringify;
pub fn Variants(comptime U: type, comptime key: []const u8) type {
    return struct {
        pub fn jsonParse(allocator: Allocator, source: anytype, parse_options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!U {
            const value = try std.json.Value.jsonParse(allocator, source, parse_options);
            return jsonParseFromValue(allocator, value, parse_options);
        }

        pub fn jsonParseFromValue(allocator: Allocator, value: std.json.Value, parse_options: std.json.ParseOptions) std.json.ParseFromValueError!U {
            var failure: std.json.ParseFromValueError = error.UnexpectedToken;
            const variants = @typeInfo(U).@"union";
            inline for (variants.field_names, variants.field_types) |name, Variant| {
                if (fits(Variant, key, value)) {
                    if (decodeVariant(Variant, allocator, value, parse_options)) |payload| {
                        return @unionInit(U, name, payload);
                    } else |err| failure = err;
                }
            }
            return failure;
        }

        pub fn jsonStringify(variant: U, writer: *std.json.Stringify) std.json.Stringify.Error!void {
            switch (variant) {
                inline else => |payload| try writer.write(payload),
            }
        }

        /// Whether a variant takes an object whose member `key` is the text `name`.
        pub fn names(name: []const u8) bool {
            inline for (@typeInfo(U).@"union".field_types) |Variant| {
                if (takes(Variant, key, .{ .string = name })) return true;
            }
            return false;
        }
    };
}

/// Whether a value is of the kind a variant `T` takes, and an object one whose member `key` it takes.
fn fits(comptime T: type, comptime key: []const u8, value: std.json.Value) bool {
    return switch (value) {
        .string => |text| switch (@typeInfo(T)) {
            .@"enum" => std.meta.stringToEnum(T, text) != null,
            else => T == []const u8,
        },
        .integer, .float, .number_string => switch (@typeInfo(T)) {
            .int, .float => true,
            else => false,
        },
        .bool => T == bool,
        .array => @typeInfo(T) == .pointer and T != []const u8,
        .object => |object| switch (@typeInfo(T)) {
            .@"struct" => takes(T, key, object.get(key)),
            .@"union" => true,
            else => false,
        },
        .null => false,
    };
}

/// Whether a struct takes an object whose member `key` is `member`: any, where it declares no such field or one that
/// is no enum; else a name the field's enum takes, or none at all where the field is optional.
fn takes(comptime T: type, comptime key: []const u8, member: ?std.json.Value) bool {
    if (!@hasField(T, key)) return true;
    const Field = @FieldType(T, key);
    const given = member orelse return @typeInfo(Field) == .optional;
    const Tag = switch (@typeInfo(Field)) {
        .optional => |optional| optional.child,
        else => Field,
    };
    if (@typeInfo(Tag) != .@"enum") return true;
    return given == .string and std.meta.stringToEnum(Tag, given.string) != null;
}

/// `value` decoded as the variant `T`, and checked where `T` says what makes one valid.
fn decodeVariant(comptime T: type, allocator: Allocator, value: std.json.Value, parse_options: std.json.ParseOptions) std.json.ParseFromValueError!T {
    const payload = try std.json.innerParseFromValue(T, allocator, value, parse_options);
    if (comptime std.meta.hasFn(T, "valid")) {
        if (!payload.valid()) return error.MissingField;
    }
    return payload;
}

test "a value encodes one way: declared order, absent optionals left out, no whitespace, shortest numbers" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const Tool = struct { name: []const u8, description: ?[]const u8 = null, strict: ?bool = null, parameters: Raw, temperature: f64 };
    const parameters = try Raw.of(arena, "{ \"type\" : \"object\",\n \"required\": [\"city\"] }");
    const tool: Tool = .{ .name = "weather", .parameters = parameters, .temperature = 0.2 };
    const once = try encode(arena, tool);
    try std.testing.expectEqualStrings("{\"name\":\"weather\",\"parameters\":{\"type\":\"object\",\"required\":[\"city\"]},\"temperature\":0.2}", once);
    try std.testing.expectEqualStrings(once, try encode(arena, try decode(Tool, arena, once)));
}

test "a decoding passes over fields it does not know, and keeps raw JSON as it came" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const Item = struct { type: []const u8, metadata: ?Raw = null };
    const item = try decode(Item, arena, "{\"type\":\"message\",\"later\":1,\"metadata\":{\"b\":[1, 2.5, \"x\"],\"a\":null}}");
    try std.testing.expectEqualStrings("message", item.type);
    try std.testing.expectEqualStrings("{\"b\":[1,2.5,\"x\"],\"a\":null}", item.metadata.?.text);
    try std.testing.expectError(error.UnexpectedToken, decode(Item, arena, "{\"type\":1}"));
}

const Shape = union(enum) {
    circle: struct { type: enum { circle } = .circle, radius: f64 },
    square: struct {
        type: enum { square, box } = .square,
        side: f64,
        filled: ?bool = null,

        pub fn valid(square: @This()) bool {
            return square.side > 0;
        }
    },
    label: struct { type: ?enum { label } = .label, text: []const u8 },
    name: []const u8,
    names: []const []const u8,
    size: f64,

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

test "a union's variant is told by its kind, and an object's by its member" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const shapes = try decode([]const Shape, arena, "[{\"type\":\"circle\",\"radius\":1},{\"type\":\"box\",\"side\":2,\"later\":0},{\"text\":\"x\"},\"y\",[\"z\"],3.5]");
    try std.testing.expectEqual(@as(f64, 1), shapes[0].circle.radius);
    try std.testing.expectEqual(.box, shapes[1].square.type);
    try std.testing.expectEqualStrings("x", shapes[2].label.text);
    try std.testing.expectEqualStrings("y", shapes[3].name);
    try std.testing.expectEqualStrings("z", shapes[4].names[0]);
    try std.testing.expectEqual(@as(f64, 3.5), shapes[5].size);
    const once = try encode(arena, shapes);
    try std.testing.expectEqualStrings("[{\"type\":\"circle\",\"radius\":1},{\"type\":\"box\",\"side\":2},{\"type\":\"label\",\"text\":\"x\"},\"y\",[\"z\"],3.5]", once);
    try std.testing.expectEqualStrings(once, try encode(arena, try decode([]const Shape, arena, once)));
}

test "a union refuses a value no variant takes: an unknown name, a variant not valid, a member left out" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    try std.testing.expectError(error.UnexpectedToken, decode(Shape, arena, "{\"type\":\"triangle\",\"radius\":1}"));
    try std.testing.expectError(error.MissingField, decode(Shape, arena, "{\"type\":\"square\",\"side\":0}"));
    try std.testing.expectError(error.MissingField, decode(Shape, arena, "{\"radius\":1}"));
    try std.testing.expectError(error.UnexpectedToken, decode(Shape, arena, "true"));
}

test "JSON values are equal whatever the order of their members and the form of their numbers" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const left = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"a\":[1,true,null],\"b\":{\"c\":\"x\"}}", .{});
    const right = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"b\":{\"c\":\"x\"},\"a\":[1.0,true,null]}", .{});
    const other = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"b\":{\"c\":\"x\"},\"a\":[2,true,null]}", .{});
    try std.testing.expect(equal(left, right));
    try std.testing.expect(!equal(left, other));
}

test "parts merge into one object, a later part's member in place of an earlier one's" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var extra: std.json.ObjectMap = .empty;
    try extra.put(arena, "geo", .{ .string = "us" });
    try extra.put(arena, "model", .{ .string = "override" });
    const Base = struct { model: []const u8, effort: ?[]const u8 = null, stream: bool = false };
    const made = merged(.{ Base{ .model = "m" }, .{ .stream = true }, extra });
    try std.testing.expectEqualStrings("{\"stream\":true,\"geo\":\"us\",\"model\":\"override\"}", try encode(arena, made));
    try std.testing.expectEqualStrings("{\"model\":\"m\",\"stream\":true}", try encode(arena, merged(.{ Base{ .model = "m" }, .{ .stream = true }, @as(?std.json.ObjectMap, null) })));
}

test "a nullable member tells null from absent, both ways" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const Setting = struct { silence_ms: u32 };
    const Input = struct {
        model: []const u8,
        turn: ?Nullable(Setting) = null,

        pub const jsonParseFromValue = KeepingNulls(@This()).jsonParseFromValue;
        pub const jsonParse = KeepingNulls(@This()).jsonParse;
    };
    const off = try decode(Input, arena, "{\"model\":\"m\",\"turn\":null,\"later\":1}");
    try std.testing.expectEqual(.null, std.meta.activeTag(off.turn.?));
    const left = try decode(Input, arena, "{\"model\":\"m\"}");
    try std.testing.expectEqual(null, left.turn);
    const given = try decode(Input, arena, "{\"model\":\"m\",\"turn\":{\"silence_ms\":300}}");
    try std.testing.expectEqual(@as(u32, 300), given.turn.?.given().?.silence_ms);
    try std.testing.expectEqualStrings("{\"model\":\"m\",\"turn\":null}", try encode(arena, off));
    try std.testing.expectEqualStrings("{\"model\":\"m\"}", try encode(arena, left));
    try std.testing.expectError(error.MissingField, decode(Input, arena, "{\"turn\":null}"));
}

/// Encodes a value of strings, an absent optional and numbers with `allocator`, then frees it.
fn encodeEntry(allocator: Allocator) !void {
    const Entry = struct { id: []const u8, type: []const u8, reason: ?[]const u8 = null, numbers: []const f64 };
    allocator.free(try encode(allocator, Entry{ .id = "019a", .type = "turn-end", .numbers = &.{ 1.5, 2 } }));
}

test "an encoding frees what it took where an allocation fails on the way" {
    try @import("testing.zig").checkAllAllocationFailures(encodeEntry, .{});
}

test "a decoding takes whatever bytes it is given: a value whole, or refused" {
    try std.testing.fuzz({}, fuzzDecode, .{ .corpus = &.{ "{\"id\":\"019a\",\"type\":\"turn-end\",\"outcome\":\"failed\",\"numbers\":[1.5,2]}", "[1,{\"a\":null},\"x\"]" } });
}

/// Decodes whatever bytes the fuzzer gives, as an entry and as a JSON value: each whole, or refused.
fn fuzzDecode(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [4096]u8 = undefined;
    const bytes = buffer[0..smith.slice(&buffer)];
    var arena_allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_allocator.deinit();
    const Entry = struct { id: []const u8, type: []const u8, outcome: ?enum { replied, failed, stopped } = null, numbers: ?[]const f64 = null };
    _ = decode(Entry, arena_allocator.allocator(), bytes) catch {};
    _ = decode(std.json.Value, arena_allocator.allocator(), bytes) catch {};
}
