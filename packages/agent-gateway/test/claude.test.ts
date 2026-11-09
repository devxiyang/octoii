/**
 * Claude through Claude Code, as a test plays Claude Code: each process it would start is played here — what it is
 * fed is heard, what it says is said by the test — and the client's tools are called on the session's own MCP server,
 * as Claude Code calls them, through its hook first.
 */
import { describe, expect, it } from "bun:test";
import type { Options, PreToolUseHookInput, SDKMessage, SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import type { Message, Request } from "../src/anthropic.ts";
import { Claude, type Sessions } from "../src/claude.ts";
import { Holds } from "../src/holds.ts";
import { chainOf, Positions } from "../src/positions.ts";
import type { Run } from "../src/session.ts";

/** A process of Claude Code as the test plays it. */
class Played {
	readonly options: Options;
	readonly #prompt: AsyncIterator<SDKUserMessage>;
	readonly #out: SDKMessage[] = [];
	#wake: (() => void) | undefined;
	closed = false;
	#client: Promise<Client> | undefined;

	constructor(params: { readonly prompt: AsyncIterable<SDKUserMessage>; readonly options: Options }) {
		this.options = params.options;
		this.#prompt = params.prompt[Symbol.asyncIterator]();
	}

	async *[Symbol.asyncIterator](): AsyncGenerator<SDKMessage, void> {
		for (;;) {
			const next = this.#out.shift();
			if (next !== undefined) {
				yield next;
				continue;
			}
			if (this.closed) return;
			await new Promise<void>((resolve) => {
				this.#wake = resolve;
			});
		}
	}

	close(): void {
		this.closed = true;
		this.#wake?.();
	}

	supportedModels(): Promise<{ value: string; displayName: string; description: string }[]> {
		return Promise.resolve([{ value: "opus", displayName: "Opus", description: "" }]);
	}

	/** What the process is fed next: a message of the person's, its blocks. */
	async heard(): Promise<readonly { readonly type: string; readonly text?: string; readonly tool_use_id?: string }[]> {
		const next = await this.#prompt.next();
		if (next.done) return [];
		const content = next.value.message.content;
		return typeof content === "string" ? [{ type: "text", text: content }] : content;
	}

	say(...messages: SDKMessage[]): void {
		this.#out.push(...messages);
		this.#wake?.();
	}

	/** Calls the client's tool `name`, as Claude Code does: its hook first, then the call on the session's server. */
	async call(id: string, name: string, input: Record<string, unknown>): Promise<Awaited<ReturnType<Client["callTool"]>>> {
		const hook = this.options.hooks?.PreToolUse?.[0]?.hooks[0];
		const announced: PreToolUseHookInput = {
			hook_event_name: "PreToolUse",
			tool_name: `mcp__tools__${name}`,
			tool_input: input,
			tool_use_id: id,
			session_id: "",
			transcript_path: "",
			cwd: "",
		};
		await hook?.(announced, id, { signal: new AbortController().signal });
		const client = await (this.#client ??= this.#connect());
		return client.callTool({ name, arguments: input });
	}

	async #connect(): Promise<Client> {
		const config = this.options.mcpServers?.["tools"];
		if (config?.type !== "sdk" || !("instance" in config)) throw new Error("the session offered no tools of the client's");
		const server = config.instance;
		const [ours, theirs] = InMemoryTransport.createLinkedPair();
		await server.connect(theirs);
		const client = new Client({ name: "claude-code", version: "0" });
		await client.connect(ours);
		return client;
	}
}

type Said = { type: "text"; text: string } | { type: "tool_use"; id: string; name: string; input: object };

/** What Claude Code says of one API message: its stream's events, each block's entry as it ends, and how it ends. */
function message(id: string, blocks: readonly Said[], stop: "end_turn" | "tool_use"): SDKMessage[] {
	// SAFETY: the test plays Claude Code: each message holds the fields the backend reads, and none it does not.
	const event = (body: object): SDKMessage =>
		({ type: "stream_event", event: body, parent_tool_use_id: null, uuid: crypto.randomUUID(), session_id: "" }) as never;
	const said: SDKMessage[] = [
		event({ type: "message_start", message: { id, type: "message", role: "assistant", content: [], usage: { input_tokens: 10, output_tokens: 0 } } }),
	];
	blocks.forEach((block, index) => {
		if (block.type === "text") {
			said.push(event({ type: "content_block_start", index, content_block: { type: "text", text: "" } }));
			said.push(event({ type: "content_block_delta", index, delta: { type: "text_delta", text: block.text } }));
		} else {
			said.push(
				event({
					type: "content_block_start",
					index,
					content_block: { type: "tool_use", id: block.id, name: block.name.startsWith("Bash") ? block.name : `mcp__tools__${block.name}`, input: {} },
				}),
			);
			said.push(event({ type: "content_block_delta", index, delta: { type: "input_json_delta", partial_json: JSON.stringify(block.input) } }));
		}
		said.push(event({ type: "content_block_stop", index }));
		// SAFETY: as above — an assistant message's id and block, its entry's uuid, and nothing the backend does not read.
		said.push({ type: "assistant", message: { id, content: [block] }, parent_tool_use_id: null, uuid: `${id}-${index}`, session_id: "" } as never);
	});
	said.push(event({ type: "message_delta", delta: { stop_reason: stop }, usage: { output_tokens: 5 } }));
	said.push(event({ type: "message_stop" }));
	return said;
}

// SAFETY: the test plays Claude Code: a session's first message names its id, which is all the backend reads of it.
const init = (session: string): SDKMessage => ({ type: "system", subtype: "init", session_id: session }) as never;
// SAFETY: a turn's result, of which the backend reads that it ended and how.
const done = (session: string): SDKMessage => ({ type: "result", subtype: "success", is_error: false, result: "", session_id: session }) as never;

/** The events of an answer's stream, as the API sends them. */
async function eventsOf(response: Response): Promise<Record<string, unknown>[]> {
	const text = await response.text();
	return text
		.split("\n\n")
		.filter((part) => part.trim() !== "")
		.map((part) =>
			JSON.parse(
				part
					.split("\n")
					.find((line) => line.startsWith("data: "))
					?.slice(6) ?? "null",
			),
		);
}

const tools = [{ name: "read", description: "Reads a file", input_schema: { type: "object", properties: { path: { type: "string" } } } }];

/** Claude Code's folder as the test keeps it: every session there but those gone, those listed as it lists them. */
class Folder implements Sessions {
	readonly gone = new Set<string>();
	readonly listed = new Map<string, number>();
	readonly removed: string[] = [];

	readonly has = (id: string): Promise<boolean> => Promise.resolve(!this.gone.has(id));

	readonly remove = (id: string): Promise<void> => {
		this.gone.add(id);
		this.listed.delete(id);
		this.removed.push(id);
		return Promise.resolve();
	};

	readonly list = (): Promise<readonly { readonly id: string; readonly changedAt: number }[]> =>
		Promise.resolve([...this.listed].map(([id, changedAt]) => ({ id, changedAt })));
}

/** A backend whose processes of Claude Code the test plays, `plays` each as it starts. */
function claudeOf(positions: Positions, plays: Played[], kept: { readonly holds?: Holds; readonly folder?: Folder; readonly now?: number } = {}): Claude {
	const run: Run = (params) => {
		const played = new Played(params);
		plays.push(played);
		// SAFETY: of a Query the backend uses its messages, close and supportedModels, which the played process has.
		return played as never;
	};
	return new Claude({
		claude: "claude",
		folder: "/nowhere",
		positions,
		run,
		environment: {},
		idleMs: 60_000,
		holds: kept.holds ?? emptyHolds,
		sessions: kept.folder ?? new Folder(),
		now: () => kept.now ?? 0,
	});
}

const emptyHolds = await Holds.open(undefined);

const signal = (): AbortSignal => new AbortController().signal;
/** One turn of the event loop, for what the backend does in memory to happen: no time passes. */
const tick = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 0));

/** The `at`-th process started, once the backend started it. */
async function startedAt(plays: readonly Played[], at: number): Promise<Played> {
	while (plays[at] === undefined) await tick();
	return plays[at];
}

describe("Claude through Claude Code", () => {
	it("holds the calls an answer asks for till the next request brings their results, and goes on in the same process", async () => {
		const positions = await Positions.open(undefined);
		const plays: Played[] = [];
		const claude = claudeOf(positions, plays);
		const first: Request = { model: "opus", system: "Be brief.", messages: [{ role: "user", content: "Read build.zig" }], tools };
		const answering = claude.answer(first, signal());
		const played = await startedAt(plays, 0);
		expect(played.options.resume).toBeUndefined();
		expect(played.options.toolAliases).toEqual({ read: "mcp__tools__read" });
		expect(played.options.systemPrompt).toMatchObject({ type: "preset", append: "Be brief.", snapshot: false });
		expect(await played.heard()).toEqual([{ type: "text", text: "Read build.zig" }]);
		played.say(
			init("S1"),
			...message(
				"m1",
				[
					{ type: "text", text: "Reading." },
					{ type: "tool_use", id: "toolu_1", name: "read", input: { path: "build.zig" } },
				],
				"tool_use",
			),
		);
		const events = await eventsOf(await answering);
		// The client's tool by the name it gave it; the answer ends with the message.
		expect(
			events.find((each) => each["type"] === "content_block_start" && (each["content_block"] as { type: string }).type === "tool_use")?.["content_block"],
		).toMatchObject({ name: "read" });
		expect(events.at(-1)).toEqual({ type: "message_stop" });
		const calling = played.call("toolu_1", "read", { path: "build.zig" });
		await tick();

		const replied: Message = {
			role: "assistant",
			content: [
				{ type: "text", text: "Reading." },
				{ type: "tool_use", id: "toolu_1", name: "read", input: { path: "build.zig" } },
			],
		};
		const second: Request = {
			...first,
			messages: [
				...first.messages,
				replied,
				{ role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_1", content: 'const std = @import("std");' }] },
			],
		};
		const answering2 = claude.answer(second, signal());
		expect(await calling).toEqual({ content: [{ type: "text", text: 'const std = @import("std");' }], isError: false });
		played.say(...message("m2", [{ type: "text", text: "It imports std." }], "end_turn"), done("S1"));
		const texts = (await eventsOf(await answering2)).flatMap((each) =>
			each["type"] === "content_block_delta" ? [(each["delta"] as { text?: string }).text] : [],
		);
		expect(texts).toEqual(["It imports std."]);
		expect(plays.length).toBe(1);
		await tick();

		// Started again, the gateway resumes the session at the entry its conversation ends at, given the person's words.
		const plays2: Played[] = [];
		const restarted = claudeOf(positions, plays2);
		const third: Request = {
			...second,
			messages: [...second.messages, { role: "assistant", content: "It imports std." }, { role: "user", content: "Thanks" }],
		};
		void restarted.answer(third, signal());
		const resumed = await startedAt(plays2, 0);
		expect(resumed.options).toMatchObject({ resume: "S1", resumeSessionAt: "m2-0" });
		expect(await resumed.heard()).toEqual([{ type: "text", text: "Thanks" }]);
		claude.close();
		restarted.close();
	});

	it("resumes at the longest prefix a session holds where another model answered after, giving it what it missed as history", async () => {
		const positions = await Positions.open(undefined);
		const plays: Played[] = [];
		const claude = claudeOf(positions, plays);
		const first: Request = { model: "opus", messages: [{ role: "user", content: "Read build.zig" }], tools };
		const answering = claude.answer(first, signal());
		const played = await startedAt(plays, 0);
		await played.heard();
		played.say(init("S1"), ...message("m1", [{ type: "tool_use", id: "toolu_1", name: "read", input: { path: "build.zig" } }], "tool_use"));
		await eventsOf(await answering);
		void played.call("toolu_1", "read", { path: "build.zig" });
		await tick();
		claude.close();

		// Another model took the results and answered; then the person came back to Claude.
		const fresh = claudeOf(positions, plays);
		const later: Request = {
			...first,
			messages: [
				...first.messages,
				{ role: "assistant", content: [{ type: "tool_use", id: "toolu_1", name: "read", input: { path: "build.zig" } }] },
				{ role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_1", content: "const std" }] },
				{ role: "assistant", content: "It imports std, said another model." },
				{ role: "user", content: "Is that right?" },
			],
		};
		void fresh.answer(later, signal());
		const resumed = await startedAt(plays, 1);
		expect(resumed.options).toMatchObject({ resume: "S1", resumeSessionAt: "m1-0" });
		expect(resumed.options.forkSession).toBeUndefined();
		const heard = await resumed.heard();
		expect(heard[0]).toMatchObject({ type: "tool_result", tool_use_id: "toolu_1" });
		expect(heard.map((block) => block.text ?? "")).toContain("It imports std, said another model.");
		expect(heard.at(-1)).toEqual({ type: "text", text: "Is that right?" });
		fresh.close();
	});

	it("goes on in place from where a session last stood, and forks it where the conversation parted from it earlier", async () => {
		const positions = await Positions.open(undefined);
		const plays: Played[] = [];
		const claude = claudeOf(positions, plays);
		const asked: Message = { role: "user", content: "Plan the release" };
		const tagged: Message = { role: "assistant", content: "First, tag it." };
		const then: Message = { role: "user", content: "Then?" };
		const pushed: Message = { role: "assistant", content: "Push it." };
		const chain = chainOf("", [asked, tagged, then, pushed]);
		await positions.set(chain[1] ?? "", { session: "S1", entry: "e1" });
		await positions.set(chain[3] ?? "", { session: "S1", entry: "e2" });
		void claude.answer({ model: "opus", messages: [asked, tagged, then, pushed, { role: "user", content: "Done." }] }, signal());
		const onward = await startedAt(plays, 0);
		expect(onward.options).toMatchObject({ resume: "S1", resumeSessionAt: "e2" });
		expect(onward.options.forkSession).toBeUndefined();
		// Edited after the first answer, the conversation is another from there: the session is forked, not written over.
		void claude.answer({ model: "opus", messages: [asked, tagged, { role: "user", content: "Instead, wait a week." }] }, signal());
		const parted = await startedAt(plays, 1);
		expect(parted.options).toMatchObject({ resume: "S1", resumeSessionAt: "e1", forkSession: true });
		expect(await parted.heard()).toEqual([{ type: "text", text: "Instead, wait a week." }]);
		claude.close();
	});

	it("answers aside from a fork of its own, keeping nothing, and ends a process its request cancelled", async () => {
		const positions = await Positions.open(undefined);
		const plays: Played[] = [];
		const claude = claudeOf(positions, plays);
		const aside: Request = { model: "opus", messages: [{ role: "user", content: "Sum up" }], tools, tool_choice: { type: "none" } };
		const answering = claude.answer(aside, signal());
		const forked = await startedAt(plays, 0);
		expect(forked.options).toMatchObject({ persistSession: false, mcpServers: {} });
		await forked.heard();
		forked.say(init("S9"), ...message("m9", [{ type: "text", text: "A summary." }], "end_turn"), done("S9"));
		await eventsOf(await answering);
		await tick();
		expect(forked.closed).toBe(true);

		const controller = new AbortController();
		const cancelled = claude.answer({ model: "opus", messages: [{ role: "user", content: "Write a novel" }], tools }, controller.signal);
		const writing = await startedAt(plays, 1);
		await writing.heard();
		writing.say(init("S2"), message("m3", [{ type: "text", text: "Once" }], "end_turn")[0] as SDKMessage);
		await cancelled;
		controller.abort();
		await tick();
		expect(writing.closed).toBe(true);
		claude.close();
	});

	it("closes a session whose message called a tool the client never offered, which Claude Code would answer itself", async () => {
		const positions = await Positions.open(undefined);
		const plays: Played[] = [];
		const claude = claudeOf(positions, plays);
		const answering = claude.answer({ model: "opus", messages: [{ role: "user", content: "List files" }], tools }, signal());
		const played = await startedAt(plays, 0);
		await played.heard();
		played.say(init("S3"), ...message("m4", [{ type: "tool_use", id: "toolu_9", name: "Bash", input: { command: "ls" } }], "tool_use"));
		await eventsOf(await answering);
		await tick();
		expect(played.closed).toBe(true);
		claude.close();
	});

	it("keeps the session a conversation's answer settled in, and removes the one it left for another, its positions with it", async () => {
		const positions = await Positions.open(undefined);
		const holds = await Holds.open(undefined);
		const folder = new Folder();
		const plays: Played[] = [];
		const claude = claudeOf(positions, plays, { holds, folder });
		const asked: Message = { role: "user", content: "Plan the release" };
		const answering = claude.answer({ model: "opus", messages: [asked] }, signal(), "thread-1");
		const first = await startedAt(plays, 0);
		await first.heard();
		first.say(init("S1"), ...message("m1", [{ type: "text", text: "Tag it." }], "end_turn"), done("S1"));
		await eventsOf(await answering);
		await tick();
		expect(holds.sessionOf("thread-1")).toBe("S1");

		// Compacted, the conversation begins anew: no session holds any of it, and the one it left is let go.
		const recap: Message = { role: "user", content: "So far: a release planned. Go on." };
		const again = claude.answer({ model: "opus", system: "Recap.", messages: [recap] }, signal(), "thread-1");
		const second = await startedAt(plays, 1);
		await second.heard();
		second.say(init("S2"), ...message("m2", [{ type: "text", text: "Pushing." }], "end_turn"), done("S2"));
		await eventsOf(await again);
		await tick();
		expect(holds.sessionOf("thread-1")).toBe("S2");
		expect(folder.removed).toEqual(["S1"]);
		expect(first.closed).toBe(true);
		expect(positions.get(chainOf("", [asked, { role: "assistant", content: "Tag it." }])[1] ?? "")).toBeUndefined();
		claude.close();
	});

	it("removes an ended conversation's session where no other conversation holds it", async () => {
		const holds = await Holds.open(undefined);
		const folder = new Folder();
		const claude = claudeOf(await Positions.open(undefined), [], { holds, folder });
		await holds.hold("thread-1", "S1");
		await holds.hold("thread-2", "S1");
		await claude.forget("thread-1");
		expect(folder.removed).toEqual([]);
		await claude.forget("thread-2");
		expect(folder.removed).toEqual(["S1"]);
		await claude.forget("thread-3");
		expect(folder.removed).toEqual(["S1"]);
		claude.close();
	});

	it("tells a conversation whose session is gone from the folder to a new one, whole", async () => {
		const positions = await Positions.open(undefined);
		const folder = new Folder();
		const plays: Played[] = [];
		const claude = claudeOf(positions, plays, { folder });
		const asked: Message = { role: "user", content: "Plan the release" };
		const tagged: Message = { role: "assistant", content: "Tag it." };
		await positions.set(chainOf("", [asked, tagged])[1] ?? "", { session: "S1", entry: "e1" });
		folder.gone.add("S1");
		void claude.answer({ model: "opus", messages: [asked, tagged, { role: "user", content: "Then?" }] }, signal(), "thread-1");
		const fresh = await startedAt(plays, 0);
		expect(fresh.options.resume).toBeUndefined();
		const heard = await fresh.heard();
		expect(heard.map((block) => block.text ?? "").join("")).toContain("Tag it.");
		expect(positions.get(chainOf("", [asked, tagged])[1] ?? "")).toBeUndefined();
		claude.close();
	});

	it("collects the sessions no conversation holds once none used them for a day", async () => {
		const holds = await Holds.open(undefined);
		const folder = new Folder();
		const day = 24 * 60 * 60 * 1000;
		const now = 30 * day;
		const claude = claudeOf(await Positions.open(undefined), [], { holds, folder, now });
		folder.listed.set("held", now - 2 * day);
		folder.listed.set("recent", now);
		folder.listed.set("stale", now - 2 * day);
		await holds.hold("thread-1", "held");
		await claude.collect();
		expect(folder.removed).toEqual(["stale"]);
		claude.close();
	});
});
