//! The agent: a thread's main fiber and its turns, as fibers, and the model each turn asks — what it is told of itself,
//! its work and its tools, the skills it may use, and its conversation, compacted where it grows past what the model
//! takes — the title the model gives a thread, the sub-threads it delegates to where the person asks, and the second
//! model that judges its calls in auto.
pub const skills = @import("agent/skills.zig");
pub const system = @import("agent/system.zig");
pub const compaction = @import("agent/compaction.zig");
pub const compacting = @import("agent/compacting.zig");
pub const context = @import("agent/context.zig");
pub const models = @import("agent/models.zig");
pub const turn = @import("agent/turn.zig");
pub const thread = @import("agent/thread.zig");
pub const title = @import("agent/title.zig");
pub const delegate = @import("agent/delegate.zig");
pub const resume_ = @import("agent/resume.zig");
pub const review = @import("agent/review.zig");

test {
    _ = skills;
    _ = system;
    _ = compaction;
    _ = compacting;
    _ = context;
    _ = models;
    _ = turn;
    _ = thread;
    _ = title;
    _ = delegate;
    _ = resume_;
    _ = review;
}
