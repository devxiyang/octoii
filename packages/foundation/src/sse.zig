//! Server-sent events, as the HTML standard's event-stream interpretation reads them, from a body as it streams: each
//! event is given as soon as the blank line that ends it arrives.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ChunkReader = @import("replay.zig").ChunkReader;

/// One event: its data lines joined by `\n`, its type (`message` unless named), and the stream's last event id and
/// reconnection time, which earlier events and blocks without data may have set. What it holds lives until the next
/// read.
pub const Event = struct {
    event: []const u8,
    data: []const u8,
    id: ?[]const u8 = null,
    retry: ?u64 = null,
};

/// Reads events from a body. A line break may be `\r\n`, `\n` or `\r`, and may be split across reads; a stream that
/// ends without its last blank line still gives its last event, as some servers close right after their last data.
pub const Reader = struct {
    source: *std.Io.Reader,
    allocator: Allocator,
    line: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    event: std.ArrayList(u8) = .empty,
    id: std.ArrayList(u8) = .empty,
    has_id: bool = false,
    retry: ?u64 = null,
    has_data: bool = false,
    /// A `\r` ended the last line, so a `\n` that follows is its line break's second half.
    after_return: bool = false,
    started: bool = false,
    ended: bool = false,
    /// An event was given, whose data and type the next read clears.
    given: bool = false,

    pub fn init(allocator: Allocator, source: *std.Io.Reader) Reader {
        return .{ .source = source, .allocator = allocator };
    }

    pub fn deinit(reader: *Reader) void {
        reader.line.deinit(reader.allocator);
        reader.data.deinit(reader.allocator);
        reader.event.deinit(reader.allocator);
        reader.id.deinit(reader.allocator);
    }

    /// The next event, or null at the end of the stream; `ReadFailed` where the body broke off.
    pub fn next(reader: *Reader) error{ ReadFailed, OutOfMemory }!?Event {
        if (reader.given) {
            reader.data.clearRetainingCapacity();
            reader.event.clearRetainingCapacity();
            reader.given = false;
        }
        while (!reader.ended) {
            const line = try reader.nextLine() orelse {
                reader.ended = true;
                return reader.dispatch();
            };
            if (line.len == 0) {
                if (reader.dispatch()) |event| return event;
            } else try reader.field(line);
        }
        return null;
    }

    /// The next line without its break; null at the end of the stream with nothing left.
    fn nextLine(reader: *Reader) error{ ReadFailed, OutOfMemory }!?[]const u8 {
        reader.line.clearRetainingCapacity();
        while (true) {
            if (reader.source.bufferedLen() == 0) {
                reader.source.fillMore() catch |err| switch (err) {
                    error.EndOfStream => return if (reader.line.items.len > 0) reader.firstStripped() else null,
                    error.ReadFailed => return error.ReadFailed,
                };
                continue;
            }
            const available = reader.source.buffered();
            if (reader.after_return) {
                reader.after_return = false;
                if (available[0] == '\n') reader.source.toss(1);
                continue;
            }
            const end = std.mem.indexOfAny(u8, available, "\r\n") orelse {
                try reader.line.appendSlice(reader.allocator, available);
                reader.source.toss(available.len);
                continue;
            };
            try reader.line.appendSlice(reader.allocator, available[0..end]);
            reader.after_return = available[end] == '\r';
            reader.source.toss(end + 1);
            return reader.firstStripped();
        }
    }

    /// The line read, without the byte order mark the stream's first may begin with.
    fn firstStripped(reader: *Reader) []const u8 {
        const line = reader.line.items;
        if (reader.started) return line;
        reader.started = true;
        return if (std.mem.startsWith(u8, line, "\xEF\xBB\xBF")) line[3..] else line;
    }

    fn field(reader: *Reader, line: []const u8) Allocator.Error!void {
        if (line[0] == ':') return;
        const colon = std.mem.indexOfScalar(u8, line, ':');
        const name = line[0 .. colon orelse line.len];
        var value: []const u8 = if (colon) |at| line[at + 1 ..] else "";
        if (value.len > 0 and value[0] == ' ') value = value[1..];
        if (std.mem.eql(u8, name, "data")) {
            if (reader.has_data) try reader.data.append(reader.allocator, '\n');
            try reader.data.appendSlice(reader.allocator, value);
            reader.has_data = true;
        } else if (std.mem.eql(u8, name, "event")) {
            reader.event.clearRetainingCapacity();
            try reader.event.appendSlice(reader.allocator, value);
        } else if (std.mem.eql(u8, name, "id") and std.mem.indexOfScalar(u8, value, 0) == null) {
            reader.id.clearRetainingCapacity();
            try reader.id.appendSlice(reader.allocator, value);
            reader.has_id = true;
        } else if (std.mem.eql(u8, name, "retry")) {
            reader.retry = std.fmt.parseInt(u64, value, 10) catch reader.retry;
        }
    }

    /// The event the lines since the last dispatch make, where they gave data; the event's type is reset either way,
    /// what an event holds at the next read, as clearing writes over it.
    fn dispatch(reader: *Reader) ?Event {
        if (!reader.has_data) {
            reader.event.clearRetainingCapacity();
            return null;
        }
        reader.has_data = false;
        reader.given = true;
        return .{
            .event = if (reader.event.items.len == 0) "message" else reader.event.items,
            .data = reader.data.items,
            .id = if (reader.has_id) reader.id.items else null,
            .retry = reader.retry,
        };
    }
};

/// The events of `chunks`, each as its type, a space, its data and its id.
fn eventsOf(allocator: Allocator, chunks: []const []const u8) ![]const []const u8 {
    var buffer: [64]u8 = undefined;
    var source: ChunkReader = .init(chunks, &buffer);
    var reader = Reader.init(allocator, &source.reader);
    defer reader.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    while (try reader.next()) |event| {
        try out.append(allocator, try std.fmt.allocPrint(allocator, "{s} {s}{s}", .{ event.event, event.data, if (event.id) |id| id else "" }));
    }
    return out.items;
}

test "events come as their blank lines arrive, whatever the reads split" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const events = try eventsOf(a, &.{ "\xEF\xBB\xBFevent: delta\nda", "ta: {\"a\":1}\r", "\n\r\n: a comment\ndata: one\ndata:two\n\n", "id: 7\nretry: 10\n\ndata: last" });
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqualStrings("delta {\"a\":1}", events[0]);
    try std.testing.expectEqualStrings("message one\ntwo", events[1]);
    // A block of id and retry alone gives no event, but the id is the stream's from then on.
    try std.testing.expectEqualStrings("message last7", events[2]);
}

test "a carriage return alone ends a line, and a stream without data gives no event" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const events = try eventsOf(a, &.{"data: a\r\rdata: b\r\r"});
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("message b", events[1]);
    try std.testing.expectEqual(@as(usize, 0), (try eventsOf(a, &.{ ": keep-alive\n\n", "event: ping\n\n" })).len);
}

/// Reads every event of a stream with `allocator`, then lets the reader go.
fn readEvents(allocator: Allocator) !void {
    var source: std.Io.Reader = .fixed("event: delta\ndata: one\ndata: two\nid: 7\n\ndata: three\n\n");
    var reader: Reader = .init(allocator, &source);
    defer reader.deinit();
    while (try reader.next()) |_| {}
}

test "a reader frees what it took where an allocation fails as it reads" {
    try @import("testing.zig").checkAllAllocationFailures(readEvents, .{});
}

test "a reader takes whatever stream it is given, and frees what it took" {
    try std.testing.fuzz({}, fuzzRead, .{ .corpus = &.{"event: delta\ndata: one\ndata: two\nid: 7\n\ndata: three\r\n\r\n"} });
}

/// Reads every event of whatever stream the fuzzer gives, then lets the reader go.
fn fuzzRead(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [4096]u8 = undefined;
    var source: std.Io.Reader = .fixed(buffer[0..smith.slice(&buffer)]);
    var reader: Reader = .init(std.testing.allocator, &source);
    defer reader.deinit();
    while (reader.next() catch return) |_| {}
}
