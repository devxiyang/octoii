//! The web app the node serves beside its protocol: the files of its build, in a folder of their own, each answered to
//! a GET of its path with the type its extension names, as a static file server answers — `/`, and any path of no
//! extension the folder holds no file at, such as the pairing page's, answered with the page, `index.html`, whose script
//! draws each; nothing outside the folder, nor a file whose name hides it. A file the build named by its content is
//! kept by the browser for good, as a new build names its files anew; the page is asked for again at each load. The
//! folder is found by its path at each request, as a static file server finds it, so a folder built anew is served as
//! it now is. Each answer closes its connection: a page loads its files once, and speaks to the node over its WebSocket
//! after.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Request = @import("Request.zig");

/// The folder of the app's files, by its absolute path.
folder: []const u8,

/// The largest file the app is served.
const file_bytes_max = 64 << 20;

/// The app whose files are in the folder at `path`, which is there now, by its absolute path in `arena`.
pub fn open(io: Io, arena: Allocator, path: []const u8) !App {
    const folder = try std.fs.path.resolve(arena, &.{ try std.process.currentPathAlloc(io, arena), path });
    var dir = try Io.Dir.cwd().openDir(io, folder, .{});
    dir.close(io);
    return .{ .folder = folder };
}

/// Answers `request` with the file its target names, read into memory of `gpa` while it is sent; not found where it
/// names none; a method other than GET and HEAD is not allowed.
pub fn respond(app: App, io: Io, gpa: Allocator, request: *Request) !void {
    if (request.method() != .GET and request.method() != .HEAD)
        return request.respond("", .{ .status = .method_not_allowed, .extra_headers = &.{.{ .name = "allow", .value = "GET, HEAD" }} });
    const asked = fileOf(request.target()) orelse return notFound(request);
    const name = if (try app.holds(io, gpa, asked) or std.fs.path.extension(asked).len > 0) asked else page;
    const path = try std.fs.path.join(gpa, &.{ app.folder, name });
    defer gpa.free(path);
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(file_bytes_max)) catch |err| switch (err) {
        error.FileNotFound, error.IsDir, error.NotDir, error.BadPathName => return notFound(request),
        else => return err,
    };
    defer gpa.free(bytes);
    try request.respond(bytes, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = typeOf(name) },
            .{ .name = "cache-control", .value = if (namedByContent(name)) "public, max-age=31536000, immutable" else "no-cache" },
            .{ .name = "x-content-type-options", .value = "nosniff" },
        },
    });
}

/// The app's page, whose script draws each of its pages.
const page = "index.html";

/// Whether the folder holds a file at `name`.
fn holds(app: App, io: Io, gpa: Allocator, name: []const u8) Allocator.Error!bool {
    const path = try std.fs.path.join(gpa, &.{ app.folder, name });
    defer gpa.free(path);
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

/// Whether the build named the file `name` by its content, as it names a chunk `chunk-<hash>.js`: its stem ends in a
/// dash and eight letters or digits of the hash.
fn namedByContent(name: []const u8) bool {
    const stem = std.fs.path.stem(name);
    if (stem.len < 9 or stem[stem.len - 9] != '-') return false;
    for (stem[stem.len - 8 ..]) |char| if (!std.ascii.isLower(char) and !std.ascii.isDigit(char)) return false;
    return true;
}

/// Answers `request` that the node serves nothing at its target.
pub fn notFound(request: *Request) !void {
    try request.respond("Not found\n", .{ .status = .not_found, .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }} });
}

/// The file a request's target names, by its path in the app's folder, the query left out: `index.html` for `/`; null
/// for a target that would leave the folder or names no plain file — an empty, `.` or `..` segment, a name beginning
/// with a dot, a backslash, an escape.
fn fileOf(target: []const u8) ?[]const u8 {
    const path = target[0 .. std.mem.indexOfAny(u8, target, "?#") orelse target.len];
    if (path.len == 0 or path[0] != '/') return null;
    const name = path[1..];
    if (name.len == 0) return page;
    if (std.mem.indexOfAny(u8, name, "\\%\x00") != null) return null;
    var segments = std.mem.splitScalar(u8, name, '/');
    while (segments.next()) |segment| if (segment.len == 0 or segment[0] == '.') return null;
    return name;
}

/// The type a file is served as, by its extension.
fn typeOf(name: []const u8) []const u8 {
    const extension = std.fs.path.extension(name);
    for (types) |each| if (std.mem.eql(u8, each[0], extension)) return each[1];
    return "application/octet-stream";
}

const types = [_]struct { []const u8, []const u8 }{
    .{ ".html", "text/html; charset=utf-8" },
    .{ ".js", "text/javascript; charset=utf-8" },
    .{ ".css", "text/css; charset=utf-8" },
    .{ ".json", "application/json" },
    .{ ".map", "application/json" },
    .{ ".svg", "image/svg+xml" },
    .{ ".png", "image/png" },
    .{ ".ico", "image/x-icon" },
    .{ ".woff2", "font/woff2" },
    .{ ".woff", "font/woff" },
    .{ ".wasm", "application/wasm" },
    .{ ".txt", "text/plain; charset=utf-8" },
};

test "a target names a file in the app's folder, its page for the root, never one outside or hidden" {
    try std.testing.expectEqualStrings("index.html", fileOf("/").?);
    try std.testing.expectEqualStrings("index.html", fileOf("/?token=abc").?);
    try std.testing.expectEqualStrings("main.js", fileOf("/main.js").?);
    try std.testing.expectEqualStrings("fonts/inter.woff2", fileOf("/fonts/inter.woff2?v=1").?);
    for ([_][]const u8{ "", "main.js", "/../token", "/a/../../b", "/./a", "/.env", "//a", "/a//b", "/a/", "/%2e%2e/a", "/a\\b" }) |target|
        try std.testing.expect(fileOf(target) == null);
}

test "a file the build named by its content is kept for good, and any other asked for again" {
    try std.testing.expect(namedByContent("chunk-rpefx3d6.js"));
    try std.testing.expect(namedByContent("assets/inter-a1b2c3d4.woff2"));
    try std.testing.expect(!namedByContent("index.html"));
    try std.testing.expect(!namedByContent("chunk-RPEFX3D6.js"));
    try std.testing.expect(!namedByContent("logo.svg"));
}

test "a file is served as its extension names" {
    try std.testing.expectEqualStrings("text/javascript; charset=utf-8", typeOf("chunk-x1.js"));
    try std.testing.expectEqualStrings("font/woff2", typeOf("a/b.woff2"));
    try std.testing.expectEqualStrings("application/octet-stream", typeOf("README"));
}

/// What the app answers to the HTTP request `sent`, written into `answer`.
fn answerOf(app: App, sent: []const u8, answer: []u8) ![]const u8 {
    var request: @import("auth.zig").Sent = undefined;
    try request.init(sent, answer);
    try app.respond(std.testing.io, std.testing.allocator, &request.request);
    return request.answered();
}

test "the app answers a GET with its file and its type, and what it does not hold as not found" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "index.html", .data = "<!doctype html>" });
    const folder = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(folder);
    const app: App = .{ .folder = folder };
    var buffer: [1024]u8 = undefined;
    const root = try answerOf(app, "GET /?from=here HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &buffer);
    try std.testing.expect(std.mem.startsWith(u8, root, "HTTP/1.1 200 OK\r\nconnection: close\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, root, "content-type: text/html; charset=utf-8\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, root, "cache-control: no-cache\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, root, "\r\n\r\n<!doctype html>"));
    const missing = try answerOf(app, "GET /main.js HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &buffer);
    try std.testing.expect(std.mem.startsWith(u8, missing, "HTTP/1.1 404 Not Found\r\n"));
    // A path of no extension is one of the app's pages: the page answers it, its script drawing it.
    const pairing = try answerOf(app, "GET /pair HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &buffer);
    try std.testing.expect(std.mem.endsWith(u8, pairing, "\r\n\r\n<!doctype html>"));
    const outside = try answerOf(app, "GET /../index.html HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n", &buffer);
    try std.testing.expect(std.mem.startsWith(u8, outside, "HTTP/1.1 404 Not Found\r\n"));
    const posted = try answerOf(app, "POST / HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 0\r\n\r\n", &buffer);
    try std.testing.expect(std.mem.startsWith(u8, posted, "HTTP/1.1 405 Method Not Allowed\r\n"));
}
