//! A video job priced by its model's SKUs, as a video's protocol prices one its provider gives no cost for. SKUs are
//! each provider's own names, read by their words: of the SKUs priced by the second, the one whose resolution, sound,
//! mode (text or image to video), video input and continuation fit the request, the most particular first, times the
//! request's `duration`; each image read at the SKU that prices input images; and at least a SKU's minimum per
//! generation. A name with the word `cents` in it is in cents. A job whose duration or fitting SKU is not known, or
//! whose SKUs price tokens or megapixels, has no cost.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vocabulary = @import("vocabulary");
const Usage = vocabulary.Usage;
const VideoRequest = vocabulary.videos.VideoRequest;
const Model = @import("../catalogue/model.zig").Model;

/// A SKU read: its price in US dollars and the words of its name.
const Sku = struct {
    dollars: f64,
    /// Its name in lower case, its words joined by `_`.
    name: []const u8,
    words: []const []const u8,

    fn has(sku: Sku, word: []const u8) bool {
        for (sku.words) |each| if (std.mem.eql(u8, each, word)) return true;
        return false;
    }

    fn hasStarting(sku: Sku, prefix: []const u8) bool {
        for (sku.words) |each| if (std.mem.startsWith(u8, each, prefix)) return true;
        return false;
    }

    fn says(sku: Sku, words: []const u8) bool {
        return std.mem.indexOf(u8, sku.name, words) != null;
    }

    /// Whether it prices each image a job reads.
    fn imageInput(sku: Sku) bool {
        return sku.says("image_input") or sku.says("reference_image");
    }
};

/// What a request asks for, as the SKUs' words name it.
const Asked = struct {
    resolution: ?[]const u8,
    sound: bool,
    images: u64,
    video_input: bool,
    continues: bool,
};

/// The seconds a job of `request` makes and the images it reads, as Octoii's account, with the cost its model's SKUs
/// give; without SKUs, the seconds alone.
pub fn pricedUsage(arena: Allocator, model: *const Model, request: *const VideoRequest) Allocator.Error!Usage {
    const asked = try askedOf(arena, model, request);
    var usage: Usage = .{ .seconds = if (request.duration) |seconds| @floatFromInt(seconds) else null, .images_read = if (asked.images == 0) null else asked.images };
    var skus: std.ArrayList(Sku) = .empty;
    if (model.pricing_skus) |given| {
        var it = given.map.iterator();
        while (it.next()) |entry| if (try skuOf(arena, entry.key_ptr.*, entry.value_ptr.*)) |sku| try skus.append(arena, sku);
    }
    const seconds = request.duration orelse return usage;
    const per_second = bestPerSecond(skus.items, asked) orelse return usage;
    var per_image: f64 = 0;
    var minimum: f64 = 0;
    for (skus.items) |sku| {
        if (sku.imageInput() and per_image == 0) per_image = sku.dollars;
        if (sku.has("minimum") and minimum == 0) minimum = sku.dollars;
    }
    usage.cost = @max(@as(f64, @floatFromInt(seconds)) * per_second.dollars + @as(f64, @floatFromInt(asked.images)) * per_image, minimum);
    return usage;
}

fn askedOf(arena: Allocator, model: *const Model, request: *const VideoRequest) Allocator.Error!Asked {
    var images: u64 = if (request.frame_images) |frames| frames.len else 0;
    var video_input = false;
    for (request.input_references orelse &.{}) |reference| switch (reference) {
        .image => images += 1,
        .video => video_input = true,
        .audio => {},
    };
    return .{
        .resolution = if (request.resolution) |resolution| try std.ascii.allocLowerString(arena, resolution) else null,
        // A model that makes sound makes it unless the request says not to.
        .sound = request.generate_audio orelse (model.generate_audio == true),
        .images = images,
        .video_input = video_input,
        .continues = request.previous_job_id != null,
    };
}

/// The SKU `name` priced at `price`, in dollars; null where its price cannot be read.
fn skuOf(arena: Allocator, name: []const u8, price: []const u8) Allocator.Error!?Sku {
    const amount = std.fmt.parseFloat(f64, price) catch return null;
    if (!std.math.isFinite(amount) or amount < 0) return null;
    const lowered = try std.ascii.allocLowerString(arena, name);
    std.mem.replaceScalar(u8, lowered, '-', '_');
    var words: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, lowered, '_');
    while (it.next()) |word| try words.append(arena, word);
    const sku: Sku = .{ .dollars = amount, .name = lowered, .words = words.items };
    return if (sku.has("cents")) .{ .dollars = amount / 100, .name = lowered, .words = words.items } else sku;
}

/// The SKU priced by the second that fits `asked` best: of those none of whose words conflicts with the request, the
/// one with most words that match it; null where the SKUs price tokens or megapixels, or none fits.
fn bestPerSecond(skus: []const Sku, asked: Asked) ?Sku {
    for (skus) |sku| if (sku.hasStarting("token") or sku.hasStarting("megapixel")) return null;
    var best: ?struct { sku: Sku, score: u32 } = null;
    for (skus) |sku| {
        if (!sku.hasStarting("second") or sku.imageInput()) continue;
        const score = fit(sku, asked) orelse continue;
        if (best == null or score > best.?.score) best = .{ .sku = sku, .score = score };
    }
    return if (best) |found| found.sku else null;
}

/// How many of `sku`'s words match `asked`; null where one conflicts with it.
fn fit(sku: Sku, asked: Asked) ?u32 {
    const checks = [_]?bool{
        resolutionMatches(sku, asked),
        if (sku.says("with_audio")) asked.sound else if (sku.says("without_audio")) !asked.sound else null,
        if (sku.says("image_to_video")) asked.images > 0 else if (sku.says("text_to_video")) asked.images == 0 else null,
        if (sku.says("video_input")) asked.video_input else null,
        if (sku.says("continuation")) asked.continues else null,
    };
    var score: u32 = 0;
    for (checks) |check| if (check) |holds| {
        if (!holds) return null;
        score += 1;
    };
    return score;
}

/// Whether `sku`'s resolution, a word such as `720p` or `2k`, is the one asked for; null where it names none.
fn resolutionMatches(sku: Sku, asked: Asked) ?bool {
    for (sku.words) |word| {
        if (word.len < 2) continue;
        const unit = word[word.len - 1];
        if (unit != 'p' and unit != 'k') continue;
        const number = word[0 .. word.len - 1];
        const numeric = for (number) |char| {
            if (!std.ascii.isDigit(char) and char != '.') break false;
        } else number.len > 0 and std.ascii.isDigit(number[0]);
        if (!numeric) continue;
        return if (asked.resolution) |resolution| std.mem.eql(u8, resolution, word) else false;
    }
    return null;
}

test "a job is priced by the second at the SKU that fits it best, its images read, and at least its minimum" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    var skus: std.json.ArrayHashMap([]const u8) = .{};
    try skus.map.put(arena, "duration_seconds_720p_with_audio", "0.10");
    try skus.map.put(arena, "duration_seconds_720p_without_audio", "0.05");
    try skus.map.put(arena, "duration_seconds_1080p_with_audio", "0.20");
    try skus.map.put(arena, "image_input", "0.01");
    try skus.map.put(arena, "minimum_cents", "60");
    const model: Model = .{ .id = "v", .name = "V", .architecture = .{ .input_modalities = &.{}, .output_modalities = &.{} }, .generate_audio = true, .pricing_skus = skus, .octoii = .{ .provider = "p", .kinds = &.{.video} } };
    const sounding = try pricedUsage(arena, &model, &.{ .model = "p/v", .duration = 5, .resolution = "720P" });
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), sounding.cost.?, 1e-12);
    const silent = try pricedUsage(arena, &model, &.{ .model = "p/v", .duration = 12, .resolution = "720p", .generate_audio = false, .frame_images = &.{.{ .image_url = .{ .url = "https://a" }, .frame_type = .first_frame }} });
    try std.testing.expectApproxEqAbs(@as(f64, 0.61), silent.cost.?, 1e-12);
    try std.testing.expectEqual(@as(?u64, 1), silent.images_read);
    try std.testing.expectEqual(null, (try pricedUsage(arena, &model, &.{ .model = "p/v", .resolution = "720p" })).cost);
}
