//! What a message or a call's output holds: input content from the caller, output content from the model, and the
//! text of reasoning. Each file the caller gives has a source of its bytes — inline, at an address, or a stored file
//! under its `octoii` — and decodes only with one.
const foundation = @import("foundation");
const Variants = foundation.json.Variants;
const extensions = @import("extensions.zig");
const FileExtension = extensions.FileExtension;

/// Text, or parts: what a message, a call's output or a request's input is given as.
pub fn TextOr(comptime Part: type) type {
    return union(enum) {
        text: []const u8,
        parts: []const Part,

        const variants = Variants(@This(), "type");
        pub const jsonParse = variants.jsonParse;
        pub const jsonParseFromValue = variants.jsonParseFromValue;
        pub const jsonStringify = variants.jsonStringify;
    };
}

/// How long OpenAI keeps a prefix in its prompt cache: `30m`, its default, or `12h`.
pub const PromptCacheTtl = enum { @"30m", @"12h" };

/// A mark that ends a prefix of the prompt to keep in the provider's cache.
pub const PromptCacheBreakpoint = struct {
    mode: enum { explicit } = .explicit,
    /// How long the provider keeps this prefix, in place of the request's `prompt_cache_options.ttl`.
    ttl: ?PromptCacheTtl = null,
};

/// Text the caller gives the model.
pub const InputText = struct {
    type: enum { input_text } = .input_text,
    text: []const u8,
    prompt_cache_breakpoint: ?PromptCacheBreakpoint = null,
};

/// How closely a model looks at an image.
pub const ImageDetail = enum { auto, high, low, original };

/// An image the caller gives the model: an `https` address or a data URL, or a stored file under `octoii`.
pub const InputImage = struct {
    type: enum { input_image } = .input_image,
    detail: ImageDetail,
    /// An `https` address or a data URL; left out for a stored file.
    image_url: ?[]const u8 = null,
    octoii: ?FileExtension = null,

    pub fn valid(image: InputImage) bool {
        return image.image_url != null or extensions.stored(image.octoii);
    }
};

/// A file the caller gives the model, such as a PDF: inline, at an address, or a stored file under `octoii`.
pub const InputFile = struct {
    type: enum { input_file } = .input_file,
    /// The file inline, as a data URL.
    file_data: ?[]const u8 = null,
    /// The file's `https` address.
    file_url: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    octoii: ?FileExtension = null,

    pub fn valid(file: InputFile) bool {
        return file.file_data != null or file.file_url != null or extensions.stored(file.octoii);
    }
};

/// The encodings of audio the caller gives the model.
pub const AudioFormat = enum { mp3, wav };

/// Audio the caller gives the model: base64 in `input_audio.data`, or a stored file under `octoii`.
pub const InputAudio = struct {
    type: enum { input_audio } = .input_audio,
    input_audio: struct {
        /// The audio, base64; left out for a stored file.
        data: ?[]const u8 = null,
        format: AudioFormat,
    },
    octoii: ?FileExtension = null,

    pub fn valid(audio: InputAudio) bool {
        return audio.input_audio.data != null or extensions.stored(audio.octoii);
    }
};

/// Video the caller gives the model: an `https` address or a data URL in `video_url`, or a stored file under `octoii`.
pub const InputVideo = struct {
    type: enum { input_video } = .input_video,
    /// An `https` address or a data URL; left out for a stored file.
    video_url: ?[]const u8 = null,
    /// `agentic` lets the provider process the video as it sees fit; `static` samples frames at a fixed rate.
    processing: ?enum { agentic, static } = null,
    octoii: ?FileExtension = null,

    pub fn valid(video: InputVideo) bool {
        return video.video_url != null or extensions.stored(video.octoii);
    }
};

/// What user, developer and system messages and calls' outputs hold.
pub const InputContent = union(enum) {
    input_text: InputText,
    input_image: InputImage,
    input_file: InputFile,
    input_audio: InputAudio,
    input_video: InputVideo,

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// A web page an answer cites, by the characters of the text that cite it.
pub const UrlCitation = struct {
    type: enum { url_citation } = .url_citation,
    url: []const u8,
    title: []const u8,
    start_index: u32,
    end_index: u32,
    content: ?[]const u8 = null,
};

/// A file at the provider an answer cites.
pub const FileCitation = struct {
    type: enum { file_citation } = .file_citation,
    file_id: []const u8,
    filename: []const u8,
    index: u32,
};

/// A file at the provider an answer names by its path.
pub const FilePath = struct {
    type: enum { file_path } = .file_path,
    file_id: []const u8,
    index: u32,
};

/// What an answer's text refers to.
pub const Annotation = union(enum) {
    url_citation: UrlCitation,
    file_citation: FileCitation,
    file_path: FilePath,

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// One of the likeliest tokens at a place in an answer.
pub const TopLogprob = struct {
    token: []const u8,
    logprob: f64,
    /// The token's bytes, each as a number.
    bytes: []const u16,
};

/// A token of an answer with its log probability, and the likeliest tokens in its place.
pub const Logprob = struct {
    token: []const u8,
    logprob: f64,
    bytes: []const u16,
    top_logprobs: []const TopLogprob,
};

/// Text a model wrote.
pub const OutputText = struct {
    type: enum { output_text } = .output_text,
    text: []const u8,
    annotations: ?[]const Annotation = null,
    logprobs: ?[]const Logprob = null,
};

/// An image a model made, at an address or as a data URL; it has no stored form.
pub const OutputImage = struct {
    type: enum { output_image } = .output_image,
    image_url: []const u8,
};

/// A model's refusal to answer, in its words.
pub const Refusal = struct {
    type: enum { refusal } = .refusal,
    refusal: []const u8,
};

/// What an assistant message holds.
pub const OutputContent = union(enum) {
    output_text: OutputText,
    output_image: OutputImage,
    refusal: Refusal,

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// Text of a model's reasoning, as its provider shows it.
pub const ReasoningText = struct {
    type: enum { reasoning_text } = .reasoning_text,
    text: []const u8,
};

/// A summary of a model's reasoning.
pub const SummaryText = struct {
    type: enum { summary_text } = .summary_text,
    text: []const u8,
};
