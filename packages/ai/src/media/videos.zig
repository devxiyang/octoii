//! The video kind as `Models` serves it: a request checked against its model and its stored references read, then a
//! job its provider takes, stamped with the model making it and Octoii's account of it; how a job stands, its account
//! kept; waiting for a job on the host's sleep; and one of a completed job's outputs.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vocabulary = @import("vocabulary");
const videos = vocabulary.videos;
const VideoJob = videos.VideoJob;
const VideoRequest = videos.VideoRequest;
const driver = @import("../driver.zig");
const Call = driver.Call;
const failure_ = @import("../failure.zig");
const Failure = failure_.Failure;
const Error = failure_.Error;
const model_ = @import("../catalogue/model.zig");
const Model = model_.Model;
const Models = @import("../Models.zig");
const stream_ = @import("stream.zig");
const references = @import("references.zig");
const usage = @import("usage.zig");
const text_stream = @import("../text/stream.zig");

/// How often a job is retrieved while it is waited for.
pub const check_interval_ms = 10_000;

/// How long a job is waited for at most.
pub const wait_ms = 30 * 60_000;

/// A model that makes videos and its driver's calls, found for a call.
const Served = struct { model: *const Model, calls: driver.VideoCalls };

fn served(models: *Models, call: *Call, reference: []const u8) Error!Served {
    const found = try models.served(call, reference, .video);
    call.provider = found.provider;
    const calls = found.provider.driver.video orelse return call.failWith(.invalid_request, "The provider {s} makes no videos", .{found.provider.id});
    const model = try call.arena.create(Model);
    model.* = found.model;
    return .{ .model = model, .calls = calls };
}

fn callOf(models: *Models, arena: Allocator) Call {
    return .{ .arena = arena, .provider = undefined, .host = &models.host, .wait = .{ .head_ms = text_stream.start_timeout_ms, .idle_ms = text_stream.idle_timeout_ms } };
}

/// What `run` gave, or the failure its call was left with.
fn outcome(comptime Made: type, call: *Call, given: Error!Made) Allocator.Error!stream_.Outcome(Made) {
    const made = given catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return .{ .failed = call.failure.? },
    };
    return .{ .made = made };
}

/// The job the provider takes for `request`, stamped with the model and Octoii's account: the seconds asked for,
/// priced.
pub fn create(models: *Models, arena: Allocator, request: VideoRequest) Allocator.Error!stream_.Outcome(VideoJob) {
    var call = callOf(models, arena);
    return outcome(VideoJob, &call, created(models, &call, request));
}

fn created(models: *Models, call: *Call, request: VideoRequest) Error!VideoJob {
    const found = try served(models, call, request.model);
    const sent_at_ms = call.nowMs();
    try checkRequest(call, found.model, &request);
    const prepared = try call.arena.create(VideoRequest);
    prepared.* = try withReferencesRead(call, request);
    var job = try found.calls.create(call, found.model, prepared);
    const meters = job.octoii.usage orelse vocabulary.Usage{ .seconds = if (request.duration) |seconds| @floatFromInt(seconds) else null };
    const cost = if (job.usage) |given| given.cost else null;
    job.octoii.model = try found.model.reference(call.arena);
    job.octoii.usage = usage.priced(found.model, meters, cost, sent_at_ms);
    return job;
}

/// How `job` stands, as its provider says now, with its account kept: its seconds, and its cost the provider's once it
/// gives one.
pub fn retrieve(models: *Models, arena: Allocator, job: VideoJob) Allocator.Error!stream_.Outcome(VideoJob) {
    var call = callOf(models, arena);
    return outcome(VideoJob, &call, retrieved(models, &call, job));
}

fn retrieved(models: *Models, call: *Call, job: VideoJob) Error!VideoJob {
    const found = try served(models, call, job.octoii.model);
    var now = try found.calls.retrieve(call, found.model, job.id);
    var kept = job.octoii.usage orelse vocabulary.Usage{};
    if (now.octoii.usage) |given| inline for (comptime std.meta.fieldNames(vocabulary.Usage)) |name| {
        if (@field(given, name)) |value| @field(kept, name) = value;
    };
    const given_cost = if (now.usage) |reported| reported.cost else null;
    if (given_cost orelse (if (now.octoii.usage) |given| given.cost else null) orelse (if (job.octoii.usage) |given| given.cost else null)) |cost| kept.cost = cost;
    now.octoii.model = job.octoii.model;
    now.octoii.usage = if (std.meta.eql(kept, vocabulary.Usage{})) null else kept;
    return now;
}

/// A job waited for: ended, or the failure the wait ended with and the job as it stood, which goes on.
pub const Waited = union(enum) { ended: VideoJob, failed: struct { failure: Failure, job: ?VideoJob } };

/// Creates a job and retrieves it every `check_interval_ms` until it ends, for at most `wait_ms`. A failure meanwhile
/// carries the job and is not retryable, as the job goes on; past the wait it is `timeout`.
pub fn createAndPoll(models: *Models, arena: Allocator, request: VideoRequest) Allocator.Error!Waited {
    var job = switch (try create(models, arena, request)) {
        .made => |made| made,
        .failed => |failure| return .{ .failed = .{ .failure = failure, .job = null } },
    };
    const host = &models.host;
    const deadline_ms = host.nowMs() + wait_ms;
    while (!job.status.ended()) {
        const left_ms = deadline_ms - host.nowMs();
        if (left_ms <= 0) {
            var failure = try Failure.format(arena, .timeout, "The video was not made within {d} ms", .{wait_ms});
            failure.retryable = false;
            return .{ .failed = .{ .failure = failure, .job = job } };
        }
        host.sleep(@intCast(@min(check_interval_ms, left_ms))) catch {
            var failure: Failure = .init(.aborted, "The wait for the video was aborted");
            failure.retryable = false;
            return .{ .failed = .{ .failure = failure, .job = job } };
        };
        job = switch (try retrieve(models, arena, job)) {
            .made => |made| made,
            .failed => |failure| {
                var going = failure;
                going.retryable = false;
                return .{ .failed = .{ .failure = going, .job = job } };
            },
        };
    }
    return .{ .ended = job };
}

/// One of `job`'s outputs; `invalid_request` before anything is sent for a job that has not completed.
pub fn download(models: *Models, arena: Allocator, job: VideoJob, index: u32) Allocator.Error!stream_.Outcome(videos.VideoContent) {
    var call = callOf(models, arena);
    if (job.status != .completed) return stream_.failedWith(videos.VideoContent, arena, .invalid_request, "The video job {s} is {t}: only a completed job has outputs to download", .{ job.id, job.status });
    return outcome(videos.VideoContent, &call, downloaded(models, &call, job, index));
}

fn downloaded(models: *Models, call: *Call, job: VideoJob, index: u32) Error!videos.VideoContent {
    const found = try served(models, call, job.octoii.model);
    return found.calls.download(call, found.model, job.id, index);
}

/// Checks `request` against `model`: each setting the model lists, the frames and the modalities of the references it
/// reads, a seed and sound for a model that takes them, and an upscaling model's levels and factor.
fn checkRequest(call: *Call, model: *const Model, request: *const VideoRequest) Error!void {
    const reference = try model.reference(call.arena);
    if (request.duration) |duration| try listed(call, reference, "duration", @floatFromInt(duration), model.supported_durations, "supported_durations");
    try listedText(call, reference, "resolution", request.resolution, model.supported_resolutions, "supported_resolutions");
    try listedText(call, reference, "aspect_ratio", request.aspect_ratio, model.supported_aspect_ratios, "supported_aspect_ratios");
    try listedText(call, reference, "size", request.size, model.supported_sizes, "supported_sizes");
    if (request.creativity) |creativity| try listed(call, reference, "creativity", creativity, model.creativity, "creativity");
    const frames = request.frame_images orelse &.{};
    for (frames) |frame| {
        const taken = if (model.supported_frame_images) |given| std.mem.indexOfScalar(model_.FrameImage, given, @fromBackingInt(@intCast(@backingInt(frame.frame_type)))) != null else false;
        if (!taken) return call.failWith(.invalid_request, "The model {s} does not take the frame \"{t}\": its supported_frame_images {s}", .{ reference, frame.frame_type, try listing(call.arena, model.supported_frame_images) });
    }
    if (frames.len > 0) try reads(call, model, reference, .image, "frame_images");
    for (request.input_references orelse &.{}) |given| switch (given) {
        .image => try reads(call, model, reference, .image, "an input_reference of type image_url"),
        .audio => try reads(call, model, reference, .audio, "an input_reference of type audio_url"),
        .video => try reads(call, model, reference, .video, "an input_reference of type video_url"),
    };
    if (request.seed != null and model.seed != true) return call.failWith(.invalid_request, "The model {s} takes no seed: its seed is not true", .{reference});
    if (request.generate_audio == true and model.generate_audio != true) return call.failWith(.invalid_request, "The model {s} makes no sound: its generate_audio is not true", .{reference});
    if (request.upscale_factor) |factor| {
        const range = model.upscale_factor;
        const within = if (range) |given| (given.min == null or factor >= given.min.?) and (given.max == null or factor <= given.max.?) else false;
        if (!within) return call.failWith(.invalid_request, "The model {s} does not take the upscale_factor {d}", .{ reference, factor });
    }
}

fn reads(call: *Call, model: *const Model, reference: []const u8, modality: model_.InputModality, what: []const u8) Error!void {
    if (model.reads(modality)) return;
    return call.failWith(.invalid_request, "The request holds {s}, and the model {s} does not read {t}: its architecture.input_modalities lack it", .{ what, reference, modality });
}

fn listed(call: *Call, reference: []const u8, field: []const u8, value: f64, given: ?[]const f64, list_name: []const u8) Error!void {
    if (given) |values| for (values) |each| if (each == value) return;
    var text: std.ArrayList(u8) = .empty;
    for (given orelse &.{}, 0..) |each, index| try text.print(call.arena, "{s}{d}", .{ if (index == 0) "" else ", ", each });
    const takes = if (given == null) "lists none" else try std.fmt.allocPrint(call.arena, "lists {s}", .{text.items});
    return call.failWith(.invalid_request, "The model {s} does not take the {s} {d}: its {s} {s}", .{ reference, field, value, list_name, takes });
}

fn listedText(call: *Call, reference: []const u8, field: []const u8, value: ?[]const u8, given: ?[]const []const u8, list_name: []const u8) Error!void {
    const asked = value orelse return;
    if (given) |values| for (values) |each| if (std.mem.eql(u8, each, asked)) return;
    const takes = if (given) |values| try std.fmt.allocPrint(call.arena, "lists {s}", .{try std.mem.join(call.arena, ", ", values)}) else "lists none";
    return call.failWith(.invalid_request, "The model {s} does not take the {s} \"{s}\": its {s} {s}", .{ reference, field, asked, list_name, takes });
}

fn listing(arena: Allocator, given: ?[]const model_.FrameImage) Allocator.Error![]const u8 {
    const values = given orelse return "lists none";
    var names: std.ArrayList([]const u8) = .empty;
    for (values) |each| try names.append(arena, @tagName(each));
    return std.fmt.allocPrint(arena, "lists {s}", .{try std.mem.join(arena, ", ", names.items)});
}

/// `request` with its frames and references read: stored ones into data URLs, inline ones typed.
fn withReferencesRead(call: *Call, request: VideoRequest) Error!VideoRequest {
    var prepared = request;
    if (request.frame_images) |frames| {
        const read = try call.arena.alloc(videos.FrameImage, frames.len);
        for (frames, read, 0..) |frame, *made, index| {
            const file = try references.read(call, .image, .{ .url = frame.image_url.url, .octoii = frame.octoii }, false, try std.fmt.allocPrint(call.arena, "The frame_images[{d}]", .{index}));
            made.* = .{ .image_url = .{ .url = file.url }, .octoii = file.octoii, .frame_type = frame.frame_type };
        }
        prepared.frame_images = read;
    }
    if (request.input_references) |given| {
        const read = try call.arena.alloc(videos.InputReference, given.len);
        for (given, read, 0..) |reference, *made, index| {
            const what = try std.fmt.allocPrint(call.arena, "The input_references[{d}]", .{index});
            made.* = switch (reference) {
                .image => |image| image: {
                    const file = try references.read(call, .image, .{ .url = image.image_url.url, .octoii = image.octoii }, false, what);
                    break :image .{ .image = .{ .image_url = .{ .url = file.url }, .octoii = file.octoii } };
                },
                .audio => |audio| audio: {
                    const file = try references.read(call, .audio, .{ .url = audio.audio_url.url, .octoii = audio.octoii }, false, what);
                    break :audio .{ .audio = .{ .audio_url = .{ .url = file.url }, .octoii = file.octoii } };
                },
                .video => |video| video: {
                    const file = try references.read(call, .video, .{ .url = video.video_url.url, .octoii = video.octoii }, false, what);
                    break :video .{ .video = .{ .video_url = .{ .url = file.url }, .octoii = file.octoii } };
                },
            };
        }
        prepared.input_references = read;
    }
    return prepared;
}
