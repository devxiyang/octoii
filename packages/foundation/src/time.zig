//! Time as a part takes it from its host: the clock and the waits are the io's by default, and a host, or a test that
//! sets the time, gives its own in their place.
const std = @import("std");

/// A clock in place of the io's.
pub const Clock = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Milliseconds since the epoch.
        now_ms: *const fn (context: *anyopaque) i64,
    };

    pub fn nowMs(clock: Clock) i64 {
        return clock.vtable.now_ms(clock.context);
    }
};

/// A way of waiting in place of the io's sleep.
pub const Sleeper = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Returns once `ms` have passed; `Canceled` where the host cancels the wait.
        sleep: *const fn (context: *anyopaque, ms: u64) error{Canceled}!void,
    };

    pub fn sleep(sleeper: Sleeper, ms: u64) error{Canceled}!void {
        return sleeper.vtable.sleep(sleeper.context, ms);
    }
};

/// The milliseconds since the epoch on `clock`, else on the io's real clock.
pub fn nowMs(io: std.Io, clock: ?Clock) i64 {
    if (clock) |given| return given.nowMs();
    return std.Io.Clock.real.now(io).toMilliseconds();
}

/// Waits `ms` on `sleeper`, else on the io's sleep.
pub fn sleep(io: std.Io, sleeper: ?Sleeper, ms: u64) error{Canceled}!void {
    if (sleeper) |given| return given.sleep(ms);
    return io.sleep(.fromMilliseconds(@intCast(ms)), .awake);
}
