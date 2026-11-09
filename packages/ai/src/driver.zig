//! The seam between `Models` and a driver, and what the host gives them both. `Models` finds a request's model,
//! checks the request against it, prepares it and makes the driver's stream whole; a driver does what only its
//! provider's API decides, through the `Call` it is given.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const http = foundation.http;
const vocabulary = @import("vocabulary");
const failure_ = @import("failure.zig");
const Failure = failure_.Failure;
const Error = failure_.Error;
const Model = @import("catalogue/model.zig").Model;
const ModelFacts = @import("catalogue/facts.zig").ModelFacts;
const Kind = @import("catalogue/model.zig").Kind;
const realtime_session = @import("wire/realtime/session.zig");

/// The code that speaks one provider's API: its id and name, the catalogue its models come from, and its calls.
pub const Driver = struct {
    /// Such as "anthropic": the key of its provider options and provider metadata.
    id: []const u8,
    /// What a driver of the host's own keeps for its calls, which read it from their provider's driver.
    context: ?*anyopaque = null,
    /// For people, such as "Anthropic".
    name: []const u8,
    /// The agent its provider is reached through, signed in to on its own, such as "Claude Code"; none for one the host
    /// reaches itself.
    through: ?[]const u8 = null,
    /// The driver whose catalogue entries its models take, such as "anthropic"; none, none.
    catalogue: ?[]const u8 = null,
    /// Whether the provider metadata it writes on an item holds for every model its providers serve, as metadata that
    /// names a session of its own does, rather than for the model that wrote the item alone, as a signature does.
    metadata_across_models: bool = false,
    /// Streams the response to a text request `Models` has checked against `model` and prepared for it.
    text: ?TextCall = null,
    /// Streams the images of an image request.
    image: ?ImageCall = null,
    /// Streams the audio of a speech request.
    speech: ?SpeechCall = null,
    /// Streams the transcript of a transcription request.
    transcription: ?TranscriptionCall = null,
    /// Makes videos as jobs.
    video: ?VideoCalls = null,
    /// Answers the questions of a decisions request.
    decision: ?DecisionCall = null,
    /// Makes and removes voices for the account.
    voices: ?VoiceCalls = null,
    realtime: ?RealtimeCalls = null,
    /// Lists the models the provider serves now, for a driver whose models are not the catalogue's.
    list: ?ListCall = null,
    /// Says how the provider stands; none, it is connected where the host keeps a credential for it.
    status: ?StatusCall = null,
    /// Begins a sign-in in a browser, for a driver whose provider is reached by one.
    sign_in: ?SignInCall = null,
    /// Lets go of what the provider keeps of a conversation that ended, for a driver whose provider keeps one.
    forget: ?ForgetCall = null,
    /// The settings an account the person added of a provider is reached with, for a driver whose accounts are reached
    /// apart; none, the provider's own.
    instance: ?InstanceCall = null,

    /// The kinds of the calls it serves.
    pub fn kinds(driver: *const Driver, arena: Allocator) Allocator.Error![]const Kind {
        var served: std.ArrayList(Kind) = .empty;
        if (driver.text != null) try served.append(arena, .text);
        if (driver.image != null) try served.append(arena, .image);
        if (driver.speech != null) try served.append(arena, .speech);
        if (driver.transcription != null) try served.append(arena, .transcription);
        if (driver.video != null) try served.append(arena, .video);
        if (driver.decision != null) try served.append(arena, .decision);
        if (driver.realtime != null) try served.append(arena, .@"realtime-transcription");
        return served.items;
    }
};

/// A driver's listing: the models its provider serves now, in `call`'s arena.
pub const ListCall = *const fn (call: *Call) Error![]const ModelFacts;

/// A driver's account of how its provider stands.
pub const StatusCall = *const fn (call: *Call) Error!Status;

/// A driver's letting go of a conversation that ended, by the key its requests named it with: their `prompt_cache_key`.
pub const ForgetCall = *const fn (call: *Call, conversation: []const u8) Error!void;

/// The settings the account `account` — its id — that a person added of a provider of `base` is reached with, in
/// `arena`.
pub const InstanceCall = *const fn (arena: Allocator, account: []const u8, base: Settings) Allocator.Error!Settings;

/// How a provider stands: whether a request may reach it now, who it is connected as, and what is wrong.
pub const Status = struct {
    connected: bool,
    /// Who it is connected as, where the driver knows, such as an email.
    account: ?[]const u8 = null,
    /// What is wrong, in words for the person, where it is not connected.
    problem: ?[]const u8 = null,
    /// How much of each of its plan's limits is used, where the provider tells.
    limits: []const Limit = &.{},
};

/// One of a plan's limits, as its provider tells how much of it is used: how long its window lasts, in minutes — 300
/// for five hours, 10080 for a week — the models it is of, where it is of some alone, such as "Opus"; how much of it is
/// used, in percent, and when it is given again, in milliseconds since the epoch, each where the provider says.
pub const Limit = struct { window_minutes: u32, scope: ?[]const u8 = null, used_percent: ?f64 = null, resets_at_ms: ?i64 = null };

/// What a sign-in in a browser takes.
pub const SignInOptions = struct {
    /// A loopback address on this machine, such as "http://127.0.0.1:1455/auth/callback".
    redirect_uri: []const u8,
    /// The app's name, offered to the person when the app is registered for them.
    agent_name_hint: []const u8,
};

/// A sign-in under way: where the person signs in, and the attempt its end needs, which lives in the arena its call
/// began in.
pub const SignIn = struct {
    url: []const u8,
    attempt: *anyopaque,
    /// Ends the sign-in from the address the browser was sent back to, or the one the person copied from its address
    /// bar, storing the credential; or `Failed`, with the failure left in `call`.
    finish: *const fn (call: *Call, attempt: *anyopaque, redirect: []const u8) Error!void,
};

/// A driver's sign-in: the address where the person signs in, and how it ends.
pub const SignInCall = *const fn (call: *Call, options: SignInOptions) Error!SignIn;

/// A driver's text call: the provider's stream of the request, begun; or `Failed`, with the failure left in `call`.
pub const TextCall = *const fn (call: *Call, model: *const Model, request: *const vocabulary.ResponsesRequest) Error!TextSource;

/// A provider's events of one request, in the vocabulary, as its stream gives them. `next` gives null at the
/// stream's end, or `Failed` with the failure left in its call; `close` lets it go, read to its end or not.
pub fn Source(comptime Event: type) type {
    return struct {
        context: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            next: *const fn (context: *anyopaque) Error!?Event,
            close: *const fn (context: *anyopaque) void,
        };

        pub fn next(source: @This()) Error!?Event {
            return source.vtable.next(source.context);
        }

        pub fn close(source: @This()) void {
            source.vtable.close(source.context);
        }
    };
}

/// The events of one text response.
pub const TextSource = Source(vocabulary.ResponseStreamEvent);

/// The events of one image request.
pub const ImageSource = Source(vocabulary.images.ImageStreamEvent);

/// The events of one speech request.
pub const SpeechSource = Source(vocabulary.speech.SpeechStreamEvent);

/// A driver's speech call: the provider's stream of the audio of a checked speech request, its stored samples read,
/// ending with `speech.audio.done`.
pub const SpeechCall = *const fn (call: *Call, model: *const Model, request: *const vocabulary.speech.SpeechRequest) Error!SpeechSource;

/// The events of one transcription request.
pub const TranscriptionSource = Source(vocabulary.transcriptions.TranscriptionStreamEvent);

/// A driver's transcription call: the provider's stream of the transcript of a checked request, its stored recording
/// read, ending with `transcript.text.done`.
pub const TranscriptionCall = *const fn (call: *Call, model: *const Model, request: *const vocabulary.transcriptions.TranscriptionRequest) Error!TranscriptionSource;

/// A driver's video calls: a job made of a checked request, how a job stands, and one of a completed job's outputs.
pub const VideoCalls = struct {
    /// The job the provider took for `request`, its stored references read.
    create: *const fn (call: *Call, model: *const Model, request: *const vocabulary.videos.VideoRequest) Error!vocabulary.videos.VideoJob,
    /// How the job `id` stands now.
    retrieve: *const fn (call: *Call, model: *const Model, id: []const u8) Error!vocabulary.videos.VideoJob,
    /// The output at `index` of the completed job `id`.
    download: *const fn (call: *Call, model: *const Model, id: []const u8, index: u32) Error!vocabulary.videos.VideoContent,
};

/// A driver's decision call: the answers to a checked request's questions, its media read.
pub const DecisionCall = *const fn (call: *Call, model: *const Model, request: *const vocabulary.decisions.DecisionsRequest) Error!vocabulary.decisions.DecisionsResponse;

/// A driver's voice calls: voices made and removed for the account, and the consents it asks for first.
pub const VoiceCalls = struct {
    /// The id of the voice made from `params`, its stored sample read.
    create: *const fn (call: *Call, params: *const vocabulary.voices.VoiceCreateParams) Error![]const u8,
    /// Removes the voice `id`.
    delete: *const fn (call: *Call, id: []const u8) Error!void,
    /// The id of the consent recorded from `params`, its stored recording read; none for a provider that asks none.
    create_consent: ?*const fn (call: *Call, params: *const vocabulary.voices.VoiceConsentCreateParams) Error![]const u8 = null,
};

/// A driver's image call: the provider's stream of the images of a request `Models` has checked against `model`, its
/// stored references read, ending with the last `image_generation.completed`.
/// A driver's realtime transcription: the socket a session opens and how it speaks over it, the sideband of a session
/// a client made by WebRTC, and such a session made for a client.
pub const RealtimeCalls = struct {
    /// The opening of a session of `session`; its wire keeps what changes as the session goes in `gpa`.
    connect: *const fn (call: *Call, model: *const Model, session: *const vocabulary.realtime.Session, gpa: Allocator) Error!RealtimeOpening,
    /// The opening of the sideband of the call `call_id`, which sends no audio.
    connect_sideband: ?*const fn (call: *Call, model: *const Model, call_id: []const u8, gpa: Allocator) Error!RealtimeOpening = null,
    /// A session made for a client from its offer: its call's id and the answer for the client.
    create_call: ?*const fn (call: *Call, model: *const Model, params: *const vocabulary.realtime.CallCreateParams) Error!vocabulary.realtime.CallCreateResponse = null,
};

/// Where a realtime session's socket opens, with which headers, and how the session speaks over it.
pub const RealtimeOpening = struct {
    url: []const u8,
    headers: []const http.Header,
    wire: realtime_session.Wire,
};

pub const ImageCall = *const fn (call: *Call, model: *const Model, request: *const vocabulary.images.ImageRequest) Error!ImageSource;

/// What a host connects and a person pays: a driver with its settings, its credential kept under its id, and the
/// models the person gave it. One driver serves any number of providers.
pub const Provider = struct {
    /// The first part of its models' references, and the key of its credential, such as "openai-work".
    id: []const u8,
    /// For people, such as "OpenAI (work)".
    name: []const u8,
    driver: *const Driver,
    settings: Settings = .{},
    /// What the person knows of models it serves: those it does not list join them, and those it lists take the
    /// facts the person gives where their catalogue and listing give none.
    models: []const ModelFacts = &.{},
};

/// What a provider sets of its driver: where it reaches its API, and headers sent with each of its requests.
pub const Settings = struct {
    /// The address its API's paths follow, without a trailing `/`; none, the driver's own.
    base_url: ?[]const u8 = null,
    /// Sent with each of its requests over the driver's own of the same name, such as a proxy's key.
    headers: []const http.Header = &.{},
};

/// What a provider is reached with: an API key, a sign-in by OAuth, or nothing, for a server that takes no credential.
pub const Credential = union(enum) {
    api_key: []const u8,
    oauth: OAuth,
    none,

    /// Whether it can authorize a request: all but a sign-in that holds a registered client and no tokens yet.
    pub fn usable(credential: Credential) bool {
        return credential != .oauth or credential.oauth.tokens != null;
    }
};

/// A sign-in by OAuth, as the host keeps it.
pub const OAuth = struct {
    issuer: []const u8,
    /// The client issued to this app for the person at their first sign-in, kept and reused.
    client_id: []const u8,
    /// This host's id for the sign-in, chosen once, which the issuer ties the sign-in to.
    host_id: ?[]const u8 = null,
    /// Who signed in, from the verified ID token.
    subject: ?[]const u8 = null,
    email: ?[]const u8 = null,
    tokens: ?struct {
        access: []const u8,
        refresh: ?[]const u8 = null,
        /// When the access token expires, in ms since the epoch.
        expires_at_ms: i64,
        scopes: []const []const u8,
    } = null,
};

/// The host's store of credentials, by provider id.
pub const Credentials = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The provider's credential, in `arena`; null where the host keeps none.
        read: *const fn (context: *anyopaque, arena: Allocator, provider: []const u8) error{ Unavailable, OutOfMemory }!?Credential,
        /// Reads the provider's credential, gives it to `change` and stores what `change` makes of it, null leaving it
        /// as it is; one change of a provider's credential at a time, across processes where the store can hold a
        /// lock. The credential stored after, in `arena`; `Failed` where `change` failed, storing nothing.
        modify: *const fn (context: *anyopaque, arena: Allocator, provider: []const u8, change: Change) ModifyError!?Credential,
        /// Forgets the provider's credential the store keeps; one the host reads elsewhere, as from its environment,
        /// is read as before.
        remove: *const fn (context: *anyopaque, provider: []const u8) error{Unavailable}!void,
    };

    pub const ModifyError = error{ Unavailable, OutOfMemory, Failed };

    /// A change of a credential, made inside the store's lock.
    pub const Change = struct {
        context: *anyopaque,
        apply: *const fn (context: *anyopaque, arena: Allocator, current: ?Credential) Error!?Credential,
    };

    pub fn read(credentials: Credentials, arena: Allocator, provider: []const u8) error{ Unavailable, OutOfMemory }!?Credential {
        return credentials.vtable.read(credentials.context, arena, provider);
    }

    pub fn modify(credentials: Credentials, arena: Allocator, provider: []const u8, change: Change) ModifyError!?Credential {
        return credentials.vtable.modify(credentials.context, arena, provider, change);
    }

    pub fn remove(credentials: Credentials, provider: []const u8) error{Unavailable}!void {
        return credentials.vtable.remove(credentials.context, provider);
    }
};

/// The host's stored files, by reference.
pub const Files = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The bytes of the stored file `ref`, in `arena`.
        read: *const fn (context: *anyopaque, arena: Allocator, ref: []const u8) error{ NotFound, Unavailable, OutOfMemory }![]const u8,
    };

    pub fn read(files: Files, arena: Allocator, ref: []const u8) error{ NotFound, Unavailable, OutOfMemory }![]const u8 {
        return files.vtable.read(files.context, arena, ref);
    }
};

/// Where ids come from: UUIDs of version 7 as text, each later than the one before.
pub const Mint = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        mint: *const fn (context: *anyopaque) [36]u8,
    };

    pub fn next(mint: Mint) [36]u8 {
        return mint.vtable.mint(mint.context);
    }
};

/// What the host gives ai: its `io`, the network, credentials, stored files, the ids it mints; the clock and randomness
/// are the io's unless the host gives its own, as a test that sets the time does.
pub const Host = struct {
    io: std.Io,
    /// None: the standard library's client on the io, which `Models` keeps.
    http: ?http.Http = null,
    credentials: Credentials,
    /// None: a request with a stored file fails.
    files: ?Files = null,
    /// None: the io's real clock.
    clock: ?foundation.time.Clock = null,
    /// None: the io's randomness.
    random: ?std.Random = null,
    /// None: the io's sleep.
    sleeper: ?foundation.time.Sleeper = null,
    /// None: the standard library's WebSocket client on the io, which `Models` keeps.
    connector: ?foundation.websocket.Connector = null,
    /// None: one over the clock and randomness, which `Models` keeps.
    mint: ?Mint = null,

    /// The HTTP requests go through: the host's, or the default `Models` set in its place.
    pub fn network(host: *const Host) http.Http {
        return host.http.?;
    }

    /// The WebSocket sessions open through: the host's, or the default `Models` set in its place.
    pub fn sockets(host: *const Host) foundation.websocket.Connector {
        return host.connector.?;
    }

    pub fn nowMs(host: *const Host) i64 {
        return foundation.time.nowMs(host.io, host.clock);
    }

    pub fn randomBytes(host: *const Host, buffer: []u8) void {
        if (host.random) |random| return random.bytes(buffer);
        host.io.random(buffer);
    }

    /// Waits `ms` on the host's sleep, else the io's.
    pub fn sleep(host: *const Host, ms: u64) error{Canceled}!void {
        return foundation.time.sleep(host.io, host.sleeper, ms);
    }

    /// A new id from the host's mint, in `arena`.
    pub fn newId(host: *const Host, arena: Allocator) Allocator.Error![]const u8 {
        const id = host.mint.?.next();
        return arena.dupe(u8, &id);
    }

    /// A multipart body's boundary, random, in `arena`: no id, as nothing names it.
    pub fn boundary(host: *const Host, arena: Allocator) Allocator.Error![]const u8 {
        var bytes: [16]u8 = undefined;
        host.randomBytes(&bytes);
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        const hex = std.fmt.bytesToHex(bytes, .lower);
        return arena.print("octoii-{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });
    }
};

/// What a driver is given for one request: where to keep what it makes, its provider, the host, and where it leaves
/// the failure it fails with.
pub const Call = struct {
    /// Where everything of the request lives, until its caller lets it go.
    arena: Allocator,
    provider: *const Provider,
    host: *const Host,
    /// How long the host waits for each response the call is answered with.
    wait: ?http.Wait = null,
    /// The failure the call failed with, once a function returned `Failed`.
    failure: ?Failure = null,
    /// The types of the events it was sent that the vocabulary lacks.
    unlisted_events: std.StringHashMapUnmanaged(void) = .empty,

    /// Leaves `failure` as the call's, for the caller to read.
    pub fn fail(call: *Call, failure: Failure) error{Failed} {
        call.failure = failure;
        return error.Failed;
    }

    /// Leaves a failure of `kind`, its message formatted, as the call's.
    pub fn failWith(call: *Call, kind: failure_.Kind, comptime text: []const u8, arguments: anytype) Error {
        return call.fail(try Failure.format(call.arena, kind, text, arguments));
    }

    pub fn nowMs(call: *const Call) i64 {
        return call.host.nowMs();
    }

    /// The address the provider's API paths follow: the provider's, else `default`.
    pub fn baseUrl(call: *const Call, default: []const u8) []const u8 {
        return call.provider.settings.base_url orelse default;
    }

    /// The provider's credential, read from the host's store now; null where it holds none.
    pub fn credential(call: *Call) Error!?Credential {
        return call.host.credentials.read(call.arena, call.provider.id) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Unavailable => call.failWith(.auth, "The host's credentials for the provider {s} cannot be read", .{call.provider.id}),
        };
    }

    /// The provider's API key, read from the host's store now; `auth` where it holds none.
    pub fn apiKey(call: *Call) Error![]const u8 {
        if (try call.credential()) |given| if (given == .api_key) return given.api_key;
        return call.failWith(.auth, "The provider {s} has no API key: the host's credentials hold none for it", .{call.provider.id});
    }
};
