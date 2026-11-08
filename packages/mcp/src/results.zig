//! What a server answers, read into the shapes the client takes; an answer that does not fit is a protocol violation.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const foundation = @import("foundation");
const types = @import("types.zig");
const failure_ = @import("failure.zig");
const Slot = failure_.Slot;
const Error = failure_.Error;

/// `value`, a member of a result, read as `T`; a protocol violation saying `what` does not fit where it is not.
fn decoded(comptime T: type, slot: *Slot, value: ?Value, comptime what: []const u8) Error!T {
    const given = value orelse return slot.violated(what, .{});
    return foundation.json.decodeValue(T, slot.arena, given) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => slot.violated(what, .{}),
    };
}

pub fn callToolResult(slot: *Slot, result: std.json.ObjectMap) Error!types.CallToolResult {
    const content = try decoded([]const types.ContentBlock, slot, result.get("content"), "A tool result's content is not a list of content blocks");
    const is_error: ?bool = if (result.get("isError")) |flag| switch (flag) {
        .bool => |given| given,
        else => return slot.violated("A tool result's isError is not a boolean", .{}),
    } else null;
    return .{ .content = content, .structuredContent = result.get("structuredContent"), .isError = is_error };
}

pub fn readResourceResult(slot: *Slot, result: std.json.ObjectMap) Error!types.ReadResourceResult {
    return .{ .contents = try decoded([]const types.ResourceContents, slot, result.get("contents"), "A resource's contents are not text or blob contents") };
}

pub fn getPromptResult(slot: *Slot, result: std.json.ObjectMap) Error!types.GetPromptResult {
    const messages = try decoded([]const types.PromptMessage, slot, result.get("messages"), "A prompt's messages are not role and content");
    const description = if (result.get("description")) |given| (if (given == .string) given.string else null) else null;
    return .{ .description = description, .messages = messages };
}

pub fn completeResult(slot: *Slot, result: std.json.ObjectMap) Error!types.CompleteResult {
    const completion = result.get("completion") orelse return slot.violated("A completion result has no completion", .{});
    if (completion != .object) return slot.violated("A completion result has no completion", .{});
    const values = try decoded([]const []const u8, slot, completion.object.get("values"), "A completion's values are not strings");
    const total: ?f64 = if (completion.object.get("total")) |given| numberOf(given) else null;
    const has_more = if (completion.object.get("hasMore")) |given| (if (given == .bool) given.bool else null) else null;
    return .{ .values = values, .total = total, .hasMore = has_more };
}

/// A page of `field`'s items, each read as `T`.
pub fn page(comptime T: type, slot: *Slot, result: std.json.ObjectMap, comptime field: []const u8) Error!types.Page(T) {
    const items = try decoded([]const T, slot, result.get(field), "A list result's " ++ field ++ " do not fit their schema");
    const cursor = if (result.get("nextCursor")) |given| (if (given == .string and given.string.len > 0) given.string else null) else null;
    return .{ .items = items, .nextCursor = cursor };
}

/// The part of an implementation the client keeps, its name and version; null where `value` names neither.
pub fn implementation(value: ?Value) ?types.Implementation {
    const given = value orelse return null;
    if (given != .object) return null;
    const name = given.object.get("name") orelse return null;
    const version = given.object.get("version") orelse return null;
    if (name != .string or version != .string) return null;
    return .{ .name = name.string, .version = version.string };
}

/// An elicitation's parameters: a form of a flat object of primitive fields, or a link; one without `mode` is a form.
pub fn elicitRequest(slot: *Slot, params: ?Value) Error!types.ElicitRequest {
    const given = params orelse return slot.violated("An elicitation has no message", .{});
    if (given != .object) return slot.violated("An elicitation has no message", .{});
    const message = given.object.get("message") orelse return slot.violated("An elicitation has no message", .{});
    if (message != .string) return slot.violated("An elicitation has no message", .{});
    const mode = if (given.object.get("mode")) |named| (if (named == .string) named.string else "") else "form";
    if (std.mem.eql(u8, mode, "url")) {
        const url = given.object.get("url") orelse return slot.violated("A URL elicitation has no valid URL", .{});
        if (url != .string or !isUrl(url.string)) return slot.violated("A URL elicitation has no valid URL", .{});
        const id = if (given.object.get("elicitationId")) |named| (if (named == .string) named.string else null) else null;
        return .{ .url = .{ .message = message.string, .url = url.string, .elicitationId = id } };
    }
    if (!std.mem.eql(u8, mode, "form")) return slot.violated("An elicitation has the unknown mode {s}", .{mode});
    const schema = given.object.get("requestedSchema") orelse return slot.violated("A form elicitation's schema is not a flat object of primitive fields", .{});
    if (!isFlatForm(schema)) return slot.violated("A form elicitation's schema is not a flat object of primitive fields", .{});
    return .{ .form = .{ .message = message.string, .requestedSchema = schema } };
}

/// Whether `schema` is an object of primitive fields: strings, numbers, integers, booleans, or lists of them.
fn isFlatForm(schema: Value) bool {
    if (schema != .object) return false;
    const kind = schema.object.get("type") orelse return false;
    if (kind != .string or !std.mem.eql(u8, kind.string, "object")) return false;
    const properties = schema.object.get("properties") orelse return false;
    if (properties != .object) return false;
    for (properties.object.values()) |field| {
        if (field != .object) return false;
        const field_type = field.object.get("type") orelse return false;
        if (field_type != .string) return false;
        const name = field_type.string;
        const primitive = std.mem.eql(u8, name, "string") or std.mem.eql(u8, name, "number") or std.mem.eql(u8, name, "integer") or std.mem.eql(u8, name, "boolean");
        const listed = std.mem.eql(u8, name, "array") and if (field.object.get("items")) |items| items == .object else false;
        if (!primitive and !listed) return false;
    }
    if (schema.object.get("required")) |required| {
        if (required != .array) return false;
        for (required.array.items) |each| if (each != .string) return false;
    }
    return true;
}

fn isUrl(text: []const u8) bool {
    const uri = std.Uri.parse(text) catch return false;
    return uri.scheme.len > 0;
}

/// A subscription's filter as a server may send it: a field of the wrong type counts as absent.
pub fn subscriptionFilter(arena: Allocator, value: ?Value) Allocator.Error!types.SubscriptionFilter {
    const given = value orelse return .{};
    if (given != .object) return .{};
    var filter: types.SubscriptionFilter = .{};
    inline for (.{ "toolsListChanged", "promptsListChanged", "resourcesListChanged" }) |name| {
        if (given.object.get(name)) |flag| @field(filter, name) = flag == .bool and flag.bool;
    }
    if (given.object.get("resourceSubscriptions")) |uris| if (uris == .array) {
        var kept: std.ArrayList([]const u8) = .empty;
        for (uris.array.items) |uri| {
            if (uri != .string) break;
            try kept.append(arena, uri.string);
        } else filter.resourceSubscriptions = kept.items;
    };
    return filter;
}

pub fn loggingLevel(value: ?Value) ?types.LoggingLevel {
    const given = value orelse return null;
    if (given != .string) return null;
    return std.meta.stringToEnum(types.LoggingLevel, given.string);
}

pub fn numberOf(value: Value) ?f64 {
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        .number_string => |text| std.fmt.parseFloat(f64, text) catch null,
        else => null,
    };
}

test "a tool's result is read, and one that does not fit is a protocol violation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var slot: Slot = .{ .arena = a };
    const good = try std.json.parseFromSliceLeaky(Value, a, "{\"content\":[{\"type\":\"text\",\"text\":\"hi\"},{\"type\":\"resource\",\"resource\":{\"uri\":\"u\",\"blob\":\"AA==\"}}],\"structuredContent\":{\"n\":1}}", .{});
    const result = try callToolResult(&slot, good.object);
    try std.testing.expectEqualStrings("hi", result.content[0].text.text);
    try std.testing.expectEqualStrings("AA==", result.content[1].resource.resource.blob.blob);
    const bad = try std.json.parseFromSliceLeaky(Value, a, "{\"content\":[{\"type\":\"video\"}]}", .{});
    try std.testing.expectError(error.Failed, callToolResult(&slot, bad.object));
    try std.testing.expectEqualStrings("A tool result's content is not a list of content blocks", slot.failure.?.protocol);
}

test "an elicitation is a flat form or a link, a form when it names no mode" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var slot: Slot = .{ .arena = a };
    const form = try std.json.parseFromSliceLeaky(Value, a, "{\"message\":\"Name?\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"required\":[\"name\"]}}", .{});
    try std.testing.expectEqualStrings("Name?", (try elicitRequest(&slot, form)).form.message);
    const link = try std.json.parseFromSliceLeaky(Value, a, "{\"mode\":\"url\",\"message\":\"Sign in\",\"url\":\"https://example.com/a\"}", .{});
    try std.testing.expectEqualStrings("https://example.com/a", (try elicitRequest(&slot, link)).url.url);
    const nested = try std.json.parseFromSliceLeaky(Value, a, "{\"message\":\"m\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"object\"}}}}", .{});
    try std.testing.expectError(error.Failed, elicitRequest(&slot, nested));
}
