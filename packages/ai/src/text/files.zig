//! The files of a text request and their media types. A file's type is the first of these that names one, what is
//! declared before what is inferred: its data URL's type; its `octoii.media_type`; the `Content-Type` a fetched file
//! came with, but `application/octet-stream`; the first bytes of a stored or fetched file; its name — its `filename`
//! or `octoii.filename`, else the last segment of its address's path. `input_image`, `input_file` and `input_video`
//! each take their own media types, and a file of another type fails the request; `input_audio` says its format.
//! A stored file's reference is its one source of bytes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vocabulary = @import("vocabulary");
const content = vocabulary.content;
const Error = @import("../failure.zig").Error;
const Call = @import("../driver.zig").Call;
const wire_http = @import("../wire/http.zig");

/// A file whose kind of content takes only some media types: an image, a file or a video.
pub const TypedFile = union(enum) {
    input_image: content.InputImage,
    input_file: content.InputFile,
    input_video: content.InputVideo,

    /// The typed file a part of content is; null for text and audio.
    pub fn of(part: content.InputContent) ?TypedFile {
        return switch (part) {
            .input_image => |image| .{ .input_image = image },
            .input_file => |file| .{ .input_file = file },
            .input_video => |video| .{ .input_video = video },
            .input_text, .input_audio => null,
        };
    }

    pub fn octoii(file: TypedFile) ?vocabulary.extensions.FileExtension {
        return switch (file) {
            inline else => |given| given.octoii,
        };
    }

    pub fn kind(file: TypedFile) []const u8 {
        return @tagName(file);
    }
};

/// What reading a file gave: its bytes, and the `Content-Type` it came with where it was fetched.
pub const Read = struct { bytes: []const u8, content_type: ?[]const u8 = null };

/// The text an `input_file` takes besides PDF.
const text_media_types = [_][]const u8{ "text/plain", "text/markdown", "text/csv", "text/html", "application/json", "application/xml" };

/// The media types each kind of file takes.
fn taken(file: TypedFile) []const []const u8 {
    return switch (file) {
        .input_image => &.{ "image/png", "image/jpeg", "image/gif", "image/webp" },
        .input_file => &(.{"application/pdf"} ++ text_media_types),
        .input_video => &.{ "video/mp4", "video/mpeg", "video/mov", "video/webm" },
    };
}

/// Whether `media_type` is text an `input_file` takes, which a provider that takes no text files is sent as text.
pub fn isText(media_type: []const u8) bool {
    for (text_media_types) |each| if (std.mem.eql(u8, each, media_type)) return true;
    return false;
}

/// What a file whose first bytes are these is, the more particular first. Types no content takes are known too, so
/// that a file of one fails saying what it is.
const signatures = [_]struct { media_type: []const u8, parts: []const struct { at: usize, bytes: []const u8 } }{
    .{ .media_type = "image/png", .parts = &.{.{ .at = 0, .bytes = "\x89PNG\r\n\x1a\n" }} },
    .{ .media_type = "image/jpeg", .parts = &.{.{ .at = 0, .bytes = "\xff\xd8\xff" }} },
    .{ .media_type = "image/gif", .parts = &.{.{ .at = 0, .bytes = "GIF8" }} },
    .{ .media_type = "image/webp", .parts = &.{ .{ .at = 0, .bytes = "RIFF" }, .{ .at = 8, .bytes = "WEBP" } } },
    .{ .media_type = "audio/wav", .parts = &.{ .{ .at = 0, .bytes = "RIFF" }, .{ .at = 8, .bytes = "WAVE" } } },
    .{ .media_type = "audio/mpeg", .parts = &.{.{ .at = 0, .bytes = "ID3" }} },
    .{ .media_type = "application/pdf", .parts = &.{.{ .at = 0, .bytes = "%PDF-" }} },
    // An MPEG program stream begins with a pack header, and an elementary video stream with a sequence header.
    .{ .media_type = "video/mpeg", .parts = &.{.{ .at = 0, .bytes = "\x00\x00\x01\xba" }} },
    .{ .media_type = "video/mpeg", .parts = &.{.{ .at = 0, .bytes = "\x00\x00\x01\xb3" }} },
    // Images, audio and QuickTime share MP4's container: its major brand, after `ftyp`, says which a file is.
    .{ .media_type = "image/avif", .parts = &.{ .{ .at = 4, .bytes = "ftyp" }, .{ .at = 8, .bytes = "avif" } } },
    .{ .media_type = "image/avif", .parts = &.{ .{ .at = 4, .bytes = "ftyp" }, .{ .at = 8, .bytes = "avis" } } },
    .{ .media_type = "image/heic", .parts = &.{ .{ .at = 4, .bytes = "ftyp" }, .{ .at = 8, .bytes = "heic" } } },
    .{ .media_type = "image/heic", .parts = &.{ .{ .at = 4, .bytes = "ftyp" }, .{ .at = 8, .bytes = "heix" } } },
    .{ .media_type = "image/heif", .parts = &.{ .{ .at = 4, .bytes = "ftyp" }, .{ .at = 8, .bytes = "mif1" } } },
    .{ .media_type = "image/heif", .parts = &.{ .{ .at = 4, .bytes = "ftyp" }, .{ .at = 8, .bytes = "msf1" } } },
    .{ .media_type = "audio/mp4", .parts = &.{ .{ .at = 4, .bytes = "ftyp" }, .{ .at = 8, .bytes = "M4A " } } },
    .{ .media_type = "video/mov", .parts = &.{ .{ .at = 4, .bytes = "ftyp" }, .{ .at = 8, .bytes = "qt  " } } },
    .{ .media_type = "video/mp4", .parts = &.{.{ .at = 4, .bytes = "ftyp" }} },
    .{ .media_type = "video/webm", .parts = &.{.{ .at = 0, .bytes = "\x1a\x45\xdf\xa3" }} },
};

/// What a file is by the extension of its name.
const extensions = std.StaticStringMap([]const u8).initComptime(.{
    .{ "pdf", "application/pdf" },                                                    .{ "txt", "text/plain" },                                                                 .{ "md", "text/markdown" },
    .{ "markdown", "text/markdown" },                                                 .{ "csv", "text/csv" },                                                                   .{ "html", "text/html" },
    .{ "htm", "text/html" },                                                          .{ "json", "application/json" },                                                          .{ "xml", "application/xml" },
    .{ "png", "image/png" },                                                          .{ "jpg", "image/jpeg" },                                                                 .{ "jpeg", "image/jpeg" },
    .{ "gif", "image/gif" },                                                          .{ "webp", "image/webp" },                                                                .{ "mp3", "audio/mpeg" },
    .{ "wav", "audio/wav" },                                                          .{ "mp4", "video/mp4" },                                                                  .{ "mpeg", "video/mpeg" },
    .{ "mpg", "video/mpeg" },                                                         .{ "mov", "video/mov" },                                                                  .{ "webm", "video/webm" },
    .{ "heic", "image/heic" },                                                        .{ "heif", "image/heif" },                                                                .{ "avif", "image/avif" },
    .{ "svg", "image/svg+xml" },                                                      .{ "bmp", "image/bmp" },                                                                  .{ "tif", "image/tiff" },
    .{ "tiff", "image/tiff" },                                                        .{ "m4a", "audio/mp4" },                                                                  .{ "aac", "audio/aac" },
    .{ "ogg", "audio/ogg" },                                                          .{ "flac", "audio/flac" },                                                                .{ "mkv", "video/x-matroska" },
    .{ "avi", "video/x-msvideo" },                                                    .{ "rtf", "application/rtf" },                                                            .{ "doc", "application/msword" },
    .{ "xls", "application/vnd.ms-excel" },                                           .{ "ppt", "application/vnd.ms-powerpoint" },                                              .{ "docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document" },
    .{ "xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" }, .{ "pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation" },
});

/// The media type of `file`, from the first that names one, each read without its parameters and in lower case;
/// null where none does.
pub fn mediaType(arena: Allocator, file: TypedFile, read: ?Read) Allocator.Error!?[]const u8 {
    if (try declared(arena, file)) |given| return given;
    if (read) |got| {
        if (try essence(arena, got.content_type)) |served| if (!std.mem.eql(u8, served, "application/octet-stream")) return served;
        if (ofBytes(got.bytes)) |found| return found;
    }
    return ofName(arena, name(file));
}

/// The media type of `file`, as `mediaType` reads it, where its kind of content takes it; `invalid_request`, naming
/// the file as `what` does, where nothing names its type or its content does not take it.
pub fn checkedType(call: *Call, file: TypedFile, what: []const u8, read: ?Read) Error![]const u8 {
    const found = try mediaType(call.arena, file, read) orelse
        return call.failWith(.invalid_request, "{s} does not say what it is: give its media type as octoii.media_type", .{what});
    for (taken(file)) |each| if (std.mem.eql(u8, each, found)) return found;
    return call.failWith(.invalid_request, "{s} is {s}, and an {s} takes {s}", .{ what, found, file.kind(), try listed(call.arena, taken(file)) });
}

/// The type `file` declares: its data URL's, else its `octoii.media_type`.
fn declared(arena: Allocator, file: TypedFile) Allocator.Error!?[]const u8 {
    if (inlineData(file)) |data| if (dataUrlParts(data)) |parts| if (try essence(arena, parts.header)) |given| return given;
    const extension = file.octoii() orelse return null;
    return essence(arena, extension.media_type);
}

/// A media type without its parameters, in lower case; null where it is absent or empty.
pub fn essence(arena: Allocator, media_type: ?[]const u8) Allocator.Error!?[]const u8 {
    const given = media_type orelse return null;
    const bare = std.mem.trim(u8, given[0 .. std.mem.indexOfScalar(u8, given, ';') orelse given.len], " \t");
    if (bare.len == 0) return null;
    return try std.ascii.allocLowerString(arena, bare);
}

fn ofBytes(bytes: []const u8) ?[]const u8 {
    for (signatures) |signature| {
        const matches = for (signature.parts) |part| {
            if (bytes.len < part.at + part.bytes.len or !std.mem.eql(u8, bytes[part.at..][0..part.bytes.len], part.bytes)) break false;
        } else true;
        if (matches) return signature.media_type;
    }
    return null;
}

fn ofName(arena: Allocator, given: ?[]const u8) Allocator.Error!?[]const u8 {
    const file_name = given orelse return null;
    const dot = std.mem.lastIndexOfScalar(u8, file_name, '.') orelse return null;
    return extensions.get(try std.ascii.allocLowerString(arena, file_name[dot + 1 ..]));
}

/// The base64 of the file `file` holds inline: its data URL's data where the URL says it is base64, or an
/// `input_file`'s `file_data` that is no data URL, which is base64 itself; null otherwise.
pub fn inlineBase64(file: TypedFile) ?[]const u8 {
    const data = inlineData(file) orelse return null;
    const parts = dataUrlParts(data) orelse return data;
    return if (std.ascii.endsWithIgnoreCase(parts.header, ";base64")) parts.data else null;
}

/// `file` with the data it holds inline as a data URL of `media_type`, its parameters and data as given; a file at
/// an address or stored as it is.
pub fn typedInline(arena: Allocator, file: TypedFile, media_type: []const u8) Allocator.Error!TypedFile {
    const data = inlineData(file) orelse return file;
    const typed = if (dataUrlParts(data)) |parts|
        try std.fmt.allocPrint(arena, "data:{s}{s},{s}", .{ media_type, parameters(parts.header), parts.data })
    else
        try std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ media_type, data });
    var made = file;
    switch (made) {
        .input_image => |*image| image.image_url = typed,
        .input_file => |*given| given.file_data = typed,
        .input_video => |*video| video.video_url = typed,
    }
    return made;
}

/// The address `file` is at; null for a file inline or stored.
pub fn address(file: TypedFile) ?[]const u8 {
    if (stored(file)) return null;
    return switch (file) {
        .input_image => |image| remoteUrl(image.image_url),
        .input_file => |given| given.file_url,
        .input_video => |video| remoteUrl(video.video_url),
    };
}

/// Whether `file` holds its bytes itself rather than at an address or as a stored file.
pub fn isInline(file: TypedFile) bool {
    return inlineData(file) != null;
}

/// The name of the file: its `filename` or `octoii.filename`, else the last segment of its address's path.
pub fn name(file: TypedFile) ?[]const u8 {
    if (file == .input_file) if (file.input_file.filename) |given| return given;
    if (file.octoii()) |extension| if (extension.filename) |given| return given;
    const at = address(file) orelse return null;
    const path = at[0 .. std.mem.indexOfAny(u8, at, "?#") orelse at.len];
    const segment = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse return null) + 1 ..];
    return if (segment.len == 0) null else segment;
}

fn stored(file: TypedFile) bool {
    const extension = file.octoii() orelse return false;
    return extension.ref != null;
}

fn inlineData(file: TypedFile) ?[]const u8 {
    if (stored(file)) return null;
    return switch (file) {
        .input_image => |image| dataUrl(image.image_url),
        .input_file => |given| given.file_data,
        .input_video => |video| dataUrl(video.video_url),
    };
}

fn isDataUrl(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "data:");
}

fn dataUrl(url: ?[]const u8) ?[]const u8 {
    const given = url orelse return null;
    return if (isDataUrl(given)) given else null;
}

fn remoteUrl(url: ?[]const u8) ?[]const u8 {
    const given = url orelse return null;
    return if (isDataUrl(given)) null else given;
}

/// A data URL's parts: what stands between its scheme and its first comma, and its data.
fn dataUrlParts(url: []const u8) ?struct { header: []const u8, data: []const u8 } {
    if (!isDataUrl(url)) return null;
    const comma = std.mem.indexOfScalar(u8, url, ',') orelse return .{ .header = url[5..], .data = "" };
    return .{ .header = url[5..comma], .data = url[comma + 1 ..] };
}

fn parameters(header: []const u8) []const u8 {
    return header[std.mem.indexOfScalar(u8, header, ';') orelse header.len ..];
}

/// `file` as a failure's message names it: by its stored file, its address, or as inline.
pub fn described(arena: Allocator, file: TypedFile) Allocator.Error![]const u8 {
    if (file.octoii()) |extension| if (extension.ref) |ref| return std.fmt.allocPrint(arena, "The {s} stored as {s}", .{ file.kind(), ref });
    if (address(file)) |at| return std.fmt.allocPrint(arena, "The {s} at {s}", .{ file.kind(), at[0 .. std.mem.indexOfAny(u8, at, "?#") orelse at.len] });
    return std.fmt.allocPrint(arena, "The inline {s}", .{file.kind()});
}

/// Types as a message lists them: "a, b or c".
fn listed(arena: Allocator, types: []const []const u8) Allocator.Error![]const u8 {
    if (types.len <= 1) return std.mem.join(arena, "", types);
    return std.fmt.allocPrint(arena, "{s} or {s}", .{ try std.mem.join(arena, ", ", types[0 .. types.len - 1]), types[types.len - 1] });
}

test "a file's type is what it declares, then what its bytes say, then its name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const declared_file: TypedFile = .{ .input_image = .{ .detail = .auto, .image_url = "data:IMAGE/PNG;base64,AAAA" } };
    try std.testing.expectEqualStrings("image/png", (try mediaType(a, declared_file, null)).?);
    const stored_file: TypedFile = .{ .input_file = .{ .octoii = .{ .ref = "f", .filename = "notes.md" } } };
    try std.testing.expectEqualStrings("application/pdf", (try mediaType(a, stored_file, .{ .bytes = "%PDF-1.7" })).?);
    try std.testing.expectEqualStrings("text/markdown", (try mediaType(a, stored_file, .{ .bytes = "# notes" })).?);
    const addressed: TypedFile = .{ .input_image = .{ .detail = .auto, .image_url = "https://example.com/a/cat.WEBP?x=1" } };
    try std.testing.expectEqualStrings("image/webp", (try mediaType(a, addressed, null)).?);
    try std.testing.expectEqualStrings("application/pdf, text/plain or text/csv", try listed(a, &.{ "application/pdf", "text/plain", "text/csv" }));
}

test "a file inline is made a data URL of its type" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const made = try typedInline(a, .{ .input_file = .{ .file_data = "JVBERi0=" } }, "application/pdf");
    try std.testing.expectEqualStrings("data:application/pdf;base64,JVBERi0=", made.input_file.file_data.?);
    try std.testing.expectEqualStrings("JVBERi0=", inlineBase64(made).?);
}

/// The file `file` holds at its address, fetched for a provider that takes no address for it, its type as
/// `checkedType` reads it; a declared type its content does not take fails before anything is fetched.
pub fn fetchInput(call: *Call, file: TypedFile) Error!wire_http.Fetched {
    const what = try described(call.arena, file);
    const at = address(file) orelse return call.failWith(.invalid_request, "{s} is at no address to fetch it from", .{what});
    if (try declared(call.arena, file) != null) _ = try checkedType(call, file, what, null);
    const fetched = try wire_http.fetchFile(call, at);
    return .{ .media_type = try checkedType(call, file, what, .{ .bytes = fetched.data, .content_type = fetched.media_type }), .data = fetched.data };
}

/// The media type of a file at an address its provider fetches, as its `octoii.media_type` or its name says; null
/// where neither names one, as it then goes as it is; `invalid_request` for a type its content does not take.
pub fn addressedType(call: *Call, file: TypedFile) Error!?[]const u8 {
    if (try mediaType(call.arena, file, null) == null) return null;
    return try checkedType(call, file, try described(call.arena, file), null);
}
