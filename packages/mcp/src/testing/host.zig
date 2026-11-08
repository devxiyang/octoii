//! A host for tests: a clock they set, waits that pass at once and move it on, and randomness from a seed.
const std = @import("std");
const transport = @import("../transport.zig");

pub const Host = struct {
    clock_ms: i64 = 1_793_275_200_000,
    prng: std.Random.DefaultPrng = .init(7),

    /// The host as a client takes it.
    pub fn host(test_host: *Host) transport.Host {
        return .{
            .io = std.testing.io,
            .clock = .{ .context = test_host, .vtable = &.{ .now_ms = nowMs } },
            .sleeper = .{ .context = test_host, .vtable = &.{ .sleep = sleep } },
            .random = test_host.prng.random(),
        };
    }

    fn of(context: *anyopaque) *Host {
        return @ptrCast(@alignCast(context));
    }

    fn nowMs(context: *anyopaque) i64 {
        return of(context).clock_ms;
    }

    /// A wait passes at once, the clock moved on by it.
    fn sleep(context: *anyopaque, ms: u64) error{Canceled}!void {
        of(context).clock_ms += @intCast(ms);
    }
};
