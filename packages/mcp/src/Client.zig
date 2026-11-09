//! The MCP client: it finds which protocol the server speaks and settles on a version, then sends each request and
//! waits for its answer on its caller's task — its progress, its time, which stops while its question waits for an
//! answer — answers the server's questions through the request's handler or the client's, or hands a stateless
//! server's back to the caller, and keeps what the server sends apart for whoever reads the client's events. Many
//! tasks may make requests at once. It never reconnects by itself.
const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const foundation = @import("foundation");
const jsonrpc = @import("jsonrpc.zig");
const protocol = @import("protocol.zig");
const types = @import("types.zig");
const results = @import("results.zig");
const headers_ = @import("headers.zig");
const failure_ = @import("failure.zig");
const Failure = failure_.Failure;
const Slot = failure_.Slot;
const Error = failure_.Error;
const transport_ = @import("transport.zig");
const Transport = transport_.Transport;
const requests = @import("client/requests.zig");
const answers = @import("client/answers.zig");
const subscriptions = @import("client/subscriptions.zig");
pub const Subscription = subscriptions.Subscription;

gpa: Allocator,
options: Options,
transport: Transport,
/// Guards what follows.
lock: std.Io.Mutex = .init,
next_id: i64 = 1,
state: State = .connecting,
/// What the client settled on with the server, in `lasting`.
settled: ?Settled = null,
lasting_arena: std.heap.ArenaAllocator,
/// The tools listed last, by name, for their headers and output schemas, in `known_arena`.
known: std.StringHashMapUnmanaged(Known) = .empty,
known_arena: std.heap.ArenaAllocator,
/// The requests in flight, whose time a question stops and whose handler answers it.
pending: std.ArrayList(*requests.Pending) = .empty,
roots: []const types.Root,
log_level: ?types.LoggingLevel = null,
/// What the server sent apart from any request, as JSON text, until the client's events are read.
events: std.ArrayList([]u8) = .empty,

pub const State = enum { connecting, connected, closed };

/// Answers an elicitation: shows the form or the link to the person, and gives back what they chose, in `arena`.
pub const ElicitHandler = struct {
    context: *anyopaque,
    answer: *const fn (context: *anyopaque, arena: Allocator, request: types.ElicitRequest) Allocator.Error!types.ElicitResult,
};

/// Takes each progress notification of a request.
pub const ProgressHandler = struct {
    context: *anyopaque,
    progressed: *const fn (context: *anyopaque, progress: types.Progress) void,
};

/// Takes the problems that fail no request, such as a tool left out for an invalid definition.
pub const Reporter = struct {
    context: *anyopaque,
    report: *const fn (context: *anyopaque, problem: []const u8) void,
};

pub const Options = struct {
    host: transport_.Host,
    /// The client's name and version, which every request names.
    client: types.Implementation,
    /// The elicitation modes the client offers, and the handler of an elicitation no request answers itself.
    elicitation: ?struct { form: bool = false, url: bool = false, handler: ?ElicitHandler = null } = null,
    /// The roots the client offers, which offers roots at all; `setRoots` changes them. They outlive the client.
    roots: ?[]const types.Root = null,
    /// How long a request waits for its answer, its time stopped while its question waits for one.
    timeout_ms: u64 = protocol.timeout_ms,
    /// How long `server/discover` waits before the server is taken for a session-based one.
    probe_timeout_ms: u64 = protocol.probe_timeout_ms,
    reporter: ?Reporter = null,
};

pub const RequestOptions = struct {
    /// In place of the client's `timeout_ms`.
    timeout_ms: ?u64 = null,
    /// Asks for progress notifications and takes each one.
    progress: ?ProgressHandler = null,
    /// Whether a progress notification starts the time again; `max_total_timeout_ms` bounds the whole request still.
    reset_timeout_on_progress: bool = false,
    max_total_timeout_ms: ?u64 = null,
    /// Answers the elicitations this request brings, in place of the client's handler.
    elicit: ?ElicitHandler = null,
    /// Hands a stateless server's elicitations back, failing `input_required`, in place of answering them, so that
    /// the caller keeps them past its process; a session-based server's go to `elicit` still.
    hand_back_input: bool = false,
    /// Sends the request with the answers to the questions a stateless server handed back, and its `requestState`.
    answered: ?types.InputAnswers = null,
};

/// What the client settled on: the server's era, version, capabilities, name and instructions.
pub const Settled = struct {
    era: protocol.Era,
    version: []const u8,
    capabilities: Value,
    server: ?types.Implementation = null,
    instructions: ?[]const u8 = null,
};

/// A listed tool, for its `x-mcp-header` annotations and output schema.
pub const Known = struct { headers: []const headers_.ParamHeader, output_schema: ?Value };

/// A client connected, or the failure it could not connect with.
pub const Connected = union(enum) {
    client: *Client,
    failed: Failure,
};

/// Connects over `transport`, which it owns from here, and settles on a protocol: `server/discover` first, as the
/// current specification has it; a server that answers with anything but a discovery result or an error only a
/// stateless server gives is taken for a session-based one, and initialized. Its failure lives in `arena`.
pub fn connect(gpa: Allocator, arena: Allocator, options: Options, transport: Transport) Allocator.Error!Connected {
    const client = gpa.create(Client) catch |err| {
        transport.close();
        return err;
    };
    errdefer gpa.destroy(client);
    client.* = .{ .gpa = gpa, .options = options, .transport = transport, .lasting_arena = .init(gpa), .known_arena = .init(gpa), .roots = options.roots orelse &.{} };
    errdefer client.release();
    var slot: Slot = .{ .arena = arena };
    requests.settle(client, &slot) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => {
            client.deinit();
            return .{ .failed = slot.failure.? };
        },
    };
    client.lock.lockUncancelable(options.host.io);
    defer client.lock.unlock(options.host.io);
    if (client.state == .connecting) client.state = .connected;
    return .{ .client = client };
}

/// Closes the transport, if it is open, and lets the client go; nothing may be asked of it from then on.
pub fn deinit(client: *Client) void {
    client.release();
    client.gpa.destroy(client);
}

/// Lets go of what the client holds, its transport closed, the client itself kept.
fn release(client: *Client) void {
    client.transport.close();
    for (client.events.items) |event| client.gpa.free(event);
    client.events.deinit(client.gpa);
    client.pending.deinit(client.gpa);
    client.known.deinit(client.gpa);
    client.known_arena.deinit();
    client.lasting_arena.deinit();
}

pub fn era(client: *Client) ?protocol.Era {
    client.lock.lockUncancelable(client.options.host.io);
    defer client.lock.unlock(client.options.host.io);
    return if (client.settled) |settled| settled.era else null;
}

/// What the client settled on, once connected; it lives as long as the client.
pub fn server(client: *Client) ?Settled {
    client.lock.lockUncancelable(client.options.host.io);
    defer client.lock.unlock(client.options.host.io);
    return client.settled;
}

/// How the client stands: closed as soon as its transport is — its server gone — whether or not anything read it yet.
pub fn currentState(client: *Client) State {
    client.lock.lockUncancelable(client.options.host.io);
    defer client.lock.unlock(client.options.host.io);
    if (client.state != .closed and client.transport.isClosed()) client.state = .closed;
    return client.state;
}

/// One page of the server's tools; a tool whose `x-mcp-header` annotations are invalid is left out and reported.
pub fn listTools(client: *Client, arena: Allocator, cursor: ?[]const u8, options: RequestOptions) Allocator.Error!failure_.Outcome(types.Page(types.Tool)) {
    var slot: Slot = .{ .arena = arena };
    return outcome(types.Page(types.Tool), &slot, requests.listTools(client, &slot, cursor, options));
}

/// Every page of the server's tools.
pub fn allTools(client: *Client, arena: Allocator, options: RequestOptions) Allocator.Error!failure_.Outcome([]const types.Tool) {
    var slot: Slot = .{ .arena = arena };
    return outcome([]const types.Tool, &slot, requests.allPages(types.Tool, client, &slot, options, requests.listTools));
}

/// Calls a tool, its structured content checked against the output schema of a tool the client listed; the input
/// the server asks for on the way goes to `options.elicit` or the client's handler.
pub fn callTool(client: *Client, arena: Allocator, name: []const u8, arguments: ?Value, options: RequestOptions) Allocator.Error!failure_.Outcome(types.CallToolResult) {
    var slot: Slot = .{ .arena = arena };
    return outcome(types.CallToolResult, &slot, requests.callTool(client, &slot, name, arguments, options));
}

pub fn listResources(client: *Client, arena: Allocator, cursor: ?[]const u8, options: RequestOptions) Allocator.Error!failure_.Outcome(types.Page(types.Resource)) {
    var slot: Slot = .{ .arena = arena };
    return outcome(types.Page(types.Resource), &slot, requests.listed(types.Resource, client, &slot, "resources/list", "resources", cursor, options));
}

pub fn listResourceTemplates(client: *Client, arena: Allocator, cursor: ?[]const u8, options: RequestOptions) Allocator.Error!failure_.Outcome(types.Page(types.ResourceTemplate)) {
    var slot: Slot = .{ .arena = arena };
    return outcome(types.Page(types.ResourceTemplate), &slot, requests.listed(types.ResourceTemplate, client, &slot, "resources/templates/list", "resourceTemplates", cursor, options));
}

pub fn readResource(client: *Client, arena: Allocator, uri: []const u8, options: RequestOptions) Allocator.Error!failure_.Outcome(types.ReadResourceResult) {
    var slot: Slot = .{ .arena = arena };
    return outcome(types.ReadResourceResult, &slot, requests.readResource(client, &slot, uri, options));
}

pub fn listPrompts(client: *Client, arena: Allocator, cursor: ?[]const u8, options: RequestOptions) Allocator.Error!failure_.Outcome(types.Page(types.Prompt)) {
    var slot: Slot = .{ .arena = arena };
    return outcome(types.Page(types.Prompt), &slot, requests.listed(types.Prompt, client, &slot, "prompts/list", "prompts", cursor, options));
}

/// A prompt, its arguments filled in.
pub fn getPrompt(client: *Client, arena: Allocator, name: []const u8, arguments: []const [2][]const u8, options: RequestOptions) Allocator.Error!failure_.Outcome(types.GetPromptResult) {
    var slot: Slot = .{ .arena = arena };
    return outcome(types.GetPromptResult, &slot, requests.getPrompt(client, &slot, name, arguments, options));
}

/// The values the server completes an argument of a prompt or a resource template with.
pub fn complete(client: *Client, arena: Allocator, reference: types.CompletionReference, argument: [2][]const u8, context: []const [2][]const u8, options: RequestOptions) Allocator.Error!failure_.Outcome(types.CompleteResult) {
    var slot: Slot = .{ .arena = arena };
    return outcome(types.CompleteResult, &slot, requests.complete(client, &slot, reference, argument, context, options));
}

/// The lowest level of the log messages the server sends: with `logging/setLevel` to a session-based server, and on
/// every later request to a stateless one.
pub fn setLoggingLevel(client: *Client, arena: Allocator, level: types.LoggingLevel) Allocator.Error!failure_.Outcome(void) {
    var slot: Slot = .{ .arena = arena };
    return outcome(void, &slot, requests.setLoggingLevel(client, &slot, level));
}

/// Checks that a session-based server answers; the stateless protocol has no `ping`.
pub fn ping(client: *Client, arena: Allocator, options: RequestOptions) Allocator.Error!failure_.Outcome(void) {
    var slot: Slot = .{ .arena = arena };
    return outcome(void, &slot, requests.ping(client, &slot, options));
}

/// Changes the roots the client offers, which outlive the client; a session-based server is told they changed.
pub fn setRoots(client: *Client, arena: Allocator, roots: []const types.Root) Allocator.Error!failure_.Outcome(void) {
    var slot: Slot = .{ .arena = arena };
    return outcome(void, &slot, requests.setRoots(client, &slot, roots));
}

/// Opens a subscription to the changes `filter` asks for, which its `next` then brings; the caller closes it.
pub fn listen(client: *Client, arena: Allocator, filter: types.SubscriptionFilter) Allocator.Error!failure_.Outcome(*Subscription) {
    var slot: Slot = .{ .arena = arena };
    return outcome(*Subscription, &slot, subscriptions.listen(client, &slot, filter));
}

/// What the client's events are: what the server sends apart from any request.
pub const Event = answers.Event;

/// The next of the client's events, in `arena`, waiting at most `wait_ms`: null where none came within it, or the
/// connection closed.
pub fn nextEvent(client: *Client, arena: Allocator, wait_ms: ?u64) Allocator.Error!?Event {
    return answers.nextEvent(client, arena, wait_ms);
}

/// What `made` came to: what it made, or the failure the slot holds.
fn outcome(comptime T: type, slot: *Slot, made: Error!T) Allocator.Error!failure_.Outcome(T) {
    const done = made catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return .{ .failed = slot.failure.? },
    };
    return .{ .done = done };
}

/// The next request's id.
pub fn nextId(client: *Client) i64 {
    client.lock.lockUncancelable(client.options.host.io);
    defer client.lock.unlock(client.options.host.io);
    defer client.next_id += 1;
    return client.next_id;
}

pub fn report(client: *Client, problem: []const u8) void {
    if (client.options.reporter) |reporter| reporter.report(reporter.context, problem);
}
