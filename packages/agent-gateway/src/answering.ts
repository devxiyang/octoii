/**
 * One answer as it streams: the events of the model's message, as Anthropic's API sends them, passed on as they come —
 * the client's tools by the names it gave them — its response begun with its first event, or as the API's error where
 * the answer fails first; and the message it answers with, kept as the client will send it back, so the conversation
 * is known by its hash once the message is in it.
 */
import { type Block, errorResponse, type ErrorType, type Json, type Message, sse, type StreamEvent } from "./anthropic.ts";
import { nextOf } from "./positions.ts";

/** What Claude Code puts before the name of each tool of the client's MCP server. */
export const SERVER = "tools";
export const PREFIX = `mcp__${SERVER}__`;

/** A block of the message as it streams in: its words, or its call — the input's JSON as it comes. */
type Streamed =
	| { readonly kind: "text"; text: string }
	| { readonly kind: "call"; readonly id: string; readonly name: string; json: string }
	| { readonly kind: "other" };

export class Answering {
	readonly response: Promise<Response>;
	#respond!: (response: Response) => void;
	#controller: ReadableStreamDefaultController<Uint8Array> | undefined;
	readonly #encoder = new TextEncoder();
	/** The hash of the conversation it answers; none for an answer aside from it. */
	readonly #end: string | undefined;
	/** The names of the client's tools. */
	readonly #tools: ReadonlySet<string>;
	started = false;
	ended = false;
	/** Whether the message asked for calls, which its session holds once it ends. */
	asked = false;
	/** Whether the message called a tool the client did not offer, which Claude Code answers itself and goes on. */
	diverged = false;
	/** The hash of the conversation once the message is in it. */
	position: string | undefined;
	#messageId: string | undefined;
	readonly #blocks: Streamed[] = [];
	#lastEntry: string | undefined;

	constructor(end: string | undefined, tools: ReadonlySet<string>) {
		this.#end = end;
		this.#tools = tools;
		this.response = new Promise((resolve) => {
			this.#respond = resolve;
		});
	}

	/** Passes on one event of the message as the client reads it. */
	event(event: StreamEvent): void {
		if (this.ended) return;
		const told = this.#track(event);
		if (!this.started) this.#begin();
		this.#controller?.enqueue(this.#encoder.encode(sse(told.type, told)));
		if (event.type === "message_stop") this.#finish();
	}

	/** Notes the transcript's entry a block of the message `id` was written as: the last is where it is resumed. */
	entry(id: string, uuid: string): void {
		if (id === this.#messageId) this.#lastEntry = uuid;
	}

	lastEntry(): string | undefined {
		return this.#lastEntry;
	}

	/** Ends the answer as failed: as the API's error before its stream began, else as an error event in it. */
	fail(type: ErrorType, words: string): void {
		if (this.ended) return;
		this.ended = true;
		if (!this.started) return this.#respond(errorResponse(type, words));
		this.#controller?.enqueue(this.#encoder.encode(sse("error", { type: "error", error: { type, message: words } })));
		this.#controller?.close();
	}

	#begin(): void {
		this.started = true;
		const body = new ReadableStream<Uint8Array>({
			start: (controller) => {
				this.#controller = controller;
			},
		});
		this.#respond(new Response(body, { status: 200, headers: { "content-type": "text/event-stream", "cache-control": "no-cache" } }));
	}

	/** Ends the answer with its message, which the conversation is known by from now. */
	#finish(): void {
		this.ended = true;
		this.#controller?.close();
		if (this.#end === undefined || this.diverged) return;
		const message: Message = { role: "assistant", content: this.#blocks.flatMap(blockOf) };
		this.position = nextOf(this.#end, message);
	}

	/** Keeps what `event` adds to the message, and gives it as the client reads it: its calls by their own names. */
	#track(event: StreamEvent): StreamEvent {
		switch (event.type) {
			case "message_start":
				this.#messageId = event.message.id;
				return event;
			case "content_block_start": {
				const block = event.content_block;
				if (block.type === "text") this.#blocks[event.index] = { kind: "text", text: block.text };
				if (block.type !== "tool_use") {
					this.#blocks[event.index] ??= { kind: "other" };
					return event;
				}
				const name = block.name.startsWith(PREFIX) ? block.name.slice(PREFIX.length) : block.name;
				if (!this.#tools.has(name)) this.diverged = true;
				this.#blocks[event.index] = { kind: "call", id: block.id, name, json: "" };
				return { ...event, content_block: { ...block, name } };
			}
			case "content_block_delta": {
				const streamed = this.#blocks[event.index];
				if (streamed?.kind === "text" && event.delta.type === "text_delta") streamed.text += event.delta.text;
				if (streamed?.kind === "call" && event.delta.type === "input_json_delta") streamed.json += event.delta.partial_json;
				return event;
			}
			case "message_delta":
				this.asked = event.delta.stop_reason === "tool_use";
				return event;
			default:
				return event;
		}
	}
}

/** A block of the message as the client keeps it: its words, and its calls with their input; its thinking left out. */
function blockOf(streamed: Streamed): Block[] {
	if (streamed.kind === "text") return [{ type: "text", text: streamed.text }];
	if (streamed.kind === "call") return [{ type: "tool_use", id: streamed.id, name: streamed.name, input: inputOf(streamed.json) }];
	return [];
}

/** A call's input, as its JSON says; the text itself where it is no JSON, as a call cut off may leave it. */
function inputOf(json: string): Json {
	if (json === "") return {};
	try {
		return JSON.parse(json);
	} catch {
		return json;
	}
}
