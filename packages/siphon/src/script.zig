//! Scripts: TypeScript run on QuickJS — the whole language it gives, its parser reading TypeScript's types and skipping
//! them — each on an engine of its own, with the host's functions under a global object it names, a call of one a
//! promise the host settles; bounded by steps and memory, its clocks and its random numbers the host's, so a replay runs
//! alike.
const engine = @import("script/engine.zig");
pub const Script = engine.Script;
pub const Status = engine.Status;
pub const Start = engine.Start;
pub const Limits = engine.Limits;
pub const Call = engine.Call;
pub const Result = engine.Result;

test {
    _ = engine;
}
