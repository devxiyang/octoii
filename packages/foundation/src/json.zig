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
///
/// A value read from whole input is read ahead of — its kind, its text where it is a string a variant's enum may name,
/// its member `key` where it is an object — and where one variant alone fits, decoded as it from the input straight;
/// a value several variants fit, or one read as it streams, is read whole into a tree, and its variants tried on it.
pub fn Variants(comptime U: type, comptime key: []const u8) type {
    const variants = @typeInfo(U).@"union";
    return struct {
        pub fn jsonParse(allocator: Allocator, source: anytype, parse_options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!U {
            if (comptime @TypeOf(source.*) == std.json.Scanner) {
                if (source.is_end_of_input) {
                    if (try parseAhead(allocator, source, parse_options)) |variant| return variant;
                }
            }
            const value = try std.json.Value.jsonParse(allocator, source, parse_options);
            return jsonParseFromValue(allocator, value, parse_options);
        }

        pub fn jsonParseFromValue(allocator: Allocator, value: std.json.Value, parse_options: std.json.ParseOptions) std.json.ParseFromValueError!U {
            var failure: std.json.ParseFromValueError = error.UnexpectedToken;
            const ahead = aheadOf(value, key);
            inline for (variants.field_names, variants.field_types) |name, Variant| {
                if (fits(Variant, key, ahead)) {
                    if (checked(Variant, std.json.innerParseFromValue(Variant, allocator, value, parse_options))) |payload| {
                        return @unionInit(U, name, payload);
                    } else |err| failure = err;
                }
            }
            return failure;
        }

        /// The value `source` stands at, decoded from its input straight, where one variant alone fits it; none, the
        /// value left where it stands, where several do.
        fn parseAhead(allocator: Allocator, source: *std.json.Scanner, parse_options: std.json.ParseOptions) std.json.ParseError(std.json.Scanner)!?U {
            const kind = try source.peekNextTokenType();
            const ahead = try readAhead(allocator, source.input[source.cursor..], kind, key, comptime namesText(U));
            var fitting: usize = 0;
            inline for (variants.field_types) |Variant| {
                if (fits(Variant, key, ahead)) fitting += 1;
            }
            if (fitting == 0) return error.UnexpectedToken;
            if (fitting > 1) return null;
            inline for (variants.field_names, variants.field_types) |name, Variant| {
                if (fits(Variant, key, ahead)) return @unionInit(U, name, try checked(Variant, std.json.innerParse(Variant, allocator, source, parse_options)));
            }
            unreachable;
        }

        pub fn jsonStringify(variant: U, writer: *std.json.Stringify) std.json.Stringify.Error!void {
            switch (variant) {
                inline else => |payload| try writer.write(payload),
            }
        }

        /// Whether a variant takes an object whose member `key` is the text `name`.
        pub fn names(name: []const u8) bool {
            inline for (variants.field_types) |Variant| {
                if (takes(Variant, key, .{ .string = name })) return true;
            }
            return false;
        }
    };
}

/// What decides which variants take a value, read ahead of it: its kind; its text, where it is a string and a variant
/// is an enum, which names some texts alone; and its member `key` where it is an object — a string's text as the
/// member's own, any other value as `null`, none where it has no such member.
const Ahead = struct { kind: std.json.TokenType, text: ?[]const u8 = null, member: ?std.json.Value = null };

/// What decides which variants take `value`.
fn aheadOf(value: std.json.Value, comptime key: []const u8) Ahead {
    return switch (value) {
        .string => |text| .{ .kind = .string, .text = text },
        .integer, .float, .number_string => .{ .kind = .number },
        .bool => |on| .{ .kind = if (on) .true else .false },
        .array => .{ .kind = .array_begin },
        .object => |object| .{ .kind = .object_begin, .member = object.get(key) },
        .null => .{ .kind = .null },
    };
}

/// What decides which variants take the value of the kind `kind` at the start of `rest`, read from it as far as it
/// must be: a string's text where `with_text` says a variant names texts; an object's members till `key`.
fn readAhead(allocator: Allocator, rest: []const u8, kind: std.json.TokenType, comptime key: []const u8, with_text: bool) std.json.ParseError(std.json.Scanner)!Ahead {
    if (kind != .object_begin and !(kind == .string and with_text)) return .{ .kind = kind };
    if (kind == .object_begin) {
        if (firstMember(rest, key)) |text| return .{ .kind = kind, .member = .{ .string = text } };
    }
    var scanner: std.json.Scanner = .initCompleteInput(allocator, rest);
    defer scanner.deinit();
    if (kind == .string) return .{ .kind = kind, .text = try textOf(allocator, &scanner) };
    _ = try scanner.next();
    while (true) {
        switch (try scanner.nextAlloc(allocator, .alloc_if_needed)) {
            .object_end => return .{ .kind = kind },
            .string, .allocated_string => |name| {
                if (!std.mem.eql(u8, name, key)) {
                    try scanner.skipValue();
                    continue;
                }
                if (try scanner.peekNextTokenType() != .string) return .{ .kind = kind, .member = .null };
                return .{ .kind = kind, .member = .{ .string = try textOf(allocator, &scanner) } };
            },
            else => return error.UnexpectedToken,
        }
    }
}

/// The text of the member `key` of the object `rest` begins with, where it is the object's first member and a string
/// with no escapes in it, as an object Octoii wrote has it: read from the bytes straight, no scanner made.
fn firstMember(rest: []const u8, comptime key: []const u8) ?[]const u8 {
    var at = skipSpace(rest, 1);
    const quoted = "\"" ++ key ++ "\"";
    if (!std.mem.startsWith(u8, rest[at..], quoted)) return null;
    at = skipSpace(rest, at + quoted.len);
    if (at == rest.len or rest[at] != ':') return null;
    at = skipSpace(rest, at + 1);
    if (at == rest.len or rest[at] != '"') return null;
    const end = std.mem.indexOfAnyPos(u8, rest, at + 1, "\"\\") orelse return null;
    return if (rest[end] == '"') rest[at + 1 .. end] else null;
}

/// Where in `bytes` the whitespace from `from` on ends.
fn skipSpace(bytes: []const u8, from: usize) usize {
    var at = from;
    while (at < bytes.len and std.mem.indexOfScalar(u8, " \t\r\n", bytes[at]) != null) at += 1;
    return at;
}

/// The string `scanner` stands at.
fn textOf(allocator: Allocator, scanner: *std.json.Scanner) std.json.ParseError(std.json.Scanner)![]const u8 {
    return switch (try scanner.nextAlloc(allocator, .alloc_if_needed)) {
        .string, .allocated_string => |text| text,
        else => error.UnexpectedToken,
    };
}

/// Whether a variant of `U` is an enum, which takes the strings that name its tags alone.
fn namesText(comptime U: type) bool {
    for (@typeInfo(U).@"union".field_types) |Variant| {
        if (@typeInfo(Variant) == .@"enum") return true;
    }
    return false;
}

/// Whether a value is of the kind a variant `T` takes, and an object one whose member `key` it takes.
fn fits(comptime T: type, comptime key: []const u8, ahead: Ahead) bool {
    return switch (ahead.kind) {
        .string => switch (@typeInfo(T)) {
            .@"enum" => std.meta.stringToEnum(T, ahead.text.?) != null,
            else => T == []const u8,
        },
        .number => switch (@typeInfo(T)) {
            .int, .float => true,
            else => false,
        },
        .true, .false => T == bool,
        .array_begin => @typeInfo(T) == .pointer and T != []const u8,
        .object_begin => switch (@typeInfo(T)) {
            .@"struct" => takes(T, key, ahead.member),
            .@"union" => true,
            else => false,
        },
        else => false,
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

/// `decoded`, a variant `T` decoded, where `T` says it is valid, or says nothing of what makes one valid.
fn checked(comptime T: type, decoded: anytype) @TypeOf(decoded) {
    const payload = try decoded;
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

test "a union decodes from bytes as from a tree: its member read ahead wherever it stands, however it is written" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const texts = [_][]const u8{
        "{\"type\":\"circle\",\"radius\":1}",
        "{ \"radius\" : 1 , \"type\" : \"circle\" }",
        "{\"type\":\"b\\u006fx\",\"side\":2}",
        "{\"side\":2,\"filled\":true,\"type\":\"square\"}",
        "{\"text\":\"x\"}",
        "\"y\"",
        "[\"z\"]",
        "3.5",
    };
    for (texts) |text| {
        const tree = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
        try std.testing.expectEqualStrings(try encode(arena, try decodeValue(Shape, arena, tree)), try encode(arena, try decode(Shape, arena, text)));
    }
    try std.testing.expectError(error.UnexpectedToken, decode(Shape, arena, "{\"type\":null,\"text\":\"x\"}"));
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
