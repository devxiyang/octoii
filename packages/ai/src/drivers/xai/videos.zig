//! xAI's video kind: its video API. A video is made at `/videos/generations`, its frames and references in xAI's
//! fields; a video reference and a job to continue fail, as no model of the catalogue edits or extends a video. A job
//! is xAI's `request_id`, and `/videos/{id}` says how it stands, its statuses and failures made the vocabulary's. Its
//! one output is the video's address, fetched without credentials. A job is priced by its model's SKUs until xAI gives
//! its cost in ticks.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const videos = vocabulary.videos;
const seam = @import("../../driver.zig");
const Call = seam.Call;
const failure_ = @import("../../failure.zig");
const Error = failure_.Error;
const Kind = failure_.Kind;
const Model = @import("../../catalogue/model.zig").Model;
const http = @import("../../wire/http.zig");
const skus = @import("../../wire/video_skus.zig");
const media = @import("media.zig");
const shared = @import("../openrouter/media.zig");

pub const calls: seam.VideoCalls = .{ .create = create, .retrieve = retrieve, .download = download };

const Reference = struct { url: []const u8 };

/// The body of a video made at `/videos/generations`.
const Body = struct {
    model: []const u8,
    prompt: ?[]const u8 = null,
    duration: ?u32 = null,
    resolution: ?[]const u8 = null,
    aspect_ratio: ?[]const u8 = null,
    image: ?Reference = null,
    last_frame: ?Reference = null,
    reference_images: ?[]const Reference = null,
    reference_audios: ?[]const Reference = null,
    generate_audio: ?bool = null,
    user: ?[]const u8 = null,
};

/// The request as it goes to xAI for `model`: a video made from its prompt, frames and references; `invalid_request`
/// for what xAI's models do not take: a callback, a job to continue, or a video reference.
pub fn wireRequest(call: *Call, model: *const Model, request: videos.VideoRequest) Error![]const u8 {
    const arena = call.arena;
    const reference = try model.reference(arena);
    const own = try media.options(call, request.provider, "video API");
    if (request.callback_url != null) return call.failWith(.invalid_request, "xAI tells no address when a video job ends: retrieve the job instead of a callback_url", .{});
    if (request.previous_job_id != null) return call.failWith(.invalid_request, "The model {s} continues no job: leave previous_job_id out", .{reference});
    var images: std.ArrayList(Reference) = .empty;
    var audios: std.ArrayList(Reference) = .empty;
    for (request.input_references orelse &.{}, 0..) |given, index| switch (given) {
        .video => return call.failWith(.invalid_request, "The model {s} takes no video reference: give images or audio as references", .{reference}),
        .image => |image| {
            try media.checkImageType(call, image.image_url.url, image.octoii, try std.fmt.allocPrint(arena, "The input_references[{d}]", .{index}));
            try images.append(arena, .{ .url = image.image_url.url orelse "" });
        },
        .audio => |audio| try audios.append(arena, .{ .url = audio.audio_url.url orelse "" }),
    };
    var body: Body = .{ .model = model.id, .prompt = request.prompt, .duration = request.duration, .resolution = request.resolution, .aspect_ratio = request.aspect_ratio, .generate_audio = request.generate_audio, .user = request.user };
    for (request.frame_images orelse &.{}, 0..) |frame, index| {
        try media.checkImageType(call, frame.image_url.url, frame.octoii, try std.fmt.allocPrint(arena, "The frame_images[{d}]", .{index}));
        const at: Reference = .{ .url = frame.image_url.url orelse "" };
        switch (frame.frame_type) {
            .first_frame => if (body.image == null) {
                body.image = at;
            },
            .last_frame => if (body.last_frame == null) {
                body.last_frame = at;
            },
        }
    }
    if (body.image != null and request.aspect_ratio != null) return call.failWith(.invalid_request, "xAI makes a video of its first frame's aspect ratio: leave aspect_ratio out beside a first frame", .{});
    if (images.items.len > 0) body.reference_images = images.items;
    if (audios.items.len > 0) body.reference_audios = audios.items;
    return foundation.json.encode(arena, foundation.json.merged(.{ body, own }));
}

fn create(call: *Call, model: *const Model, request: *const videos.VideoRequest) Error!videos.VideoJob {
    const response = try media.send(call, .{ .path = "/videos/generations", .body = try wireRequest(call, model, request.*), .accept = "application/json" });
    const created = try media.jsonBody(struct { request_id: []const u8 }, call, response, "video job");
    return .{ .id = created.request_id, .status = .pending, .octoii = .{ .model = try model.reference(call.arena), .usage = try skus.pricedUsage(call.arena, model, request) } };
}

/// How a video stands as xAI says, of which ai reads these fields.
const Video = struct {
    status: enum { pending, done, failed },
    progress: ?u32 = null,
    @"error": ?struct { code: []const u8, message: []const u8 } = null,
    usage: ?struct { cost_in_usd_ticks: ?u64 = null } = null,
    video: ?struct {
        url: ?[]const u8 = null,
        duration: ?f64 = null,
        respect_moderation: ?bool = null,
        file_output: ?struct { expires_at: ?i64 = null } = null,
    } = null,
};

/// How the job `id` stands, as xAI says; a job xAI no longer keeps fails as `invalid_request`.
fn retrieved(call: *Call, id: []const u8) Error!Video {
    const path = try std.fmt.allocPrint(call.arena, "/videos/{f}", .{std.fmt.alt(std.Uri.Component{ .raw = id }, .formatEscaped)});
    const response = media.send(call, .{ .method = .GET, .path = path, .accept = "application/json" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return shared.goneAsInvalid(call, &.{ 404, 410 }, "xAI no longer keeps the video job {s}: download a video once its job completes", .{id}),
    };
    return media.jsonBody(Video, call, response, "video job");
}

fn retrieve(call: *Call, model: *const Model, id: []const u8) Error!videos.VideoJob {
    return videoJob(call.arena, try model.reference(call.arena), id, try retrieved(call, id));
}

/// The failure kind of each of xAI's video error codes.
const kinds = std.StaticStringMap(Kind).initComptime(.{
    .{ "invalid_argument", .invalid_request }, .{ "failed_precondition", .invalid_request },
    .{ "permission_denied", .forbidden },      .{ "service_unavailable", .server },
    .{ "internal_error", .server },
});

/// xAI's video `id` as the vocabulary's job, made by the model `reference`.
fn videoJob(arena: Allocator, reference: []const u8, id: []const u8, video: Video) Allocator.Error!videos.VideoJob {
    const cost: ?f64 = if (video.usage) |given| (if (given.cost_in_usd_ticks) |ticks| media.dollarsOfTicks(ticks) else null) else null;
    var job: videos.VideoJob = .{ .id = id, .status = .pending, .usage = if (cost) |given| .{ .cost = given } else null, .octoii = .{ .model = reference } };
    switch (video.status) {
        .pending => job.status = if ((video.progress orelse 0) > 0) .in_progress else .pending,
        .failed => {
            job.status = .failed;
            const given = video.@"error";
            job.@"error" = if (given) |raised| try std.fmt.allocPrint(arena, "{s}: {s}", .{ raised.code, raised.message }) else "The video failed without saying why";
            const lowered = if (given) |raised| try std.ascii.allocLowerString(arena, raised.message) else "";
            const moderated = std.mem.indexOf(u8, lowered, "moderat") != null or std.mem.indexOf(u8, lowered, "content polic") != null or std.mem.indexOf(u8, lowered, "safety") != null;
            const kind: Kind = if (given == null) .server else if (moderated) .content_filter else kinds.get(given.?.code) orelse .server;
            job.octoii.failure = .{ .kind = kind, .retryable = failure_.retryableKind(kind) };
        },
        .done => {
            const made = video.video;
            const url = if (made) |given| given.url orelse "" else "";
            const withheld = made == null or made.?.respect_moderation == false or url.len == 0;
            if (withheld) {
                job.status = .failed;
                job.@"error" = "xAI's moderation withheld the video";
                job.octoii.failure = .{ .kind = .content_filter, .retryable = false };
                return job;
            }
            job.status = .completed;
            job.urls = try arena.dupe([]const u8, &.{url});
            job.expires_at = if (made.?.file_output) |output| output.expires_at else null;
            if (made.?.duration) |seconds| job.octoii.usage = .{ .seconds = seconds };
        },
    }
    return job;
}

/// The one output of the completed job `id`: its video, fetched from its address without credentials.
fn download(call: *Call, _: *const Model, id: []const u8, index: u32) Error!videos.VideoContent {
    if (index != 0) return call.failWith(.invalid_request, "xAI makes one video a job, and the output {d} is none of the job {s}'s", .{ index, id });
    const video = try retrieved(call, id);
    const url = if (video.video) |made| made.url orelse "" else "";
    if (video.status != .done or url.len == 0) return call.failWith(.invalid_request, "xAI keeps no video of the job {s}, which is {t}", .{ id, video.status });
    // The address takes no credentials, so none go to it.
    const response = call.host.network().send(.{ .url = url, .wait = call.wait }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return call.failWith(.aborted, "The request was aborted", .{}),
        error.Timeout => return call.failWith(.timeout, "No response began in time", .{}),
        error.Transport => return call.failWith(.transport, "The request to {s} did not get through", .{http.shownAddress(url)}),
    };
    if (response.status < 200 or response.status >= 300) {
        call.failure = try http.failureOf(call, response, null);
        return shared.goneAsInvalid(call, &.{ 403, 404, 410 }, "xAI no longer keeps the video of the job {s}: download a video once its job completes", .{id});
    }
    const got = try shared.bytesBody(call, response, "video/mp4");
    return .{ .media_type = got.media_type, .data = got.data };
}
