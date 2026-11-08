//! Siphon's runtime, its kernel: the volume and the loop that serves it, the programs its fibers run, their phases, and
//! the requests they make, and the volume's collection as it grows — what every other part of Siphon stands on, knowing
//! nothing of any of them.
pub const Runtime = @import("runtime/Runtime.zig");
pub const Phase = @import("runtime/Phase.zig");
pub const Request = @import("runtime/Request.zig");
pub const Changes = @import("runtime/Changes.zig");
pub const Waits = @import("runtime/Waits.zig");
pub const Task = @import("runtime/Task.zig");
pub const Completion = @import("runtime/Completion.zig");
pub const Streams = @import("runtime/Streams.zig");
pub const Collection = @import("runtime/Collection.zig");
pub const Host = Runtime.Host;
pub const Device = Runtime.Device;
pub const Program = Runtime.Program;
pub const Work = Runtime.Work;
pub const Listener = Runtime.Listener;

test {
    _ = Runtime;
    _ = Phase;
    _ = Request;
    _ = Changes;
    _ = Waits;
    _ = Task;
    _ = Completion;
    _ = Streams;
    _ = Collection;
}
