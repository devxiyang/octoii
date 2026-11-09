/**
 * What a live session is fed and what it waits on: the words it is given, a message at a time; and the calls of the
 * client's tools Claude Code makes, held — never run — till their results come. Claude Code runs them one at a time,
 * none being read-only, and its hook before each names the model's call, which the call's handler cannot see: so the
 * handler takes the id the hook named last.
 */
import type { SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import type { Block, ResultBlock } from "./anthropic.ts";

/** The words a session is given, a message at a time, till it ends. */
export class Input implements AsyncIterable<SDKUserMessage> {
	readonly #queue: SDKUserMessage[] = [];
	#wake: (() => void) | undefined;
	#ended = false;

	push(content: readonly Block[]): void {
		this.#queue.push({ type: "user", parent_tool_use_id: null, message: { role: "user", content: [...content] } });
		this.#wake?.();
	}

	end(): void {
		this.#ended = true;
		this.#wake?.();
	}

	async *[Symbol.asyncIterator](): AsyncIterator<SDKUserMessage> {
		for (;;) {
			const next = this.#queue.shift();
			if (next !== undefined) {
				yield next;
				continue;
			}
			if (this.#ended) return;
			await new Promise<void>((resolve) => {
				this.#wake = resolve;
			});
			this.#wake = undefined;
		}
	}
}

/** The words a call held is answered with where its session ends first. */
const ENDED = "The session ended before the call's result came.";

/** The calls a session holds, each by the id of the model's call, till its result is given. */
export class Held {
	/** The call Claude Code is about to run, as its hook named it. */
	#next: string | undefined;
	readonly #holding = new Map<string, (result: CallToolResult) => void>();
	/** Results given before their calls were run, as the next is run only once the last is answered. */
	readonly #given = new Map<string, CallToolResult>();
	#onHolding: (() => void) | undefined;
	#ended = false;

	/** Claude Code is about to run the call `id`. */
	announce(id: string): void {
		this.#next = id;
	}

	/** A call's handler: held till its result is given, or given at once where it came first. */
	take(): Promise<CallToolResult> {
		const id = this.#next;
		this.#next = undefined;
		if (id === undefined) return Promise.resolve(failed("The call came with no id to hold it by."));
		if (this.#ended) return Promise.resolve(failed(ENDED));
		const given = this.#given.get(id);
		if (given !== undefined) {
			this.#given.delete(id);
			return Promise.resolve(given);
		}
		return new Promise((resolve) => {
			this.#holding.set(id, resolve);
			this.#onHolding?.();
		});
	}

	/** Gives the call `id` its result: to its handler where it is held, else kept till it is run. */
	give(id: string, result: CallToolResult): void {
		const resolve = this.#holding.get(id);
		if (resolve === undefined) return void this.#given.set(id, result);
		this.#holding.delete(id);
		resolve(result);
	}

	isHolding(): boolean {
		return this.#holding.size > 0;
	}

	/** Settles once a call is held. */
	whenHolding(): Promise<void> {
		if (this.isHolding()) return Promise.resolve();
		return new Promise((resolve) => {
			this.#onHolding = () => {
				this.#onHolding = undefined;
				resolve();
			};
		});
	}

	/** Answers every call held, and every one to come, that the session ended. */
	endAll(): void {
		this.#ended = true;
		for (const resolve of this.#holding.values()) resolve(failed(ENDED));
		this.#holding.clear();
	}
}

function failed(words: string): CallToolResult {
	return { content: [{ type: "text", text: words }], isError: true };
}

/** A result block as an MCP tool's result: its words and images, and whether it failed. */
export function resultOf(block: ResultBlock): CallToolResult {
	if (typeof block.content === "string") return { content: [{ type: "text", text: block.content }], isError: block.is_error === true };
	return { content: (block.content ?? []).map(resultContentOf), isError: block.is_error === true };
}

/** A block of a result as an MCP tool's content: words and images as themselves, anything else written out. */
function resultContentOf(block: NonNullable<Exclude<ResultBlock["content"], string>>[number]): CallToolResult["content"][number] {
	if (block.type === "text") return { type: "text", text: block.text };
	if (block.type === "image" && block.source.type === "base64") return { type: "image", data: block.source.data, mimeType: block.source.media_type };
	return { type: "text", text: JSON.stringify(block) };
}
