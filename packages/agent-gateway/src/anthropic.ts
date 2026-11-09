/**
 * Anthropic's Messages API as the gateway reads and answers it: the request a client sends — its system, messages and
 * their blocks, tools, thinking and output settings — read by schema at the edge; the events of the stream that
 * answers it; and an error as the API writes one. Only what the gateway reads is checked; whatever else an object
 * carries is passed over.
 */
import type { BetaRawMessageStreamEvent } from "@anthropic-ai/sdk/resources/beta/messages/messages";
import { type Static, Type } from "typebox";

/** A value JSON writes. */
export type Json = string | number | boolean | null | readonly Json[] | { readonly [key: string]: Json };

const TextBlockSchema = Type.Object({ type: Type.Literal("text"), text: Type.String() });

const ImageSourceSchema = Type.Union([
	Type.Object({
		type: Type.Literal("base64"),
		media_type: Type.Union([Type.Literal("image/jpeg"), Type.Literal("image/png"), Type.Literal("image/gif"), Type.Literal("image/webp")]),
		data: Type.String(),
	}),
	Type.Object({ type: Type.Literal("url"), url: Type.String() }),
]);

const ImageBlockSchema = Type.Object({ type: Type.Literal("image"), source: ImageSourceSchema });

const DocumentBlockSchema = Type.Object({
	type: Type.Literal("document"),
	source: Type.Union([
		Type.Object({ type: Type.Literal("base64"), media_type: Type.Literal("application/pdf"), data: Type.String() }),
		Type.Object({ type: Type.Literal("text"), media_type: Type.Literal("text/plain"), data: Type.String() }),
		Type.Object({ type: Type.Literal("url"), url: Type.String() }),
	]),
	title: Type.Optional(Type.String()),
});

const ToolResultBlockSchema = Type.Object({
	type: Type.Literal("tool_result"),
	tool_use_id: Type.String(),
	content: Type.Optional(Type.Union([Type.String(), Type.Array(Type.Union([TextBlockSchema, ImageBlockSchema, DocumentBlockSchema]))])),
	is_error: Type.Optional(Type.Boolean()),
});

const BlockSchema = Type.Union([
	TextBlockSchema,
	ImageBlockSchema,
	DocumentBlockSchema,
	Type.Object({ type: Type.Literal("tool_use"), id: Type.String(), name: Type.String(), input: Type.Unknown() }),
	ToolResultBlockSchema,
	Type.Object({ type: Type.Literal("thinking"), thinking: Type.String(), signature: Type.String() }),
	Type.Object({ type: Type.Literal("redacted_thinking"), data: Type.String() }),
]);

/** A block of a message. */
export type Block = Static<typeof BlockSchema>;

/** A result of a call, as a block. */
export type ResultBlock = Static<typeof ToolResultBlockSchema>;

const MessageSchema = Type.Object({
	role: Type.Union([Type.Literal("user"), Type.Literal("assistant")]),
	content: Type.Union([Type.String(), Type.Array(BlockSchema)]),
});

/** A message: who said it, and what — its words alone, or its blocks. */
export type Message = Static<typeof MessageSchema>;

const ToolSchema = Type.Object({
	name: Type.String(),
	description: Type.Optional(Type.String()),
	input_schema: Type.Optional(Type.Unknown()),
	type: Type.Optional(Type.String()),
});

/** A tool the client offers: a function, by its name, with the JSON Schema of its input; or one of the API's own, by its type. */
export type Tool = Static<typeof ToolSchema>;

/** What a client asks. */
export const RequestSchema = Type.Object({
	model: Type.String(),
	max_tokens: Type.Optional(Type.Number()),
	system: Type.Optional(Type.Union([Type.String(), Type.Array(TextBlockSchema)])),
	messages: Type.Array(MessageSchema),
	tools: Type.Optional(Type.Array(ToolSchema)),
	tool_choice: Type.Optional(
		Type.Object({
			type: Type.Union([Type.Literal("auto"), Type.Literal("any"), Type.Literal("tool"), Type.Literal("none")]),
			name: Type.Optional(Type.String()),
		}),
	),
	thinking: Type.Optional(
		Type.Object({
			type: Type.Union([Type.Literal("enabled"), Type.Literal("adaptive"), Type.Literal("disabled")]),
			budget_tokens: Type.Optional(Type.Number()),
		}),
	),
	output_config: Type.Optional(
		Type.Object({
			effort: Type.Optional(Type.String()),
			format: Type.Optional(Type.Object({ type: Type.Literal("json_schema"), schema: Type.Record(Type.String(), Type.Unknown()) })),
		}),
	),
	stream: Type.Optional(Type.Boolean()),
});

export type Request = Static<typeof RequestSchema>;

/** One event of a stream that answers a request, as the API sends it — and Claude Code gives it. */
export type StreamEvent = BetaRawMessageStreamEvent;

/** An error's type, as the API names it, by the status it comes with. */
export type ErrorType =
	| "invalid_request_error"
	| "authentication_error"
	| "permission_error"
	| "not_found_error"
	| "rate_limit_error"
	| "api_error"
	| "overloaded_error";

/** The status an error of `type` comes with. */
export function statusOf(type: ErrorType): number {
	switch (type) {
		case "invalid_request_error":
			return 400;
		case "authentication_error":
			return 401;
		case "permission_error":
			return 403;
		case "not_found_error":
			return 404;
		case "rate_limit_error":
			return 429;
		case "overloaded_error":
			return 529;
		case "api_error":
			return 500;
	}
}

/** An error as the API answers one, before any stream: its status and body. */
export function errorResponse(type: ErrorType, message: string, headers: Readonly<Record<string, string>> = {}): Response {
	return Response.json({ type: "error", error: { type, message } }, { status: statusOf(type), headers });
}

/** An event as a server-sent event's lines: its type, then its data, then the blank line that ends it. */
export function sse(type: string, data: object): string {
	return `event: ${type}\ndata: ${JSON.stringify(data)}\n\n`;
}

/** The blocks of a message: its words alone as one text block. */
export function blocksOf(message: Message): readonly Block[] {
	return typeof message.content === "string" ? [{ type: "text", text: message.content }] : message.content;
}

/** The text of a system prompt: its blocks' texts, a blank line between. */
export function systemText(system: Request["system"]): string {
	if (system === undefined) return "";
	if (typeof system === "string") return system;
	return system.map((block) => block.text).join("\n\n");
}
