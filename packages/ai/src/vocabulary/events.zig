//! The events a text response streams: the response's own, each output item's, the content, reasoning, calls and web
//! searches within them, OpenRouter's `response.debug`, ChatGPT's `response.metadata`, and `error`. Each carries its `sequence_number`, from 0 without
//! a gap, and the last is `response.completed`, `response.incomplete` or `response.failed`, carrying the whole response.
const foundation = @import("foundation");
const Raw = foundation.json.Raw;
const Variants = foundation.json.Variants;
const content = @import("content.zig");
const FailureExtension = @import("extensions.zig").FailureExtension;
const OutputItem = @import("items.zig").OutputItem;
const Response = @import("response.zig").Response;

/// The response has begun.
pub const ResponseCreatedEvent = struct {
    type: enum { @"response.created" } = .@"response.created",
    response: Response,
    sequence_number: u64,
};

/// The response is under way.
pub const ResponseInProgressEvent = struct {
    type: enum { @"response.in_progress" } = .@"response.in_progress",
    response: Response,
    sequence_number: u64,
};

/// The response ended whole: the last event.
pub const ResponseCompletedEvent = struct {
    type: enum { @"response.completed" } = .@"response.completed",
    response: Response,
    sequence_number: u64,
};

/// The response ended short of whole, as its `incomplete_details` say: the last event.
pub const ResponseIncompleteEvent = struct {
    type: enum { @"response.incomplete" } = .@"response.incomplete",
    response: Response,
    sequence_number: u64,
};

/// The response failed, as its `error` says, after an `error` event: the last event.
pub const ResponseFailedEvent = struct {
    type: enum { @"response.failed" } = .@"response.failed",
    response: Response,
    sequence_number: u64,
};

/// An output item has begun at its position.
pub const OutputItemAddedEvent = struct {
    type: enum { @"response.output_item.added" } = .@"response.output_item.added",
    item: OutputItem,
    output_index: u32,
    sequence_number: u64,
};

/// An output item has ended, whole, replacing what streamed of it.
pub const OutputItemDoneEvent = struct {
    type: enum { @"response.output_item.done" } = .@"response.output_item.done",
    item: OutputItem,
    output_index: u32,
    sequence_number: u64,
};

/// A part of a message's or a reasoning item's content.
pub const ContentPart = union(enum) {
    output_text: content.OutputText,
    output_image: content.OutputImage,
    refusal: content.Refusal,
    reasoning_text: content.ReasoningText,

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// A content part has begun.
pub const ContentPartAddedEvent = struct {
    type: enum { @"response.content_part.added" } = .@"response.content_part.added",
    item_id: []const u8,
    output_index: u32,
    sequence_number: u64,
    content_index: u32,
    part: ContentPart,
};

/// A content part has ended, whole.
pub const ContentPartDoneEvent = struct {
    type: enum { @"response.content_part.done" } = .@"response.content_part.done",
    item_id: []const u8,
    output_index: u32,
    sequence_number: u64,
    content_index: u32,
    part: ContentPart,
};

/// A likely token at a place in streamed text.
pub const StreamTopLogprob = struct {
    token: ?[]const u8 = null,
    logprob: ?f64 = null,
    bytes: ?[]const u16 = null,
};

/// A token of streamed text with its log probability.
pub const StreamLogprob = struct {
    token: []const u8,
    logprob: f64,
    bytes: ?[]const u16 = null,
    top_logprobs: ?[]const StreamTopLogprob = null,
};

/// More of an answer's text.
pub const OutputTextDeltaEvent = struct {
    type: enum { @"response.output_text.delta" } = .@"response.output_text.delta",
    item_id: []const u8,
    output_index: u32,
    sequence_number: u64,
    content_index: u32,
    delta: []const u8,
    logprobs: []const StreamLogprob,
};

/// An answer's text, whole.
pub const OutputTextDoneEvent = struct {
    type: enum { @"response.output_text.done" } = .@"response.output_text.done",
    item_id: []const u8,
    output_index: u32,
    sequence_number: u64,
    content_index: u32,
    text: []const u8,
    logprobs: []const StreamLogprob,
};

/// An annotation of an answer's text, such as a citation.
pub const OutputTextAnnotationAddedEvent = struct {
    type: enum { @"response.output_text.annotation.added" } = .@"response.output_text.annotation.added",
    item_id: []const u8,
    output_index: u32,
    sequence_number: u64,
    content_index: u32,
    annotation_index: u32,
    annotation: content.Annotation,
};

/// More of a refusal.
pub const RefusalDeltaEvent = struct {
    type: enum { @"response.refusal.delta" } = .@"response.refusal.delta",
    item_id: []const u8,
    output_index: u32,
    sequence_number: u64,
    content_index: u32,
    delta: []const u8,
};

/// A refusal, whole.
pub const RefusalDoneEvent = struct {
    type: enum { @"response.refusal.done" } = .@"response.refusal.done",
    item_id: []const u8,
    output_index: u32,
    sequence_number: u64,
    content_index: u32,
    refusal: []const u8,
};

/// More of a reasoning item's text.
pub const ReasoningTextDeltaEvent = struct {
    type: enum { @"response.reasoning_text.delta" } = .@"response.reasoning_text.delta",
    item_id: []const u8,
    output_index: u32,
    sequence_number: u64,
    content_index: u32,
    delta: []const u8,
};

/// A reasoning item's text, whole.
pub const ReasoningTextDoneEvent = struct {
    type: enum { @"response.reasoning_text.done" } = .@"response.reasoning_text.done",
    item_id: []const u8,
    output_index: u32,
    sequence_number: u64,
    content_index: u32,
    text: []const u8,
};

/// A part of a reasoning item's summary has begun.
pub const ReasoningSummaryPartAddedEvent = struct {
    type: enum { @"response.reasoning_summary_part.added" } = .@"response.reasoning_summary_part.added",
    item_id: []const u8,
    output_index: u32,
    sequence_number: u64,
    summary_index: u32,
    part: content.SummaryText,
};

/// A part of a reasoning item's summary has ended, whole.
pub const ReasoningSummaryPartDoneEvent = struct {
    type: enum { @"response.reasoning_summary_part.done" } = .@"response.reasoning_summary_part.done",
    item_id: []const u8,
    output_index: u32,
    sequence_number: u64,
    summary_index: u32,
    part: content.SummaryText,
};

/// More of a reasoning summary's text.
pub const ReasoningSummaryTextDeltaEvent = struct {
    type: enum { @"response.reasoning_summary_text.delta" } = .@"response.reasoning_summary_text.delta",
    item_id: []const u8,
    output_index: u32,
    sequence_number: u64,
    summary_index: u32,
    delta: []const u8,
};

/// A reasoning summary's text, whole.
pub const ReasoningSummaryTextDoneEvent = struct {
    type: enum { @"response.reasoning_summary_text.done" } = .@"response.reasoning_summary_text.done",
    item_id: []const u8,
    output_index: u32,
    sequence_number: u64,
    summary_index: u32,
    text: []const u8,
};

/// More of a function call's arguments.
pub const FunctionCallArgumentsDeltaEvent = struct {
    type: enum { @"response.function_call_arguments.delta" } = .@"response.function_call_arguments.delta",
    item_id: []const u8,
    output_index: u32,
    sequence_number: u64,
    delta: []const u8,
};

/// A function call's arguments, whole.
pub const FunctionCallArgumentsDoneEvent = struct {
    type: enum { @"response.function_call_arguments.done" } = .@"response.function_call_arguments.done",
    item_id: []const u8,
    output_index: u32,
    sequence_number: u64,
    name: []const u8,
    arguments: []const u8,
};

/// More of a custom tool call's input.
pub const CustomToolCallInputDeltaEvent = struct {
    type: enum { @"response.custom_tool_call_input.delta" } = .@"response.custom_tool_call_input.delta",
    item_id: []const u8,
    output_index: u32,
    sequence_number: u64,
    delta: []const u8,
};

/// A custom tool call's input, whole.
pub const CustomToolCallInputDoneEvent = struct {
    type: enum { @"response.custom_tool_call_input.done" } = .@"response.custom_tool_call_input.done",
    item_id: []const u8,
    output_index: u32,
    sequence_number: u64,
    input: []const u8,
};

/// A web search has begun.
pub const WebSearchCallInProgressEvent = struct {
    type: enum { @"response.web_search_call.in_progress" } = .@"response.web_search_call.in_progress",
    item_id: []const u8,
    output_index: u32,
    sequence_number: u64,
};

/// A web search is searching.
pub const WebSearchCallSearchingEvent = struct {
    type: enum { @"response.web_search_call.searching" } = .@"response.web_search_call.searching",
    item_id: []const u8,
    output_index: u32,
    sequence_number: u64,
};

/// A web search has ended.
pub const WebSearchCallCompletedEvent = struct {
    type: enum { @"response.web_search_call.completed" } = .@"response.web_search_call.completed",
    item_id: []const u8,
    output_index: u32,
    sequence_number: u64,
};

/// What OpenRouter reports of how it handled the request, for a request with `debug`.
pub const DebugEvent = struct {
    type: enum { @"response.debug" } = .@"response.debug",
    debug: struct {
        /// The request body OpenRouter sent the provider: an object.
        echo_upstream_body: ?Raw = null,
        /// When a step of the request happened.
        timings: ?struct {
            event: enum { adapter_request, upstream_headers_received, first_token_received, upstream_body_ended },
            /// Milliseconds since the Unix epoch.
            epoch_ms: i64,
            /// Milliseconds since the request began.
            start_ms: i64,
        } = null,
    },
    sequence_number: u64,
};

/// A failure that ends the response, which `response.failed` follows; the failure is under `octoii`.
pub const ErrorEvent = struct {
    type: enum { @"error" } = .@"error",
    /// The provider's code, or the failure's kind where it gives none.
    code: []const u8,
    message: []const u8,
    /// The request field the failure concerns, where the provider names one.
    param: ?[]const u8 = null,
    octoii: FailureExtension,
    sequence_number: u64,
};

/// What ChatGPT reports beside the answer as it streams: its moderation of the prompt and of what the model wrote.
pub const MetadataEvent = struct {
    type: enum { @"response.metadata" } = .@"response.metadata",
    response_id: []const u8,
    /// As ChatGPT reports it: an object.
    metadata: Raw,
    sequence_number: u64,
};

/// An event of a text response's stream.
pub const ResponseStreamEvent = union(enum) {
    created: ResponseCreatedEvent,
    in_progress: ResponseInProgressEvent,
    completed: ResponseCompletedEvent,
    incomplete: ResponseIncompleteEvent,
    failed: ResponseFailedEvent,
    output_item_added: OutputItemAddedEvent,
    output_item_done: OutputItemDoneEvent,
    content_part_added: ContentPartAddedEvent,
    content_part_done: ContentPartDoneEvent,
    output_text_delta: OutputTextDeltaEvent,
    output_text_done: OutputTextDoneEvent,
    annotation_added: OutputTextAnnotationAddedEvent,
    refusal_delta: RefusalDeltaEvent,
    refusal_done: RefusalDoneEvent,
    reasoning_text_delta: ReasoningTextDeltaEvent,
    reasoning_text_done: ReasoningTextDoneEvent,
    summary_part_added: ReasoningSummaryPartAddedEvent,
    summary_part_done: ReasoningSummaryPartDoneEvent,
    summary_text_delta: ReasoningSummaryTextDeltaEvent,
    summary_text_done: ReasoningSummaryTextDoneEvent,
    function_call_arguments_delta: FunctionCallArgumentsDeltaEvent,
    function_call_arguments_done: FunctionCallArgumentsDoneEvent,
    custom_tool_call_input_delta: CustomToolCallInputDeltaEvent,
    custom_tool_call_input_done: CustomToolCallInputDoneEvent,
    web_search_call_in_progress: WebSearchCallInProgressEvent,
    web_search_call_searching: WebSearchCallSearchingEvent,
    web_search_call_completed: WebSearchCallCompletedEvent,
    debug: DebugEvent,
    metadata: MetadataEvent,
    @"error": ErrorEvent,

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};
