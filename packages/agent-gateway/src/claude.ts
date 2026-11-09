/**
 * Claude through the person's own Claude Code, by the Agent SDK, answered as Anthropic's Messages API: Claude thinks,
 * and the client acts. Claude Code's own tools, settings, memory, skills and hooks are off; the client's tools are an
 * MCP server of each session's, whose calls are held — never run — and an answer ends as the model asks for them, as
 * the API's does; the next request brings their results.
 *
 * The client's conversation is the master and Claude Code's sessions its replicas, as Redis's are: a request goes on in
 * the live session that stands where its conversation's last message of the model's ends; else a session is resumed at
 * the longest prefix of the conversation one holds, given what it missed as history between checkpoint tags — in place
 * where that prefix is the session's tip, forked where the session went on past it, as a conversation that parted from
 * it there, edited or forked, is another; else a new session is given the conversation so. A request whose answer is
 * aside from the conversation — none of its tools may be called, or its answer is JSON of a schema — is answered by a
 * fork of its own, kept nowhere.
 *
 * Each live session is a process of Claude Code; one idle past a while is closed, its conversation resumed from its
 * positions when it is asked again.
 */
import type { ModelInfo, Options } from "@anthropic-ai/claude-agent-sdk";
import { errorResponse, type Message, type Request, systemText, type Tool } from "./anthropic.ts";
import { PREFIX } from "./answering.ts";
import { Input } from "./held.ts";
import { canonical, chainOf, type Position, type Positions, rootOf } from "./positions.ts";
import { type Run, Session } from "./session.ts";
import { toldAfter } from "./told.ts";

/** What the backend runs with. */
export type ClaudeOptions = {
	/** The person's own `claude`, by its path. */
	readonly claude: string;
	/** The folder Claude Code works in, which names where it keeps its sessions; nothing of the person's. */
	readonly folder: string;
	readonly positions: Positions;
	readonly run: Run;
	/** The variables Claude Code runs with, whole. */
	readonly environment: Readonly<Record<string, string>>;
	/** How long a live session may stand unasked before it is closed. */
	readonly idleMs: number;
};

export class Claude {
	readonly #options: ClaudeOptions;
	readonly #live = new Set<Session>();
	readonly #sweeper: ReturnType<typeof setInterval>;
	#models: Promise<readonly ModelInfo[]> | undefined;

	constructor(options: ClaudeOptions) {
		this.#options = options;
		this.#sweeper = setInterval(() => this.#sweep(), Math.max(1_000, Math.floor(options.idleMs / 4)));
	}

	/** Answers `request` as the Messages API does, as a stream; an error before the stream begins as the API's error. */
	async answer(request: Request, signal: AbortSignal): Promise<Response> {
		const messages = request.messages;
		if (messages.at(-1)?.role !== "user")
			return errorResponse("invalid_request_error", "The conversation must end with the person's words or the results of calls.");
		const system = systemText(request.system);
		const chain = chainOf(system, messages);
		const last = messages.findLastIndex((message) => message.role === "assistant");
		const settings = settingsOf(request);
		if (isAside(request)) return this.#aside(request, chain, last, signal);
		const live = await this.#liveAt(last < 0 ? rootOf(system) : (chain[last] ?? ""), settings);
		const end = chain.at(-1) ?? rootOf(system);
		if (live !== undefined) {
			const told = toldAfter(messages, last);
			return live.answer(told.results, told.rest, end, signal);
		}
		const known = this.#longestKnown(messages, chain, last);
		const told = toldAfter(messages, known.at);
		const session = this.#session(request, this.#resumed(known, chain));
		this.#live.add(session);
		return session.answer(told.results, told.rest, end, signal);
	}

	/** The models Claude Code offers the person, as it tells them, asked of a process started for it once. */
	models(): Promise<readonly ModelInfo[]> {
		this.#models ??= this.#askModels().catch((error: unknown) => {
			this.#models = undefined;
			throw error;
		});
		return this.#models;
	}

	async #askModels(): Promise<readonly ModelInfo[]> {
		const input = new Input();
		const options = this.#options;
		const query = options.run({
			prompt: input,
			options: {
				pathToClaudeCodeExecutable: options.claude,
				cwd: options.folder,
				env: { ...options.environment },
				settingSources: [],
				tools: [],
				persistSession: false,
			},
		});
		try {
			return await query.supportedModels();
		} finally {
			input.end();
			query.close();
		}
	}

	/** Closes every live session, as the gateway ends. */
	close(): void {
		clearInterval(this.#sweeper);
		for (const session of this.#live) session.close();
		this.#live.clear();
	}

	/** The live session that stands at `prefix`, settled, asked with the same settings; none where none does. */
	async #liveAt(prefix: string, settings: string): Promise<Session | undefined> {
		for (const session of this.#live) {
			if (session.position !== prefix || session.settings !== settings) continue;
			await session.settled;
			if (session.position === prefix && session.isAskable()) return session;
		}
		return undefined;
	}

	/** The longest prefix of the conversation, ending at a message of the model's no later than `last`, a session holds. */
	#longestKnown(messages: readonly Message[], chain: readonly string[], last: number): { at: number; position?: Position } {
		for (let at = last; at >= 0; at -= 1) {
			if (messages[at]?.role !== "assistant") continue;
			const position = this.#options.positions.get(chain[at] ?? "");
			if (position !== undefined) return { at, position };
		}
		return { at: -1 };
	}

	/**
	 * How a session is started where a conversation's longest known prefix ends: resumed in place at its session's tip —
	 * any live process of that session closed, as one process writes a session — forked where the session went on past
	 * it; new where no session holds any of it.
	 */
	#resumed(known: { at: number; position?: Position }, chain: readonly string[]): Partial<Options> {
		const position = known.position;
		if (position === undefined) return {};
		const at = { resume: position.session, resumeSessionAt: position.entry };
		if (!this.#options.positions.isTip(chain[known.at] ?? "")) return { ...at, forkSession: true };
		this.#closeLiveOf(position.session);
		return at;
	}

	/** Closes the live sessions of Claude Code's session `id`, which another process is about to go on with. */
	#closeLiveOf(id: string): void {
		for (const session of this.#live) {
			if (session.id !== id) continue;
			session.close();
			this.#live.delete(session);
		}
	}

	/** A new session for `request`, started as `extra` says: resumed, forked, or new. */
	#session(request: Request, extra: Partial<Options>): Session {
		const tools = (request.tools ?? []).filter(isFunction);
		return new Session({
			run: this.#options.run,
			positions: this.#options.positions,
			options: { ...baseOptions(this.#options, request, tools), ...extra },
			tools,
			holdMs: 2 * this.#options.idleMs,
			settings: settingsOf(request),
		});
	}

	/** An answer aside from the conversation, from a fork of its own where a session holds a prefix of it, kept nowhere. */
	async #aside(request: Request, chain: readonly string[], last: number, signal: AbortSignal): Promise<Response> {
		const known = this.#longestKnown(request.messages, chain, last);
		const told = toldAfter(request.messages, known.at);
		const fork = known.position === undefined ? {} : { resume: known.position.session, resumeSessionAt: known.position.entry, forkSession: true };
		const session = this.#session({ ...request, tools: [] }, { persistSession: false, ...fork });
		try {
			const response = await session.answerAside(told.results, told.rest, signal, request.output_config?.format !== undefined);
			void session.settled.finally(() => session.close());
			return response;
		} catch (error) {
			session.close();
			throw error;
		}
	}

	/** Closes the sessions that stood unasked too long, and forgets those that closed. */
	#sweep(): void {
		const now = Date.now();
		for (const session of this.#live) {
			if (session.isClosed()) this.#live.delete(session);
			else if (session.isAskable() && now - session.usedAt > this.#options.idleMs) {
				session.close();
				this.#live.delete(session);
			}
		}
	}
}

/** Whether `request`'s answer is aside from its conversation: none of its tools may be called, or it is JSON of a schema. */
function isAside(request: Request): boolean {
	return request.tool_choice?.type === "none" || request.output_config?.format !== undefined;
}

/** What a session is asked with, which a live one must share to go on: the model, how it thinks, and the tools. */
function settingsOf(request: Request): string {
	const tools = (request.tools ?? []).filter(isFunction).map((tool) => [tool.name, tool.description ?? "", tool.input_schema]);
	return canonical([request.model, request.thinking?.type ?? null, request.output_config?.effort ?? null, tools]);
}

function isFunction(tool: Tool): boolean {
	return tool.type === undefined || tool.type === "custom";
}

/** What every session runs with: Claude Code's own tools, settings, skills, memory and hooks off; the request's model and thinking. */
function baseOptions(options: ClaudeOptions, request: Request, tools: readonly Tool[]): Options {
	const effort = effortOf(request.output_config?.effort);
	const format = request.output_config?.format;
	return {
		pathToClaudeCodeExecutable: options.claude,
		cwd: options.folder,
		env: { ...options.environment },
		model: request.model,
		settingSources: [],
		settings: { disableAllHooks: true },
		strictMcpConfig: true,
		skills: [],
		tools: [],
		permissionMode: "dontAsk",
		allowedTools: [`${PREFIX}*`],
		// A call by the tool's own name, as the client's prompt writes it, is a call of the client's tool.
		toolAliases: Object.fromEntries(tools.map((tool) => [tool.name, `${PREFIX}${tool.name}`])),
		includePartialMessages: true,
		verbatimPrompts: true,
		// Not snapshot: a session resumed takes the system prompt of the request that resumes it.
		systemPrompt: { type: "preset", preset: "claude_code", append: systemText(request.system), excludeDynamicSections: true, snapshot: false },
		thinking: thinkingOf(request.thinking),
		...(effort === undefined ? {} : { effort }),
		...(format === undefined ? {} : { outputFormat: { type: "json_schema", schema: format.schema } }),
	};
}

/** How Claude thinks, as the request asks: adaptively, with summaries the client can show, unless it asks otherwise. */
function thinkingOf(thinking: Request["thinking"]): NonNullable<Options["thinking"]> {
	if (thinking === undefined || thinking.type === "adaptive") return { type: "adaptive", display: "summarized" };
	if (thinking.type === "disabled") return { type: "disabled" };
	return thinking.budget_tokens === undefined ? { type: "enabled" } : { type: "enabled", budgetTokens: thinking.budget_tokens };
}

/** The efforts Claude Code takes. */
const EFFORTS: readonly NonNullable<Options["effort"]>[] = ["low", "medium", "high", "xhigh", "max"];

/** The effort the request asks for, where it is one Claude Code takes. */
function effortOf(effort: string | undefined): Options["effort"] {
	return EFFORTS.find((each) => each === effort);
}
