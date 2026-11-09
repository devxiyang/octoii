/**
 * A live conversation with Claude Code — one process of it — answering one request at a time: given the results of
 * the calls it holds and the words past where it stands, it streams the message it answers with; then, once the
 * message ended, it settles where it stands — holding the calls the message asked for, or done with its turn — and
 * keeps that position, so a session closed later is resumed there. A message that called a tool the client never
 * offered leaves the session to answer itself, which no request follows: it is closed, and keeps no position.
 */
import type { HookCallback, McpSdkServerConfigWithInstance, Options, Query, SDKMessage, SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { Type } from "typebox";
import { type Block, errorResponse, type ErrorType, type ResultBlock, sse, type Tool } from "./anthropic.ts";
import { Answering, SERVER } from "./answering.ts";
import { Held, Input, resultOf } from "./held.ts";
import type { Positions } from "./positions.ts";
import { matches } from "./schema.ts";

/** Starts a conversation with Claude Code: the SDK's `query`, or a test's. */
export type Run = (params: { readonly prompt: AsyncIterable<SDKUserMessage>; readonly options: Options }) => Query;

/** What a session is started with. */
export type SessionOptions = {
	readonly run: Run;
	readonly positions: Positions;
	/** What Claude Code runs with, but its tools. */
	readonly options: Options;
	/** The client's tools, on the session's MCP server. */
	readonly tools: readonly Tool[];
	/** How long a call may be held before Claude Code gives up on it. */
	readonly holdMs: number;
	/** What a session must be asked with to go on: its model, how it thinks, its tools. */
	readonly settings: string;
	/** The time, in milliseconds since the epoch. */
	readonly now: () => number;
};

/** What Claude is told of a tool's result past which it is cut; the client bounds its own already. */
const RESULT_CHARS_MAX = 500_000;

/** Where a session stands: answering a request; holding the calls its last answer asked for; done, waiting for words. */
type State = "answering" | "held" | "idle" | "closed";

export class Session {
	readonly settings: string;
	readonly #query: Query;
	readonly #input = new Input();
	readonly #held = new Held();
	readonly #positions: Positions;
	readonly #now: () => number;
	readonly #tools: ReadonlySet<string>;
	readonly #messages: AsyncIterator<SDKMessage>;
	/** A read of the next message begun and not yet taken, as a call was held first. */
	#reading: Promise<IteratorResult<SDKMessage>> | undefined;
	/** The session's id in Claude Code, as its first message tells it. */
	#id: string | undefined;
	#state: State = "answering";
	/** The hash of the conversation the session stands at, as its last answer left it. */
	position: string | undefined;
	/** When it was last asked, by its clock. */
	usedAt: number;
	/** Settles once the session stands still after its last answer. */
	settled: Promise<void> = Promise.resolve();

	constructor(options: SessionOptions) {
		this.settings = options.settings;
		this.#now = options.now;
		this.usedAt = options.now();
		this.#positions = options.positions;
		this.#tools = new Set(options.tools.map((tool) => tool.name));
		this.#query = options.run({
			prompt: this.#input,
			options: {
				...options.options,
				mcpServers: options.tools.length === 0 ? {} : { [SERVER]: serverOf(options.tools, this.#held, options.holdMs) },
				hooks: { PreToolUse: [{ hooks: [this.#announce] }] },
			},
		});
		this.#messages = this.#query[Symbol.asyncIterator]();
	}

	/** Claude Code's hook before it runs a call: the call is announced to what holds it. */
	readonly #announce: HookCallback = async (given) => {
		if (given.hook_event_name === "PreToolUse") this.#held.announce(given.tool_use_id);
		return {};
	};

	/** The session's id in Claude Code, once it told it. */
	get id(): string | undefined {
		return this.#id;
	}

	isAskable(): boolean {
		return this.#state === "held" || this.#state === "idle";
	}

	isClosed(): boolean {
		return this.#state === "closed";
	}

	/**
	 * Answers, as a stream of the API's events: given `results` for the calls it holds — or as the first blocks of its
	 * next message where it holds none — and `rest`; `end` the conversation's hash with them.
	 */
	answer(results: readonly ResultBlock[], rest: readonly Block[], end: string, signal: AbortSignal): Promise<Response> {
		this.#give(results, rest);
		const stream = new Answering(end, this.#tools);
		this.settled = this.#stream(stream, signal);
		return stream.response;
	}

	/** Answers aside: the stream as it comes; or, for JSON of a schema, the value the session ends with, as one text. */
	async answerAside(results: readonly ResultBlock[], rest: readonly Block[], signal: AbortSignal, structured: boolean): Promise<Response> {
		this.#give(results, rest);
		if (!structured) {
			const stream = new Answering(undefined, this.#tools);
			this.settled = this.#stream(stream, signal);
			return stream.response;
		}
		for (;;) {
			const message = await this.#next(signal);
			if (message === undefined) return errorResponse("api_error", "Claude Code ended without an answer.");
			if (message.type !== "result") continue;
			if (message.subtype !== "success" || message.is_error) return errorResponse(resultErrorType(message), resultWords(message));
			return structuredResponse(message.structured_output, message.usage);
		}
	}

	/** Gives the session what it is asked: results to the calls it holds, the rest as a message of the person's. */
	#give(results: readonly ResultBlock[], rest: readonly Block[]): void {
		this.#state = "answering";
		this.usedAt = this.#now();
		if (this.#held.isHolding()) {
			for (const result of results) this.#held.give(result.tool_use_id, resultOf(result));
			if (rest.length > 0) this.#input.push(rest);
			return;
		}
		if (results.length + rest.length > 0) this.#input.push([...results, ...rest]);
	}

	/** Streams the API message the session sends next, then settles where the session stands after it. */
	async #stream(stream: Answering, signal: AbortSignal): Promise<void> {
		const onAbort = (): void => this.close();
		signal.addEventListener("abort", onAbort, { once: true });
		try {
			while (!stream.ended) {
				const message = await this.#next(signal);
				if (message === undefined) return stream.fail("api_error", "Claude Code ended before it answered.");
				this.#take(message, stream);
			}
			if (stream.diverged) return this.close();
			await this.#settle(stream);
		} catch (error) {
			stream.fail("api_error", error instanceof Error ? error.message : String(error));
			this.close();
		} finally {
			signal.removeEventListener("abort", onAbort);
		}
	}

	/** Takes one message of the session into the answer it streams. */
	#take(message: SDKMessage, stream: Answering): void {
		switch (message.type) {
			case "system":
				if (message.subtype === "init") this.#id = message.session_id;
				return;
			case "stream_event":
				if (message.parent_tool_use_id === null) stream.event(message.event);
				return;
			case "assistant":
				if (message.parent_tool_use_id !== null) return;
				if (message.error !== undefined) return stream.fail(assistantErrorType(message.error), wordsOf(message.message.content));
				stream.entry(message.message.id, message.uuid);
				return;
			case "result":
				this.#state = "idle";
				if (!stream.ended) stream.fail(resultErrorType(message), resultWords(message));
				return;
			default:
				return;
		}
	}

	/**
	 * Once the answer's message ended, waits for the session to stand still — holding the calls the message asked for,
	 * or done with its turn — then keeps where the conversation ends in it.
	 */
	async #settle(stream: Answering): Promise<void> {
		this.position = stream.position;
		while (this.#state === "answering") {
			if (stream.asked && this.#held.isHolding()) {
				this.#state = "held";
				break;
			}
			const message = await this.#nextOrHeld();
			if (message === undefined) return this.close();
			if (message !== "held") this.#take(message, stream);
		}
		const entry = stream.lastEntry();
		if (this.#id !== undefined && entry !== undefined && stream.position !== undefined) {
			await this.#positions.set(stream.position, { session: this.#id, entry });
		}
	}

	/** The session's next message; none where it ended or the request was cancelled. */
	async #next(signal?: AbortSignal): Promise<SDKMessage | undefined> {
		if (signal?.aborted || this.#state === "closed") return undefined;
		const reading = this.#reading ?? this.#messages.next();
		this.#reading = undefined;
		const read = await reading;
		return read.done ? undefined : read.value;
	}

	/** The session's next message, or `held` where a call is held first — the read kept for the next to take. */
	async #nextOrHeld(): Promise<SDKMessage | "held" | undefined> {
		if (this.#state === "closed") return undefined;
		const reading = this.#reading ?? this.#messages.next();
		this.#reading = reading;
		const first = await Promise.race([reading, this.#held.whenHolding().then(() => "held" as const)]);
		if (first === "held") return "held";
		this.#reading = undefined;
		return first.done ? undefined : first.value;
	}

	/** Ends the session's process, its held calls answered that it ended. */
	close(): void {
		if (this.#state === "closed") return;
		this.#state = "closed";
		this.#held.endAll();
		this.#input.end();
		this.#query.close();
	}
}

/** What MCP takes as a tool's input schema: a JSON Schema of an object. */
const ObjectSchemaSchema = Type.Object({ type: Type.Literal("object") });

/** The MCP server the client's `tools` are on: each as the client declared it, each call held till its result comes. */
function serverOf(tools: readonly Tool[], held: Held, holdMs: number): McpSdkServerConfigWithInstance {
	const server = new McpServer({ name: SERVER, version: "0.0.1" }, { capabilities: { tools: {} } });
	const listed = tools.map((tool) => ({
		name: tool.name,
		description: tool.description ?? "",
		inputSchema: matches(ObjectSchemaSchema, tool.input_schema) ? tool.input_schema : { type: "object" as const },
		// Claude Code runs a tool that is not read-only alone, so each call's handler takes the id its hook named last.
		annotations: { readOnlyHint: false },
		_meta: { "anthropic/alwaysLoad": true, "anthropic/maxResultSizeChars": RESULT_CHARS_MAX },
	}));
	server.server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: listed }));
	server.server.setRequestHandler(CallToolRequestSchema, async () => held.take());
	return { type: "sdk", name: SERVER, instance: server, timeout: holdMs };
}

/** A response of one text block, the JSON a session ended with, as a stream of the API's events. */
function structuredResponse(value: unknown, usage: object): Response {
	const text = JSON.stringify(value ?? null);
	const events = [
		{ type: "message_start", message: { id: `msg_${crypto.randomUUID()}`, type: "message", role: "assistant", content: [], usage } },
		{ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
		{ type: "content_block_delta", index: 0, delta: { type: "text_delta", text } },
		{ type: "content_block_stop", index: 0 },
		{ type: "message_delta", delta: { stop_reason: "end_turn" }, usage },
		{ type: "message_stop" },
	];
	return new Response(events.map((event) => sse(event.type, event)).join(""), { status: 200, headers: { "content-type": "text/event-stream" } });
}

/** The words of an API message's text blocks. */
function wordsOf(content: readonly { readonly type: string }[]): string {
	return content.flatMap((block) => ("text" in block && typeof block.text === "string" ? [block.text] : [])).join("\n");
}

/** The API's error type for an error Claude Code's assistant message carries. */
function assistantErrorType(error: string): ErrorType {
	switch (error) {
		case "authentication_failed":
		case "oauth_org_not_allowed":
		case "verification_required":
		case "cloud_credential_error":
			return "authentication_error";
		case "account_on_hold":
		case "billing_error":
			return "permission_error";
		case "rate_limit":
			return "rate_limit_error";
		case "overloaded":
			return "overloaded_error";
		case "invalid_request":
		case "max_output_tokens":
			return "invalid_request_error";
		case "model_not_found":
			return "not_found_error";
		default:
			return "api_error";
	}
}

/** The API's error type for a result that ended a turn short, by the status its API call failed with. */
function resultErrorType(result: Extract<SDKMessage, { type: "result" }>): ErrorType {
	const status = result.subtype === "success" ? result.api_error_status : undefined;
	if (status === 401) return "authentication_error";
	if (status === 403) return "permission_error";
	if (status === 429) return "rate_limit_error";
	if (status === 529) return "overloaded_error";
	return "api_error";
}

/** What a result says of how its turn ended. */
function resultWords(result: Extract<SDKMessage, { type: "result" }>): string {
	if (result.subtype === "success") return result.result || "Claude Code ended its turn without an answer.";
	return result.errors.join("; ") || `Claude Code ended its turn: ${result.subtype}`;
}
