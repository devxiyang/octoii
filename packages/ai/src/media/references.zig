//! The files a media or decision request refers to, read as `Models` sends them: a stored file read into inline data
//! of the type it is, a file inline typed, and one at an address kept for its provider to fetch, or fetched by ai
//! where its provider fetches none. An image takes the types an `input_image` takes, a video those an `input_video`
//! takes, and audio any `audio/` type. A file of a type its kind does not take, of none, or at an address that is not
//! `https`, fails the request.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vocabulary = @import("vocabulary");
const FileExtension = vocabulary.extensions.FileExtension;
const Call = @import("../driver.zig").Call;
const Error = @import("../failure.zig").Error;
const files = @import("../text/files.zig");
const wire_http = @import("../wire/http.zig");

/// What a reference refers to.
pub const Kind = enum { image, video, audio };

/// A reference's file as a request carries it: at an address or a data URL in `url`, or stored under `octoii`.
pub const Referenced = struct { url: ?[]const u8 = null, octoii: ?FileExtension = null };

/// A reference's file once read: a data URL or an `https` address, and its `octoii` without the stored file's
/// reference.
pub const ReadFile = struct { url: []const u8, octoii: ?FileExtension = null };

/// `file`, of `kind`, read: a stored file into a data URL of the type its `octoii`, bytes or name say; an inline one
/// as a data URL of the type it is; one at an `https` address kept as it is, its type checked where it declares or
/// names one, or fetched into a data URL where `fetch` says ai fetches. `invalid_request` names it as `what`.
pub fn read(call: *Call, kind: Kind, file: Referenced, fetch: bool, what: []const u8) Error!ReadFile {
    const ref = if (file.octoii) |extension| extension.ref else null;
    if (ref) |stored| {
        const host_files = call.host.files orelse return call.failWith(.invalid_request, "{s} is the stored file {s}, and the host gives no stored files", .{ what, stored });
        const bytes = host_files.read(call.arena, stored) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return call.failWith(.invalid_request, "{s}, the stored file {s}, cannot be read: {t}", .{ what, stored, err }),
        };
        return typedData(call, kind, file, what, .{ .bytes = bytes });
    }
    const url = file.url orelse return call.failWith(.invalid_request, "{s} holds no file: give its url, or a stored file as octoii.ref", .{what});
    if (std.ascii.startsWithIgnoreCase(url, "data:")) return .{ .url = try inlineTyped(call, kind, file, what), .octoii = file.octoii };
    if (!std.ascii.startsWithIgnoreCase(url, "https://")) return call.failWith(.invalid_request, "{s} is at an address that is not https: ai sends only https addresses", .{what});
    if (!fetch) {
        if (try files.mediaType(call.arena, typedFile(kind, file), null) != null) _ = try checkedType(call, kind, file, what, null);
        return .{ .url = url, .octoii = file.octoii };
    }
    const fetched = try wire_http.fetchFile(call, url);
    return typedData(call, kind, file, what, .{ .bytes = fetched.data, .content_type = fetched.media_type });
}

/// `got`, the bytes of `file`, as a data URL of the type they are.
fn typedData(call: *Call, kind: Kind, file: Referenced, what: []const u8, got: files.Read) Error!ReadFile {
    const media_type = try checkedType(call, kind, file, what, got);
    var octoii = withoutRef(file.octoii);
    octoii.media_type = media_type;
    return .{ .url = try std.fmt.allocPrint(call.arena, "data:{s};base64,{b64}", .{ media_type, got.bytes }), .octoii = octoii };
}

/// Audio read into base64: its data, what it is, and its `octoii` without the stored file's reference.
pub const ReadAudio = struct { data: []const u8, media_type: []const u8, octoii: FileExtension };

/// Audio stored, or at the `https` address in `file.url` where `fetch` says ai fetches, read into base64 and the type
/// it is, which an `audio/` type must be; `invalid_request` names it as `what`.
pub fn readAudio(call: *Call, file: Referenced, fetch: bool, what: []const u8) Error!ReadAudio {
    if (file.octoii) |extension| if (extension.ref != null) {
        const made = try read(call, .audio, file, fetch, what);
        return .{ .data = dataUrlBase64(made.url).?, .media_type = made.octoii.?.media_type.?, .octoii = withoutRef(made.octoii) };
    };
    const url = file.url orelse return call.failWith(.invalid_request, "{s} holds no audio to read", .{what});
    if (!fetch) return call.failWith(.invalid_request, "{s} holds no audio to read", .{what});
    if (!std.ascii.startsWithIgnoreCase(url, "https://")) return call.failWith(.invalid_request, "{s} is at an address that is not https: ai sends only https addresses", .{what});
    const made = try read(call, .audio, file, true, what);
    return .{ .data = dataUrlBase64(made.url).?, .media_type = made.octoii.?.media_type.?, .octoii = withoutRef(made.octoii) };
}

/// A recording as a transcription carries it, its stored file read into base64, its format the one its media type
/// names where it gives none; base64 and an address go as they are, an address checked to be `https`.
pub fn readRecording(call: *Call, audio: vocabulary.transcriptions.TranscriptionAudio, what: []const u8) Error!vocabulary.transcriptions.TranscriptionAudio {
    switch (audio) {
        .inline_data => return audio,
        .addressed => |addressed| {
            if (!std.ascii.startsWithIgnoreCase(addressed.url, "https://")) return call.failWith(.invalid_request, "{s} is at an address that is not https: ai sends only https addresses", .{what});
            return audio;
        },
        .stored => |stored| {
            const read_audio = try readAudio(call, .{ .octoii = stored.octoii }, false, what);
            var octoii = read_audio.octoii;
            octoii.media_type = read_audio.media_type;
            return .{ .inline_data = .{ .data = read_audio.data, .format = stored.format orelse audioFormat(read_audio.media_type), .octoii = octoii } };
        },
    }
}

/// The format a provider names audio of `media_type` by, such as `mp3` for `audio/mpeg`: its subtype, else.
pub fn audioFormat(media_type: []const u8) []const u8 {
    const named = std.StaticStringMap([]const u8).initComptime(.{ .{ "audio/mpeg", "mp3" }, .{ "audio/x-wav", "wav" }, .{ "audio/mp4", "m4a" } });
    return named.get(media_type) orelse media_type[(std.mem.indexOfScalar(u8, media_type, '/') orelse return media_type) + 1 ..];
}

/// The media type of audio a provider names by `format`, such as `audio/mpeg` for `mp3`: `audio/` and the format, else.
pub fn audioMediaType(arena: Allocator, format: []const u8) Allocator.Error![]const u8 {
    const named = std.StaticStringMap([]const u8).initComptime(.{ .{ "mp3", "audio/mpeg" }, .{ "mpga", "audio/mpeg" }, .{ "m4a", "audio/mp4" } });
    return named.get(format) orelse std.fmt.allocPrint(arena, "audio/{s}", .{format});
}

/// The base64 of a data URL; null for an address or a data URL that is not base64.
pub fn dataUrlBase64(url: []const u8) ?[]const u8 {
    if (!std.ascii.startsWithIgnoreCase(url, "data:")) return null;
    const comma = std.mem.indexOfScalar(u8, url, ',') orelse return null;
    if (!std.ascii.endsWithIgnoreCase(url[0..comma], ";base64")) return null;
    return url[comma + 1 ..];
}

/// The type of `file`, of `kind`, as its data URL, `octoii`, what was read and its name say, where its kind takes it.
fn checkedType(call: *Call, kind: Kind, file: Referenced, what: []const u8, got: ?files.Read) Error![]const u8 {
    if (kind != .audio) return files.checkedType(call, typedFile(kind, file), what, got);
    const media_type = try files.mediaType(call.arena, typedFile(kind, file), got) orelse
        return call.failWith(.invalid_request, "{s} does not say what it is: give its media type as octoii.media_type", .{what});
    if (!std.mem.startsWith(u8, media_type, "audio/")) return call.failWith(.invalid_request, "{s} is {s}, and audio takes an audio/ type", .{ what, media_type });
    return media_type;
}

/// An inline file's data URL with the type it is.
fn inlineTyped(call: *Call, kind: Kind, file: Referenced, what: []const u8) Error![]const u8 {
    const media_type = try checkedType(call, kind, file, what, null);
    if (kind == .audio) {
        const base64 = dataUrlBase64(file.url.?) orelse return call.failWith(.invalid_request, "{s} is a data URL that is not base64", .{what});
        return std.fmt.allocPrint(call.arena, "data:{s};base64,{s}", .{ media_type, base64 });
    }
    return switch (try files.typedInline(call.arena, typedFile(kind, file), media_type)) {
        .input_image => |image| image.image_url.?,
        .input_video => |video| video.video_url.?,
        .input_file => |given| given.file_data.?,
    };
}

/// `file` as the text kind's file of its kind, whose types the text kind's rules read: an image, a video, or a file
/// for audio.
fn typedFile(kind: Kind, file: Referenced) files.TypedFile {
    const url = file.url orelse "";
    return switch (kind) {
        .image => .{ .input_image = .{ .detail = .auto, .image_url = url, .octoii = file.octoii } },
        .video => .{ .input_video = .{ .video_url = url, .octoii = file.octoii } },
        .audio => if (std.ascii.startsWithIgnoreCase(url, "data:"))
            .{ .input_file = .{ .file_data = url, .octoii = file.octoii } }
        else
            .{ .input_file = .{ .file_url = url, .octoii = file.octoii } },
    };
}

/// A file's `octoii` once its bytes are read: its media type and name, without the reference they came from.
fn withoutRef(given: ?FileExtension) FileExtension {
    const extension = given orelse return .{};
    return .{ .media_type = extension.media_type, .filename = extension.filename };
}
