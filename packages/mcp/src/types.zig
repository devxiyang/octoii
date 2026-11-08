//! The MCP data a client reads and writes, after the current specification (revision 2026-07-28) and the
//! session-based revisions before it, as far as a client uses them. Fields keep the protocol's names; JSON the client
//! does not act on — a tool's schemas, metadata, an elicitation's form — is kept as it came.
const std = @import("std");
const Value = std.json.Value;
const foundation = @import("foundation");
const Variants = foundation.json.Variants;

/// A client's or a server's name and version.
pub const Implementation = struct {
    name: []const u8,
    version: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    websiteUrl: ?[]const u8 = null,
};

pub const Icon = struct {
    src: []const u8,
    mimeType: ?[]const u8 = null,
    sizes: ?[]const []const u8 = null,
    theme: ?enum { light, dark } = null,
};

pub const Annotations = struct {
    audience: ?[]const enum { user, assistant } = null,
    priority: ?f64 = null,
    lastModified: ?[]const u8 = null,
};

pub const Resource = struct {
    uri: []const u8,
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
    size: ?f64 = null,
    annotations: ?Annotations = null,
    icons: ?[]const Icon = null,
};

pub const ResourceTemplate = struct {
    uriTemplate: []const u8,
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
    annotations: ?Annotations = null,
};

/// A resource's contents: text, or bytes as base64.
pub const ResourceContents = union(enum) {
    text: struct { uri: []const u8, mimeType: ?[]const u8 = null, text: []const u8 },
    blob: struct { uri: []const u8, mimeType: ?[]const u8 = null, blob: []const u8 },

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

/// What a tool, a resource or a prompt gives: text, an image, audio, a link to a resource, or a resource embedded.
pub const ContentBlock = union(enum) {
    text: struct { type: enum { text } = .text, text: []const u8, annotations: ?Annotations = null },
    image: struct { type: enum { image } = .image, data: []const u8, mimeType: []const u8, annotations: ?Annotations = null },
    audio: struct { type: enum { audio } = .audio, data: []const u8, mimeType: []const u8, annotations: ?Annotations = null },
    resource_link: struct {
        type: enum { resource_link } = .resource_link,
        uri: []const u8,
        name: []const u8,
        title: ?[]const u8 = null,
        description: ?[]const u8 = null,
        mimeType: ?[]const u8 = null,
        size: ?f64 = null,
        annotations: ?Annotations = null,
        icons: ?[]const Icon = null,
    },
    resource: struct { type: enum { resource } = .resource, resource: ResourceContents, annotations: ?Annotations = null },

    const variants = Variants(@This(), "type");
    pub const jsonParse = variants.jsonParse;
    pub const jsonParseFromValue = variants.jsonParseFromValue;
    pub const jsonStringify = variants.jsonStringify;
};

pub const ToolAnnotations = struct {
    title: ?[]const u8 = null,
    readOnlyHint: ?bool = null,
    destructiveHint: ?bool = null,
    idempotentHint: ?bool = null,
    openWorldHint: ?bool = null,
};

pub const Tool = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    /// The arguments' JSON Schema, an object at its root; a property may carry `x-mcp-header`.
    inputSchema: Value,
    /// The JSON Schema `structuredContent` matches.
    outputSchema: ?Value = null,
    annotations: ?ToolAnnotations = null,
    icons: ?[]const Icon = null,
    _meta: ?Value = null,
};

/// A tool call's result: content for the model, a JSON value for programs, and whether the tool failed.
pub const CallToolResult = struct {
    content: []const ContentBlock,
    structuredContent: ?Value = null,
    isError: ?bool = null,
};

pub const ReadResourceResult = struct { contents: []const ResourceContents };

pub const PromptArgument = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    required: ?bool = null,
};

pub const Prompt = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    arguments: ?[]const PromptArgument = null,
};

pub const PromptMessage = struct { role: enum { user, assistant }, content: ContentBlock };

pub const GetPromptResult = struct { description: ?[]const u8 = null, messages: []const PromptMessage };

/// What a completion completes: a prompt's argument, or a resource template's.
pub const CompletionReference = union(enum) {
    prompt: struct { type: enum { @"ref/prompt" } = .@"ref/prompt", name: []const u8 },
    resource: struct { type: enum { @"ref/resource" } = .@"ref/resource", uri: []const u8 },

    pub fn jsonStringify(reference: CompletionReference, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (reference) {
            inline else => |given| try writer.write(given),
        }
    }
};

pub const CompleteResult = struct { values: []const []const u8, total: ?f64 = null, hasMore: ?bool = null };

/// A page of a list, with the cursor of the next page where there is one.
pub fn Page(comptime T: type) type {
    return struct { items: []const T, nextCursor: ?[]const u8 = null };
}

/// How severe a log message is, least first.
pub const LoggingLevel = enum { debug, info, notice, warning, @"error", critical, alert, emergency };

pub const LogMessage = struct { level: LoggingLevel, logger: ?[]const u8 = null, data: Value };

pub const Root = struct { uri: []const u8, name: ?[]const u8 = null };

/// What a server asks the person through the client: to fill a form of a flat object of primitive fields, or to open a
/// link where the client sees nothing.
pub const ElicitRequest = union(enum) {
    form: struct { message: []const u8, requestedSchema: Value },
    url: struct { message: []const u8, url: []const u8, elicitationId: ?[]const u8 = null },
};

/// The person's answer: accepted, with the form's content in form mode; declined; or cancelled without a choice.
pub const ElicitResult = union(enum) {
    /// The form's content, an object of strings, numbers, booleans and lists of strings; none for a link.
    accept: ?Value,
    decline,
    cancel,
};

/// A question a stateless server asks within a request: an elicitation, or the client's roots.
pub const InputRequest = union(enum) {
    elicitation: ElicitRequest,
    roots,
};

/// A question and the key its answer goes under.
pub const KeyedRequest = struct { key: []const u8, request: InputRequest };

/// A stateless server's questions within a request, and its opaque `requestState`.
pub const InputRequired = struct {
    requests: []const KeyedRequest,
    requestState: ?[]const u8 = null,

    /// Whether the questions ask the person anything, as an elicitation does; its roots the client gives itself.
    pub fn asksPerson(input: InputRequired) bool {
        for (input.requests) |each| if (each.request == .elicitation) return true;
        return false;
    }
};

/// An elicitation's answer and the key it goes under.
pub const KeyedAnswer = struct { key: []const u8, answer: ElicitResult };

/// What a request is sent again with: the questions handed back, and the answers to their elicitations.
pub const InputAnswers = struct { required: InputRequired, answers: []const KeyedAnswer };

/// Which change notifications a subscription asks for.
pub const SubscriptionFilter = struct {
    toolsListChanged: bool = false,
    promptsListChanged: bool = false,
    resourcesListChanged: bool = false,
    resourceSubscriptions: []const []const u8 = &.{},

    pub fn jsonStringify(filter: SubscriptionFilter, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        try writer.beginObject();
        inline for (.{ "toolsListChanged", "promptsListChanged", "resourcesListChanged" }) |name| if (@field(filter, name)) {
            try writer.objectField(name);
            try writer.write(true);
        };
        if (filter.resourceSubscriptions.len > 0) {
            try writer.objectField("resourceSubscriptions");
            try writer.write(filter.resourceSubscriptions);
        }
        try writer.endObject();
    }
};

/// A progress notification's numbers.
pub const Progress = struct { progress: f64, total: ?f64 = null, message: ?[]const u8 = null };
