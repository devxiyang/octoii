//! `Models`: the one handle a host makes and every caller shares. It keeps the directory of its providers' models —
//! which models each serves, from its listing or else the catalogue, the person's added models joining those it
//! lacks, each model's facts from the catalogue, the listing, the person, else assumed — and sends each request
//! through what every driver shares: checked, prepared, its stream made whole. It keeps nothing of a request after it.
//! The directory changes as `refresh` lists the providers' models and fetches the catalogue, and as `setProviders`
//! replaces them; every reader gets a copy of what it reads, so a change never pulls the floor from under a request.
const Models = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const driver = @import("driver.zig");
const failure = @import("failure.zig");
const media_stream = @import("media/stream.zig");
const media_images = @import("media/images.zig");
const media_speech = @import("media/speech.zig");
const media_transcriptions = @import("media/transcriptions.zig");
const media_videos = @import("media/videos.zig");
const media_realtime = @import("media/realtime.zig");
pub const RealtimeSession = media_realtime.RealtimeSession;
const model_ = @import("catalogue/model.zig");
const Model = model_.Model;
const facts_ = @import("catalogue/facts.zig");
const ModelFacts = facts_.ModelFacts;
const bundled = @import("catalogue/catalogue.zig").bundled;
const catalogue_refresh = @import("catalogue/refresh.zig");
pub const TextStream = @import("text/stream.zig").TextStream;

gpa: Allocator,
host: driver.Host,
/// Guards what follows: many read the directory at once, a change writes it alone.
lock: std.Io.RwLock = .init,
/// The providers, in the host's order; they and what they hold outlive every request made while they are set.
providers: []const driver.Provider,
/// The bundled catalogue, which lives as long as the handle.
base_arena: std.heap.ArenaAllocator,
/// The catalogue's models: the bundled ones, or those a refresh fetched, in `catalogue_arena`.
catalogue: []const Model,
catalogue_arena: ?std.heap.ArenaAllocator = null,
/// What each listing provider listed last, by its id, each in its own arena.
listings: std.StringArrayHashMapUnmanaged(Listing) = .empty,
/// The directory as it was built last.
directory: Directory,
/// Where a newer catalogue comes from; none, the bundled catalogue alone.
catalogue_source: ?catalogue_refresh.Refresh = null,
/// One refresh at a time.
refreshing: std.Io.Mutex = .init,
/// The HTTP requests go through where the host gives none: the standard library's client on the io.
default_http: ?*foundation.StdHttp = null,
/// The WebSocket sessions open through where the host gives none: the standard library's client on the io.
default_websocket: ?*foundation.StdWebSocket = null,
/// The ids minted where the host gives no mint: over its clock and randomness.
default_minter: @import("ids.zig").Minter = undefined,

const Listing = struct { arena: std.heap.ArenaAllocator, models: []const ModelFacts };

/// Every provider's models, by reference, and the person's added models a provider lists itself.
const Directory = struct {
    arena: std.heap.ArenaAllocator,
    served: std.StringArrayHashMapUnmanaged(Served) = .empty,
    shadowed: std.ArrayList([]const u8) = .empty,
};

pub const Options = struct {
    providers: []const driver.Provider,
    host: driver.Host,
    /// Where a newer catalogue document is served and kept; none, the bundled catalogue alone.
    catalogue: ?struct { url: []const u8, store: catalogue_refresh.Store } = null,
};

/// How long a listing of a provider's models, or a fetch of the catalogue, may take.
pub const refresh_timeout_ms = 10_000;

/// A handle of `options`' providers, its directory of the bundled catalogue; nothing is asked of the network until
/// `refresh`.
pub fn init(gpa: Allocator, options: Options) error{ OutOfMemory, DuplicateProvider }!*Models {
    try checkProviders(options.providers);
    const models = try gpa.create(Models);
    errdefer gpa.destroy(models);
    models.* = .{ .gpa = gpa, .host = options.host, .providers = options.providers, .base_arena = .init(gpa), .catalogue = &.{}, .directory = .{ .arena = .init(gpa) } };
    errdefer models.base_arena.deinit();
    if (models.host.http == null) {
        const default_http = try gpa.create(foundation.StdHttp);
        errdefer gpa.destroy(default_http);
        default_http.* = .init(gpa, options.host.io);
        models.default_http = default_http;
        models.host.http = default_http.http();
    }
    errdefer if (models.default_http) |default_http| {
        default_http.deinit();
        gpa.destroy(default_http);
    };
    if (models.host.mint == null) {
        models.default_minter = .{ .host = &models.host };
        models.host.mint = models.default_minter.mint();
    }
    if (models.host.connector == null) {
        const default_websocket = try gpa.create(foundation.StdWebSocket);
        errdefer gpa.destroy(default_websocket);
        default_websocket.* = .init(gpa, options.host.io);
        models.default_websocket = default_websocket;
        models.host.connector = default_websocket.connector();
    }
    errdefer if (models.default_websocket) |default_websocket| {
        default_websocket.deinit();
        gpa.destroy(default_websocket);
    };
    models.catalogue = try bundled(models.base_arena.allocator());
    if (options.catalogue) |source| models.catalogue_source = .{ .url = source.url, .store = source.store };
    models.directory = try models.built();
    return models;
}

pub fn deinit(models: *Models) void {
    models.directory.arena.deinit();
    for (models.listings.values()) |*listing| listing.arena.deinit();
    models.listings.deinit(models.gpa);
    if (models.catalogue_arena) |*arena| arena.deinit();
    models.base_arena.deinit();
    if (models.default_http) |default_http| {
        default_http.deinit();
        models.gpa.destroy(default_http);
    }
    if (models.default_websocket) |default_websocket| {
        default_websocket.deinit();
        models.gpa.destroy(default_websocket);
    }
    models.gpa.destroy(models);
}

fn checkProviders(providers: []const driver.Provider) error{DuplicateProvider}!void {
    for (providers, 0..) |given, index| {
        for (providers[0..index]) |earlier| if (std.mem.eql(u8, earlier.id, given.id)) return error.DuplicateProvider;
    }
}

/// Replaces the providers, keeping what a provider still set with the same driver listed.
pub fn setProviders(models: *Models, providers: []const driver.Provider) error{ OutOfMemory, DuplicateProvider }!void {
    try checkProviders(providers);
    models.lock.lockUncancelable(models.host.io);
    defer models.lock.unlock(models.host.io);
    models.providers = providers;
    var index: usize = 0;
    while (index < models.listings.count()) {
        const id = models.listings.keys()[index];
        const kept = for (providers) |each| {
            if (std.mem.eql(u8, each.id, id) and each.driver.list != null) break true;
        } else false;
        if (kept) {
            index += 1;
            continue;
        }
        var left = models.listings.fetchOrderedRemove(id).?;
        left.value.arena.deinit();
    }
    try models.rebuild();
}

/// Lists every listing provider's models and fetches the catalogue now, the directory changed by what came. A listing
/// or a fetch that fails keeps what was there; the next refresh asks again.
pub fn refresh(models: *Models) error{OutOfMemory}!void {
    models.refreshing.lockUncancelable(models.host.io);
    defer models.refreshing.unlock(models.host.io);
    const providers = blk: {
        models.lock.lockSharedUncancelable(models.host.io);
        defer models.lock.unlockShared(models.host.io);
        break :blk models.providers;
    };
    var fresh: std.ArrayList(struct { id: []const u8, listing: Listing }) = .empty;
    defer fresh.deinit(models.gpa);
    errdefer for (fresh.items) |*each| each.listing.arena.deinit();
    for (providers) |*serving| {
        const listing = serving.driver.list orelse continue;
        var arena_allocator: std.heap.ArenaAllocator = .init(models.gpa);
        var call = models.hostCall(arena_allocator.allocator(), serving);
        const listed = listing(&call) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Failed => {
                arena_allocator.deinit();
                continue;
            },
        };
        try fresh.append(models.gpa, .{ .id = serving.id, .listing = .{ .arena = arena_allocator, .models = listed } });
    }
    var fetched_arena: std.heap.ArenaAllocator = .init(models.gpa);
    var fetched: ?[]const Model = null;
    if (models.catalogue_source) |*source| fetched = try source.run(fetched_arena.allocator(), models.host.network());
    if (fetched == null) fetched_arena.deinit();

    models.lock.lockUncancelable(models.host.io);
    defer models.lock.unlock(models.host.io);
    for (fresh.items) |each| {
        const slot = try models.listings.getOrPut(models.gpa, each.id);
        if (slot.found_existing) slot.value_ptr.arena.deinit();
        slot.value_ptr.* = each.listing;
    }
    fresh.clearRetainingCapacity();
    if (fetched) |given| {
        if (models.catalogue_arena) |*old| old.deinit();
        models.catalogue_arena = fetched_arena;
        models.catalogue = given;
    }
    try models.rebuild();
}

/// Builds the directory again of what is set and listed, the old one let go: no reader holds it, as each copies what
/// it reads under the lock.
fn rebuild(models: *Models) Allocator.Error!void {
    const next = try models.built();
    models.directory.arena.deinit();
    models.directory = next;
}

fn built(models: *Models) Allocator.Error!Directory {
    var directory: Directory = .{ .arena = .init(models.gpa) };
    errdefer directory.arena.deinit();
    for (models.providers) |*serving| try models.serve(&directory, serving);
    return directory;
}

/// Adds the models `serving` serves: its listing's, or else its catalogue's, then the person's it lacks.
fn serve(models: *Models, directory: *Directory, serving: *const driver.Provider) Allocator.Error!void {
    const arena = directory.arena.allocator();
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    if (serving.driver.list != null) {
        const listed = if (models.listings.get(serving.id)) |listing| listing.models else &.{};
        for (listed) |given| {
            try ids.put(arena, given.id, {});
            try add(directory, serving, given.id, .{ .listing = given, .catalogue = models.entry(serving.driver, given.id), .person = personOf(serving, given.id) });
        }
    } else for (models.catalogue) |model| if (ofCatalogue(serving.driver, model)) {
        try ids.put(arena, model.id, {});
        try add(directory, serving, model.id, .{ .catalogue = model, .person = personOf(serving, model.id) });
    };
    for (serving.models) |given| {
        if (ids.contains(given.id)) {
            try directory.shadowed.append(arena, try arena.print("{s}/{s}", .{ serving.id, given.id }));
            continue;
        }
        try add(directory, serving, given.id, .{ .person = given, .catalogue = models.entry(serving.driver, given.id) });
    }
}

fn add(directory: *Directory, serving: *const driver.Provider, id: []const u8, given: facts_.Given) Allocator.Error!void {
    const arena = directory.arena.allocator();
    const reference = try arena.print("{s}/{s}", .{ serving.id, id });
    const slot = try directory.served.getOrPut(arena, reference);
    if (slot.found_existing) return;
    slot.value_ptr.* = .{ .provider = serving, .model = try facts_.modelOf(arena, serving.id, id, try serving.driver.kinds(arena), given) };
}

fn personOf(serving: *const driver.Provider, id: []const u8) ?ModelFacts {
    for (serving.models) |given| if (std.mem.eql(u8, given.id, id)) return given;
    return null;
}

fn ofCatalogue(serving: *const driver.Driver, model: Model) bool {
    const of = serving.catalogue orelse return false;
    return std.mem.eql(u8, model.octoii.provider, of);
}

/// The catalogue's entry of the model `id` under `serving`'s catalogue.
fn entry(models: *const Models, serving: *const driver.Driver, id: []const u8) ?Model {
    for (models.catalogue) |model| if (ofCatalogue(serving, model) and std.mem.eql(u8, model.id, id)) return model;
    return null;
}

/// `model` copied whole into `arena`, so that it outlives the directory it was read from.
fn copied(arena: Allocator, model: Model) Allocator.Error!Model {
    const encoded = try foundation.json.encode(arena, model);
    return foundation.json.decode(Model, arena, encoded) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // What was just encoded decodes.
        else => unreachable,
    };
}

/// The ids of the providers, in the host's order, in `arena`.
pub fn providerIds(models: *Models, arena: Allocator) Allocator.Error![]const []const u8 {
    models.lock.lockSharedUncancelable(models.host.io);
    defer models.lock.unlockShared(models.host.io);
    const ids = try arena.alloc([]const u8, models.providers.len);
    for (models.providers, ids) |each, *id| id.* = try arena.dupe(u8, each.id);
    return ids;
}

/// The directory's models, or those that serve `kind`, in the providers' order, copied into `arena`.
pub fn list(models: *Models, arena: Allocator, kind: ?model_.Kind) Allocator.Error![]const Model {
    models.lock.lockSharedUncancelable(models.host.io);
    defer models.lock.unlockShared(models.host.io);
    var listed: std.ArrayList(Model) = .empty;
    for (models.directory.served.values()) |each| if (kind == null or each.model.serves(kind.?)) try listed.append(arena, try copied(arena, each.model));
    return listed.items;
}

/// The references of the person's added models a provider lists itself, copied into `arena`.
pub fn shadowed(models: *Models, arena: Allocator) Allocator.Error![]const []const u8 {
    models.lock.lockSharedUncancelable(models.host.io);
    defer models.lock.unlockShared(models.host.io);
    const made = try arena.alloc([]const u8, models.directory.shadowed.items.len);
    for (models.directory.shadowed.items, made) |reference, *copy| copy.* = try arena.dupe(u8, reference);
    return made;
}

/// The stream of a text request; nothing is sent until its first read. What it gives lives in `arena`.
pub fn text(models: *Models, arena: Allocator, request: vocabulary.ResponsesRequest) TextStream {
    return .init(models, arena, request);
}

/// A text request's response, whole: `completed`, `incomplete`, or `failed` with its error.
pub fn create(models: *Models, arena: Allocator, request: vocabulary.ResponsesRequest) Allocator.Error!vocabulary.Response {
    var stream = models.text(arena, request);
    defer stream.close();
    while (try stream.next()) |_| {}
    return stream.response().?;
}

/// The stream of an image request: previews, text and each image made, priced, or its `error`; nothing is sent until
/// its first read. What it gives lives in `arena`.
pub fn imageStream(models: *Models, arena: Allocator, request: vocabulary.images.ImageRequest) media_images.ImageStream {
    return .init(.{ .models = models, .request = request }, arena, &models.host);
}

/// The images an image request made, whole, or the failure it ended with.
pub fn generateImages(models: *Models, arena: Allocator, request: vocabulary.images.ImageRequest) Allocator.Error!media_stream.Outcome(vocabulary.images.ImageResponse) {
    var stream = models.imageStream(arena, request);
    return media_images.gathered(arena, &stream);
}

/// The stream of a speech request: its audio as it is made, then its end, priced, or its `error`; nothing is sent
/// until its first read. What it gives lives in `arena`.
pub fn speechStream(models: *Models, arena: Allocator, request: vocabulary.speech.SpeechRequest) media_speech.SpeechStream {
    return .init(.{ .models = models, .request = request }, arena, &models.host);
}

/// The audio a speech request made, whole, or the failure it ended with.
pub fn createSpeech(models: *Models, arena: Allocator, request: vocabulary.speech.SpeechRequest) Allocator.Error!media_stream.Outcome(vocabulary.speech.SpeechResponse) {
    var stream = models.speechStream(arena, request);
    return media_speech.gathered(arena, &stream);
}

/// The stream of a transcription request: its text as it settles, then the whole transcript, priced, or its
/// `error`; nothing is sent until its first read. What it gives lives in `arena`.
pub fn transcriptionStream(models: *Models, arena: Allocator, request: vocabulary.transcriptions.TranscriptionRequest) media_transcriptions.TranscriptionStream {
    return .init(.{ .models = models, .request = request }, arena, &models.host);
}

/// The transcription a request made, whole, or the failure it ended with.
pub fn createTranscription(models: *Models, arena: Allocator, request: vocabulary.transcriptions.TranscriptionRequest) Allocator.Error!media_stream.Outcome(vocabulary.transcriptions.TranscriptionResponse) {
    var stream = models.transcriptionStream(arena, request);
    return media_transcriptions.gathered(arena, &stream);
}

/// The job a video request's provider takes, stamped with the model and priced, or the failure it ended with.
pub fn createVideo(models: *Models, arena: Allocator, request: vocabulary.videos.VideoRequest) Allocator.Error!media_stream.Outcome(vocabulary.videos.VideoJob) {
    return media_videos.create(models, arena, request);
}

/// How a video job stands now, its account kept, or the failure it ended with.
pub fn retrieveVideo(models: *Models, arena: Allocator, job: vocabulary.videos.VideoJob) Allocator.Error!media_stream.Outcome(vocabulary.videos.VideoJob) {
    return media_videos.retrieve(models, arena, job);
}

/// A video job made and waited for until it ends, every ten seconds for at most thirty minutes.
pub fn createAndPollVideo(models: *Models, arena: Allocator, request: vocabulary.videos.VideoRequest) Allocator.Error!media_videos.Waited {
    return media_videos.createAndPoll(models, arena, request);
}

/// One of a completed video job's outputs, or the failure it ended with.
pub fn downloadVideo(models: *Models, arena: Allocator, job: vocabulary.videos.VideoJob, index: u32) Allocator.Error!media_stream.Outcome(vocabulary.videos.VideoContent) {
    return media_videos.download(models, arena, job, index);
}

/// The answers to a decisions request's questions, priced, or the failure it ended with.
pub fn decide(models: *Models, arena: Allocator, request: vocabulary.decisions.DecisionsRequest) Allocator.Error!media_stream.Outcome(vocabulary.decisions.DecisionsResponse) {
    return @import("media/decisions.zig").decide(models, arena, request);
}

/// A realtime transcription session of `session`'s settings, open once its provider has taken them, or the failure
/// it could not open with, in `arena`. The session is the caller's to `deinit`, before `Models` is.
pub fn realtimeConnect(models: *Models, arena: Allocator, session: vocabulary.realtime.Session) Allocator.Error!media_realtime.Connected {
    return media_realtime.connect(models, arena, session);
}

/// The sideband of a session a client made by WebRTC, which sends no audio, or the failure it could not open with.
pub fn realtimeSideband(models: *Models, arena: Allocator, params: vocabulary.realtime.SidebandParams) Allocator.Error!media_realtime.Connected {
    return media_realtime.sideband(models, arena, params);
}

/// A session made for a client that connects by WebRTC: its call's id and the answer for the client, or the failure.
pub fn realtimeCreateCall(models: *Models, arena: Allocator, params: vocabulary.realtime.CallCreateParams) Allocator.Error!media_stream.Outcome(vocabulary.realtime.CallCreateResponse) {
    return media_realtime.createCall(models, arena, params);
}

/// A voice made for the account at the provider the request names, or the failure it ended with.
pub fn createVoice(models: *Models, arena: Allocator, params: vocabulary.voices.VoiceCreateParams) Allocator.Error!media_stream.Outcome(vocabulary.voices.Voice) {
    return @import("media/voices.zig").create(models, arena, params);
}

/// Removes a voice made for the account, or the failure it ended with.
pub fn deleteVoice(models: *Models, arena: Allocator, voice: vocabulary.voices.Voice) Allocator.Error!media_stream.Outcome(void) {
    return @import("media/voices.zig").delete(models, arena, voice);
}

/// A consent recorded for a voice at the provider the request names, or the failure it ended with.
pub fn createVoiceConsent(models: *Models, arena: Allocator, params: vocabulary.voices.VoiceConsentCreateParams) Allocator.Error!media_stream.Outcome(vocabulary.voices.VoiceConsent) {
    return @import("media/voices.zig").createConsent(models, arena, params);
}

/// A model and the provider that serves it.
pub const Served = struct { provider: *const driver.Provider, model: Model };

/// The provider `id`; null where the host has none of that id.
pub fn provider(models: *Models, id: []const u8) ?*const driver.Provider {
    models.lock.lockSharedUncancelable(models.host.io);
    defer models.lock.unlockShared(models.host.io);
    return models.providerLocked(id);
}

fn providerLocked(models: *const Models, id: []const u8) ?*const driver.Provider {
    for (models.providers) |*each| if (std.mem.eql(u8, each.id, id)) return each;
    return null;
}

/// The model `reference` names and the provider that serves it, listed or not — one no provider lists takes its
/// catalogue's facts, else those assumed — copied into `arena`; null where it names no provider the host has.
pub fn find(models: *Models, arena: Allocator, reference: []const u8) Allocator.Error!?Served {
    models.lock.lockSharedUncancelable(models.host.io);
    defer models.lock.unlockShared(models.host.io);
    if (models.directory.served.get(reference)) |found| return .{ .provider = found.provider, .model = try copied(arena, found.model) };
    const parts = model_.parseReference(reference) orelse return null;
    const serving = models.providerLocked(parts.provider) orelse return null;
    const model = try facts_.modelOf(arena, serving.id, parts.id, try serving.driver.kinds(arena), .{ .catalogue = models.entry(serving.driver, parts.id) });
    return .{ .provider = serving, .model = try copied(arena, model) };
}

/// The model `reference` names, which serves `kind`; `invalid_request` where none does.
pub fn served(models: *Models, call: *driver.Call, reference: []const u8, kind: model_.Kind) failure.Error!Served {
    const found = try models.find(call.arena, reference) orelse {
        if (model_.parseReference(reference) == null) {
            return call.failWith(.invalid_request, "\"{s}\" is not a model reference: a reference is provider/id", .{reference});
        }
        return call.failWith(.invalid_request, "No provider serves the model {s}", .{reference});
    };
    if (!found.model.serves(kind)) return call.failWith(.invalid_request, "The model {s} does not serve {t}", .{ reference, kind });
    return found;
}

/// Whether the model `reference` names reads the provider metadata of an item the model `writer` wrote: where that
/// model is itself, or one of a provider of the same driver where the driver says its metadata holds for every model.
pub fn readsMetadataOf(models: *Models, reference: []const u8, serving: *const driver.Provider, writer: []const u8) bool {
    if (std.mem.eql(u8, writer, reference)) return true;
    if (!serving.driver.metadata_across_models) return false;
    const parts = model_.parseReference(writer) orelse return false;
    const other = models.provider(parts.provider) orelse return false;
    return std.mem.eql(u8, other.driver.id, serving.driver.id);
}

/// A call to `serving` on behalf of the host itself: a listing or a status, bounded as a refresh is.
fn hostCall(models: *Models, arena: Allocator, serving: *const driver.Provider) driver.Call {
    return .{ .arena = arena, .provider = serving, .host = &models.host, .wait = .{ .head_ms = refresh_timeout_ms, .idle_ms = refresh_timeout_ms } };
}

/// Has every provider that keeps conversations let go of `conversation` — the key its requests named it with, their
/// `prompt_cache_key` — as it ended; a provider that could not be reached keeps it till it lets it go itself.
pub fn forgetConversation(models: *Models, arena: Allocator, conversation: []const u8) Allocator.Error!void {
    for (models.providers) |*serving| {
        const forgotten = serving.driver.forget_conversation orelse continue;
        var call = models.hostCall(arena, serving);
        forgotten(&call, conversation) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Failed => {},
        };
    }
}

/// Has `account` — the provider of an account the person removed, no more among the providers — let go of what it
/// keeps of the account, where its driver keeps something of one: the failure it could not, where it could not.
pub fn forgetAccount(models: *Models, arena: Allocator, account: *const driver.Provider) Allocator.Error!?failure.Failure {
    const forgotten = account.driver.forget_account orelse return null;
    var call = models.hostCall(arena, account);
    forgotten(&call) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return call.failure.?,
    };
    return null;
}

/// A sign-in begun, or the failure it could not begin with.
pub const SignInStarted = union(enum) { started: driver.SignIn, failed: failure.Failure };

/// Begins a sign-in in a browser for the provider `id`, its attempt kept in `arena` until it finishes.
pub fn signIn(models: *Models, arena: Allocator, id: []const u8, options: driver.SignInOptions) Allocator.Error!SignInStarted {
    const serving = models.provider(id) orelse return .{ .failed = try .format(arena, .invalid_request, "The host has no provider {s}", .{id}) };
    const begin = serving.driver.sign_in orelse return .{ .failed = try .format(arena, .invalid_request, "The provider {s} is not signed in to: its driver takes a credential as it is", .{id}) };
    var call = models.hostCall(arena, serving);
    return .{ .started = begin(&call, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return .{ .failed = call.failure.? },
    } };
}

/// The program that signs the agent of a provider in, as its driver tells it, or the failure it ended with.
pub const LoginTold = union(enum) { program: driver.Login, failed: failure.Failure };

/// The program that signs the agent of the provider `id` in, in `arena`, for a driver reached through an agent the
/// person signs in to themselves.
pub fn login(models: *Models, arena: Allocator, id: []const u8) Allocator.Error!LoginTold {
    const serving = models.provider(id) orelse return .{ .failed = try .format(arena, .invalid_request, "The host has no provider {s}", .{id}) };
    const tell = serving.driver.login orelse return .{ .failed = try .format(arena, .invalid_request, "The provider {s} has no agent of its own to sign in to", .{id}) };
    var call = models.hostCall(arena, serving);
    return .{ .program = tell(&call) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return .{ .failed = call.failure.? },
    } };
}

/// Finishes `sign_in` of the provider `id` from the address the browser was sent back to, storing its credential;
/// the failure it ends with, where it does not finish.
pub fn finishSignIn(models: *Models, arena: Allocator, id: []const u8, sign_in: driver.SignIn, redirect: []const u8) Allocator.Error!?failure.Failure {
    const serving = models.provider(id) orelse return try .format(arena, .invalid_request, "The host has no provider {s}", .{id});
    var call = models.hostCall(arena, serving);
    sign_in.finish(&call, sign_in.attempt, redirect) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return call.failure.?,
    };
    return null;
}

/// How the provider `id` stands: as its driver says, else connected where the host keeps a credential for it.
pub fn status(models: *Models, arena: Allocator, id: []const u8) Allocator.Error!driver.Status {
    const serving = models.provider(id) orelse return .{ .connected = false, .problem = try arena.print("The host has no provider {s}", .{id}) };
    var call = models.hostCall(arena, serving);
    if (serving.driver.status) |asked| return asked(&call) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Failed => .{ .connected = false, .problem = call.failure.?.message },
    };
    const credential = models.host.credentials.read(arena, id) catch null;
    if (credential) |held| if (held.usable()) return .{ .connected = true };
    return .{ .connected = false, .problem = try arena.print("No credential is kept for {s}", .{serving.name}) };
}
