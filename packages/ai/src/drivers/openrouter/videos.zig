//! OpenRouter's video kind: its video API, which the vocabulary is. A job is made at `/videos`, says how it stands at
//! `/videos/{id}` and gives its outputs at `/videos/{id}/content`. A job is priced by its model's SKUs until
//! OpenRouter gives its cost, and a failed job's error is classified as `content_filter` where it speaks of a content
//! policy, else as `server`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("foundation");
const vocabulary = @import("vocabulary");
const videos = vocabulary.videos;
const seam = @import("../../driver.zig");
const Call = seam.Call;
const failure_ = @import("../../failure.zig");
const Error = failure_.Error;
const Model = @import("../../catalogue/model.zig").Model;
const skus = @import("../../wire/video_skus.zig");
const media = @import("media.zig");

pub const calls: seam.VideoCalls = .{ .create = create, .retrieve = retrieve, .download = download };

/// The request as it goes to OpenRouter for `model`: the model by its id, and no extensions on its frames and
/// references.
pub fn wireRequest(arena: Allocator, model: *const Model, request: videos.VideoRequest) Allocator.Error![]const u8 {
    var sent = request;
    sent.model = model.id;
    if (request.frame_images) |frames| {
        const plain = try arena.dupe(videos.FrameImage, frames);
        for (plain) |*frame| frame.octoii = null;
        sent.frame_images = plain;
    }
    if (request.input_references) |given| {
        const plain = try arena.dupe(videos.InputReference, given);
        for (plain) |*reference| switch (reference.*) {
            inline else => |*each| each.octoii = null,
        };
        sent.input_references = plain;
    }
    return foundation.json.encode(arena, sent);
}

/// A job as OpenRouter gives it.
const WireJob = struct {
    id: []const u8,
    status: videos.VideoJobStatus,
    polling_url: ?[]const u8 = null,
    generation_id: ?[]const u8 = null,
    unsigned_urls: ?[]const []const u8 = null,
    urls: ?[]const []const u8 = null,
    expires_at: ?i64 = null,
    usage: @FieldType(videos.VideoJob, "usage") = null,
    @"error": ?[]const u8 = null,
};

fn create(call: *Call, model: *const Model, request: *const videos.VideoRequest) Error!videos.VideoJob {
    try media.checkProviderFields(call, request.provider, &.{"options"}, "video API");
    const response = try media.send(call, "/videos", try wireRequest(call.arena, model, request.*), "application/json");
    const job = try media.jsonBody(WireJob, call, response, "video job");
    var priced = try skus.pricedUsage(call.arena, model, request);
    if (job.usage) |given| if (given.cost) |cost| {
        priced.cost = cost;
    };
    return videoJob(call, model, job, priced);
}

fn retrieve(call: *Call, model: *const Model, id: []const u8) Error!videos.VideoJob {
    const response = try media.send(call, try call.arena.print("/videos/{f}", .{std.fmt.alt(std.Uri.Component{ .raw = id }, .formatEscaped)}), null, "application/json");
    return videoJob(call, model, try media.jsonBody(WireJob, call, response, "video job"), null);
}

/// OpenRouter's job as the vocabulary's: the model making it, its account where there is one, and a failed job's
/// failure: `content_filter` where its error speaks of a content policy, else `server`.
fn videoJob(call: *Call, model: *const Model, job: WireJob, usage: ?vocabulary.Usage) Allocator.Error!videos.VideoJob {
    var made: videos.VideoJob = .{ .id = job.id, .status = job.status, .polling_url = job.polling_url, .generation_id = job.generation_id, .unsigned_urls = job.unsigned_urls, .urls = job.urls, .expires_at = job.expires_at, .usage = job.usage, .@"error" = job.@"error", .octoii = .{ .model = try model.reference(call.arena), .usage = usage } };
    if (job.status == .failed) {
        const lowered = try std.ascii.allocLowerString(call.arena, job.@"error" orelse "");
        const policy = for ([_][]const u8{ "content", "policy", "moderat", "safety" }) |words| {
            if (std.mem.indexOf(u8, lowered, words) != null) break true;
        } else false;
        const kind: failure_.Kind = if (policy) .content_filter else .server;
        made.octoii.failure = .{ .kind = kind, .retryable = failure_.retryableKind(kind) };
    }
    return made;
}

/// The output at `index` of the job `id`, with the API key; an output OpenRouter no longer keeps fails as
/// `invalid_request`.
fn download(call: *Call, _: *const Model, id: []const u8, index: u32) Error!videos.VideoContent {
    const path = try call.arena.print("/videos/{f}/content?index={d}", .{ std.fmt.alt(std.Uri.Component{ .raw = id }, .formatEscaped), index });
    const response = media.send(call, path, null, "*/*") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return media.goneAsInvalid(call, &.{ 404, 410 }, "OpenRouter no longer keeps the output {d} of the video job {s}: download outputs once a job completes", .{ index, id }),
    };
    const got = try media.bytesBody(call, response, "video/mp4");
    return .{ .media_type = got.media_type, .data = got.data };
}
