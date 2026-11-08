//! What a request used, in one form for every kind: meters, each counting a share no other counts but `reasoning`,
//! which is a share of `output`, and the cost in US dollars. A meter left out counts nothing; a cost left out is
//! unknown, never zero.
const std = @import("std");
const response = @import("response.zig");
const extensions = @import("extensions.zig");

pub const Usage = struct {
    /// Tokens read, neither from the prompt cache nor into it.
    input: ?u64 = null,
    /// Tokens read from the prompt cache.
    cache_read: ?u64 = null,
    /// Tokens of audio read from the prompt cache, where the provider prices them apart.
    cache_read_audio: ?u64 = null,
    /// Tokens written into the prompt cache, kept for minutes.
    cache_write: ?u64 = null,
    /// Tokens written into the prompt cache, kept for an hour or longer.
    cache_write_long: ?u64 = null,
    /// Tokens written, reasoning among them.
    output: ?u64 = null,
    /// Of `output`, the tokens spent reasoning.
    reasoning: ?u64 = null,
    /// Tokens of audio read, where the provider counts and prices them apart.
    input_audio: ?u64 = null,
    /// Tokens of audio made, likewise.
    output_audio: ?u64 = null,
    /// Tokens of images read, likewise.
    input_image: ?u64 = null,
    /// Tokens of images made, likewise.
    output_image: ?u64 = null,
    /// Seconds of audio read, of a session, or of video made.
    seconds: ?f64 = null,
    /// Characters of text spoken.
    characters: ?u64 = null,
    /// Images read, counted one by one where the provider bills them so.
    images_read: ?u64 = null,
    /// Images made, likewise.
    images_made: ?u64 = null,
    /// Searches the provider ran.
    web_searches: ?u64 = null,
    /// What the request cost in US dollars.
    cost: ?f64 = null,

    /// A text response's meters, and its cost where the provider said it: of the usage's tokens, each share its
    /// `octoii` counts apart is taken from the count it is part of, so that no token is counted twice. A response
    /// without usage used nothing known.
    pub fn ofResponse(answer: response.Response) Usage {
        const reported = answer.usage orelse return .{};
        const shares: extensions.UsageExtension = reported.octoii orelse .{};
        const cache_read_audio = shares.cache_read_audio_tokens orelse 0;
        const cache_write_long = shares.cache_write_long_tokens orelse 0;
        const input_audio = shares.input_audio_tokens orelse 0;
        const input_image = shares.input_image_tokens orelse 0;
        const output_image = shares.output_image_tokens orelse 0;
        const cached = reported.input_tokens_details.cached_tokens;
        const written = reported.input_tokens_details.cache_write_tokens orelse 0;
        const searches = if (reported.server_tool_use_details) |details| details.web_search_requests orelse 0 else 0;
        // A provider whose shares exceed the count they are part of has miscounted; no meter goes below nothing.
        return .{
            .input = counted(reported.input_tokens -| cached -| written -| input_audio -| input_image),
            .cache_read = counted(cached -| cache_read_audio),
            .cache_read_audio = counted(cache_read_audio),
            .cache_write = counted(written -| cache_write_long),
            .cache_write_long = counted(cache_write_long),
            .output = counted(reported.output_tokens -| output_image),
            .reasoning = counted(reported.output_tokens_details.reasoning_tokens),
            .input_audio = counted(input_audio),
            .input_image = counted(input_image),
            .output_image = counted(output_image),
            .web_searches = counted(searches),
            .cost = reported.cost,
        };
    }

    /// The tokens of input `usage` counts, cached ones among them: the input of its request, for a caller that has
    /// no count of that request alone, or of all its requests where it adds several.
    pub fn inputTokens(usage: Usage) u64 {
        var total: u64 = 0;
        inline for (.{ "input", "cache_read", "cache_read_audio", "cache_write", "cache_write_long", "input_audio", "input_image" }) |meter| {
            total += @field(usage, meter) orelse 0;
        }
        return total;
    }

    /// `a` and `b` added meter by meter, and their costs where either is known.
    pub fn add(a: Usage, b: Usage) Usage {
        var sum: Usage = .{};
        const meters = @typeInfo(Usage).@"struct";
        inline for (meters.field_names, meters.field_types) |name, Meter| {
            @field(sum, name) = addMeter(@typeInfo(Meter).optional.child, @field(a, name), @field(b, name));
        }
        return sum;
    }
};

/// A count, or none where it is nothing.
fn counted(amount: u64) ?u64 {
    return if (amount > 0) amount else null;
}

/// Two meters added, left out where both are.
fn addMeter(comptime T: type, a: ?T, b: ?T) ?T {
    if (a == null and b == null) return null;
    return (a orelse 0) + (b orelse 0);
}

test "a response's usage takes each share apart from the count it is part of" {
    const usage = Usage.ofResponse(.{
        .id = "r",
        .status = .completed,
        .output = &.{},
        .usage = .{
            .input_tokens = 1000,
            .input_tokens_details = .{ .cached_tokens = 600, .cache_write_tokens = 300 },
            .output_tokens = 120,
            .output_tokens_details = .{ .reasoning_tokens = 80 },
            .total_tokens = 1120,
            .server_tool_use_details = .{ .web_search_requests = 2 },
            .octoii = .{ .cache_write_long_tokens = 100, .input_image_tokens = 50 },
        },
    });
    try std.testing.expectEqual(Usage{
        .input = 50,
        .cache_read = 600,
        .cache_write = 200,
        .cache_write_long = 100,
        .output = 120,
        .reasoning = 80,
        .input_image = 50,
        .web_searches = 2,
    }, usage);
    try std.testing.expectEqual(@as(u64, 1000), usage.inputTokens());
}

test "a miscounted share takes its count to nothing, and a response without usage used nothing" {
    const usage = Usage.ofResponse(.{
        .id = "r",
        .status = .completed,
        .output = &.{},
        .usage = .{
            .input_tokens = 10,
            .input_tokens_details = .{ .cached_tokens = 20 },
            .output_tokens = 0,
            .output_tokens_details = .{ .reasoning_tokens = 0 },
            .total_tokens = 10,
            .cost = 0.5,
        },
    });
    try std.testing.expectEqual(Usage{ .cache_read = 20, .cost = 0.5 }, usage);
    try std.testing.expectEqual(Usage{}, Usage.ofResponse(.{ .id = "r", .status = .failed, .output = &.{} }));
}

test "usage adds meter by meter, and a cost where either knows it" {
    const sum = Usage.add(.{ .input = 3, .seconds = 1.5 }, .{ .input = 4, .output = 2, .cost = 0.25 });
    try std.testing.expectEqual(Usage{ .input = 7, .output = 2, .seconds = 1.5, .cost = 0.25 }, sum);
    try std.testing.expectEqual(Usage{}, Usage.add(.{}, .{}));
}
