//! ai: Octoii's access to models. One vocabulary in and out — its own module, `vocabulary`, which Siphon imports
//! alone — and here everything else: the catalogue of models, the seam drivers speak through, the text path that
//! checks, prepares and sends a request and makes its stream whole, and each provider's driver.
pub const vocabulary = @import("vocabulary");
pub const failure = @import("failure.zig");
pub const Failure = failure.Failure;
pub const model = @import("catalogue/model.zig");
pub const Model = model.Model;
pub const catalogue = @import("catalogue/catalogue.zig");
pub const pricing = @import("catalogue/pricing.zig");
pub const facts = @import("catalogue/facts.zig");
pub const refresh = @import("catalogue/refresh.zig");
pub const driver = @import("driver.zig");
pub const Models = @import("Models.zig");
pub const text = struct {
    pub const stream = @import("text/stream.zig");
    pub const check = @import("text/check.zig");
    pub const prepare = @import("text/prepare.zig");
    pub const files = @import("text/files.zig");
    pub const items = @import("text/items.zig");
    pub const image_size = @import("text/image_size.zig");
};
pub const media = struct {
    pub const stream = @import("media/stream.zig");
    pub const references = @import("media/references.zig");
    pub const usage = @import("media/usage.zig");
    pub const images = @import("media/images.zig");
    pub const speech = @import("media/speech.zig");
    pub const transcriptions = @import("media/transcriptions.zig");
    pub const videos = @import("media/videos.zig");
    pub const decisions = @import("media/decisions.zig");
    pub const voices = @import("media/voices.zig");
    pub const realtime = @import("media/realtime.zig");
};
pub const wire = struct {
    pub const http = @import("wire/http.zig");
    pub const json = @import("wire/json.zig");
    pub const responses = @import("wire/responses.zig");
    pub const source = @import("wire/source.zig");
    pub const tags = @import("wire/tags.zig");
    pub const listings = @import("wire/listings.zig");
    pub const chat_completions = @import("wire/chat_completions.zig");
    pub const signed_in = @import("wire/signed_in.zig");
    pub const video_skus = @import("wire/video_skus.zig");
    pub const query = @import("wire/query.zig");
    pub const realtime_session = @import("wire/realtime/session.zig");
    pub const realtime_items = @import("wire/realtime/items.zig");
};
pub const drivers = struct {
    pub const openai = @import("drivers/openai.zig");
    pub const openrouter = @import("drivers/openrouter.zig");
    pub const anthropic = @import("drivers/anthropic.zig");
    pub const xai = @import("drivers/xai.zig");
    pub const deepseek = @import("drivers/deepseek.zig");
    pub const meta = @import("drivers/meta.zig");
    pub const zai = @import("drivers/zai.zig");
    pub const chat_completions = @import("drivers/chat_completions.zig");
    pub const ollama = @import("drivers/ollama.zig");
    pub const lmstudio = @import("drivers/lmstudio.zig");
    pub const google = @import("drivers/google.zig");
    pub const chatgpt = @import("drivers/chatgpt.zig");
    pub const deepgram = @import("drivers/deepgram.zig");
};
pub const testing = struct {
    pub const Host = @import("testing/host.zig").Host;
    pub const Fake = @import("testing/fake.zig").Fake;
    pub const fake = @import("testing/fake.zig");
    pub const contract = @import("testing/contract.zig");
    pub const fixtures = @import("testing/fixtures.zig");
    pub const issuer = @import("testing/issuer.zig");
    pub const host_models = @import("testing/host_models.zig");
    pub const scripted_socket = @import("testing/scripted_socket.zig");
};

test {
    analyseAll(failure);
    analyseAll(model);
    analyseAll(catalogue);
    analyseAll(pricing);
    analyseAll(facts);
    analyseAll(refresh);
    analyseAll(driver);
    analyseAll(@import("ids.zig"));
    analyseAll(Models);
    analyseAll(text.stream);
    analyseAll(text.check);
    analyseAll(text.prepare);
    analyseAll(text.files);
    analyseAll(text.items);
    analyseAll(text.image_size);
    analyseAll(media.references);
    analyseAll(media.usage);
    analyseAll(media.images);
    analyseAll(media.speech);
    analyseAll(media.transcriptions);
    analyseAll(media.videos);
    analyseAll(media.decisions);
    analyseAll(media.voices);
    analyseAll(media.realtime);
    analyseAll(wire.query);
    analyseAll(wire.realtime_session);
    analyseAll(wire.realtime_items);
    analyseAll(@import("drivers/deepgram/realtime.zig"));
    analyseAll(@import("drivers/xai/realtime.zig"));
    analyseAll(@import("drivers/openai/realtime.zig"));
    analyseAll(wire.http);
    analyseAll(wire.json);
    analyseAll(wire.responses);
    analyseAll(wire.source);
    analyseAll(wire.tags);
    analyseAll(wire.listings);
    analyseAll(wire.chat_completions);
    analyseAll(wire.chat_completions.messages);
    analyseAll(wire.chat_completions.stream);
    analyseAll(drivers.openai);
    analyseAll(drivers.openrouter);
    analyseAll(drivers.anthropic);
    analyseAll(drivers.xai);
    analyseAll(drivers.deepseek);
    analyseAll(drivers.meta);
    analyseAll(drivers.zai);
    analyseAll(drivers.chat_completions);
    analyseAll(drivers.ollama);
    analyseAll(drivers.lmstudio);
    analyseAll(drivers.google);
    analyseAll(drivers.chatgpt);
    analyseAll(drivers.deepgram);
    analyseAll(drivers.chatgpt.sign_in);
    analyseAll(wire.signed_in);
    analyseAll(wire.video_skus);
    analyseAll(@import("drivers/google/stream.zig"));
    analyseAll(@import("drivers/anthropic/wire.zig"));
    analyseAll(@import("drivers/anthropic/request.zig"));
    analyseAll(@import("drivers/anthropic/stream.zig"));
    analyseAll(testing);
    _ = @import("text/tests.zig");
    _ = @import("drivers/openai_tests.zig");
    _ = @import("drivers/openrouter_tests.zig");
    _ = @import("drivers/anthropic_tests.zig");
    _ = @import("drivers/responses_providers_tests.zig");
    _ = @import("drivers/chat_completions_tests.zig");
    _ = @import("drivers/local_servers_tests.zig");
    _ = @import("drivers/google_tests.zig");
    _ = @import("drivers/chatgpt_tests.zig");
    _ = @import("drivers/openrouter_media_tests.zig");
    _ = @import("drivers/openai_media_tests.zig");
    _ = @import("drivers/xai_media_tests.zig");
    _ = @import("drivers/google_media_tests.zig");
    _ = @import("drivers/deepgram_tests.zig");
    _ = @import("drivers/video_tests.zig");
    _ = @import("drivers/realtime_tests.zig");
}

/// Every public declaration of `T` and of the containers in it analysed, so that what no test calls yet still
/// compiles.
fn analyseAll(comptime T: type) void {
    const std = @import("std");
    inline for (comptime std.meta.declarations(T)) |name| {
        const declaration = @field(T, name);
        if (@TypeOf(declaration) == type) {
            switch (@typeInfo(declaration)) {
                .@"struct", .@"union", .@"enum" => analyseAll(declaration),
                else => {},
            }
        } else _ = &declaration;
    }
}
