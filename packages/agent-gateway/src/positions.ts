/**
 * Where a conversation stands in an agent's session, found by what the conversation says, as a prefix cache finds what
 * it holds: each message's fingerprint — what a client sends back as it was answered, its words, its calls and their
 * results, never the thinking a model signs — chained from the system prompt, so a prefix of a conversation is known by
 * the hash of its last message. A position names the session and the entry of its transcript a prefix ends at, kept
 * as a line of a file, so a gateway started again goes on where its sessions stood; it is a cache only — a prefix it
 * lacks is told the agent whole again, as a replica that lost its offset syncs in full.
 */
import { createHash } from "node:crypto";
import { Type } from "typebox";
import { type Block, blocksOf, type Message } from "./anthropic.ts";
import { LineFile } from "./lines.ts";
import { matches } from "./schema.ts";

/** Where a prefix of a conversation ends in an agent's session: the session, and the entry of its transcript. */
export type Position = { readonly session: string; readonly entry: string };

/** The hash a conversation under `system` begins from, before its first message. */
export function rootOf(system: string): string {
	return hashOf(`system\u0000${system}`);
}

/** The hash of the prefix that ends with `message`, after the prefix whose hash is `before`. */
export function nextOf(before: string, message: Message): string {
	return hashOf(`${before}\u0000${canonical(fingerprintOf(message))}`);
}

/** The hashes of `messages`' prefixes under `system`: the i-th that of the first i + 1 messages. */
export function chainOf(system: string, messages: readonly Message[]): readonly string[] {
	const chain: string[] = [];
	let at = rootOf(system);
	for (const message of messages) {
		at = nextOf(at, message);
		chain.push(at);
	}
	return chain;
}

/** What of a message is the same however a client sends it back: who said it, then each block's own, adjacent texts as one. */
function fingerprintOf(message: Message): readonly unknown[] {
	const parts: unknown[] = [message.role];
	for (const block of blocksOf(message)) {
		const part = partOf(block);
		if (part === undefined) continue;
		const last = parts.at(-1);
		if (part[0] === "text" && Array.isArray(last) && last[0] === "text") {
			parts[parts.length - 1] = ["text", `${String(last[1])}${String(part[1])}`];
		} else parts.push(part);
	}
	return parts;
}

/** What of a block is kept whatever way it comes back: none of a model's thinking, whose signature is its own. */
function partOf(block: Block): readonly unknown[] | undefined {
	switch (block.type) {
		case "text":
			return ["text", block.text];
		case "image":
			return ["image", block.source.type === "base64" ? hashOf(block.source.data) : block.source.url];
		case "document":
			return ["document", block.source];
		case "tool_use":
			return ["tool_use", block.id, block.name, block.input];
		case "tool_result": {
			const content = block.content === undefined ? [] : typeof block.content === "string" ? [["text", block.content]] : block.content.map(partOf);
			return ["tool_result", block.tool_use_id, block.is_error === true, content];
		}
		case "thinking":
		case "redacted_thinking":
			return undefined;
	}
}

/** `value` as JSON whose objects' keys are in order, so one value has one text however it was written. */
export function canonical(value: unknown): string {
	if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
	if (value !== null && typeof value === "object") {
		const entries = Object.entries(value)
			.filter(([, each]) => each !== undefined)
			.toSorted(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
		return `{${entries.map(([key, each]) => `${JSON.stringify(key)}:${canonical(each)}`).join(",")}}`;
	}
	return JSON.stringify(value) ?? "null";
}

function hashOf(text: string): string {
	return createHash("sha256").update(text).digest("hex");
}

/** How many positions are kept: past it, the oldest go, and the file is written again with the rest. */
const POSITIONS_MAX = 20_000;

/**
 * The positions known, by the hash of the prefix each ends; kept in a file of lines where one is given. Each session's
 * tip is the position it was last written to — the last line of it — which a conversation goes on from in place;
 * from any earlier one, the session is forked, as a conversation that parted from it at that point is another.
 */
export class Positions {
	readonly #file: LineFile | undefined;
	readonly #known = new Map<string, Position>();
	/** Each session's tip, by the hash of the prefix it ends. */
	readonly #tips = new Map<string, string>();

	private constructor(file: LineFile | undefined) {
		this.#file = file;
	}

	/** The positions the file at `path` keeps, none where there is no file yet; kept in memory alone with no path. */
	static async open(path: string | undefined): Promise<Positions> {
		if (path === undefined) return new Positions(undefined);
		const { file, values } = await LineFile.open(path);
		const positions = new Positions(file);
		for (const value of values) {
			if (!matches(LineSchema, value)) continue;
			positions.#known.delete(value.hash);
			positions.#known.set(value.hash, { session: value.session, entry: value.entry });
			positions.#tips.set(value.session, value.hash);
		}
		return positions;
	}

	/** Where the prefix of hash `hash` ends; none where no session holds it. */
	get(hash: string): Position | undefined {
		return this.#known.get(hash);
	}

	/** Whether the prefix of hash `hash` ends at its session's tip: where the session was last written to. */
	isTip(hash: string): boolean {
		const position = this.#known.get(hash);
		return position !== undefined && this.#tips.get(position.session) === hash;
	}

	/** Keeps that the prefix of hash `hash` ends at `position`. */
	async set(hash: string, position: Position): Promise<void> {
		this.#known.delete(hash);
		this.#known.set(hash, position);
		this.#tips.set(position.session, hash);
		while (this.#known.size > POSITIONS_MAX) {
			const oldest = this.#known.keys().next().value;
			if (oldest === undefined) break;
			this.#known.delete(oldest);
		}
		if (this.#file === undefined) return;
		if (this.#file.lines >= 2 * POSITIONS_MAX) return this.#rewrite();
		await this.#file.append(lineOf(hash, position));
	}

	/** Forgets every position in the session `session`, which is gone. */
	async forget(session: string): Promise<void> {
		const before = this.#known.size;
		for (const [hash, position] of this.#known) if (position.session === session) this.#known.delete(hash);
		this.#tips.delete(session);
		if (this.#known.size !== before) await this.#rewrite();
	}

	/** Writes the file again with the positions kept alone. */
	async #rewrite(): Promise<void> {
		await this.#file?.rewrite([...this.#known].map(([hash, position]) => lineOf(hash, position)));
	}
}

function lineOf(hash: string, position: Position): object {
	return { hash, session: position.session, entry: position.entry };
}

const LineSchema = Type.Object({ hash: Type.String(), session: Type.String(), entry: Type.String() });
