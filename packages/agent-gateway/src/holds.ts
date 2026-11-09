/**
 * Which of an agent's sessions each conversation holds — the one its last answer was in — a conversation named by its
 * client, as the `conversation-id` its requests carry; kept as lines of a file where one is given, so a gateway started
 * again knows them. A session no conversation holds is let go, as a file no name links is removed: once the last
 * conversation that held it went on in another, or ended.
 */
import { Type } from "typebox";
import { LineFile } from "./lines.ts";
import { matches } from "./schema.ts";

/** How many lines the file may hold past twice the holds it keeps before it is written again with them alone. */
const SLACK_LINES = 64;

export class Holds {
	readonly #file: LineFile | undefined;
	/** The session each conversation holds. */
	readonly #held = new Map<string, string>();
	/** How many conversations hold each session. */
	readonly #holders = new Map<string, number>();

	private constructor(file: LineFile | undefined) {
		this.#file = file;
	}

	/** The holds the file at `path` keeps, none where there is no file yet; kept in memory alone with no path. */
	static async open(path: string | undefined): Promise<Holds> {
		if (path === undefined) return new Holds(undefined);
		const { file, values } = await LineFile.open(path);
		const holds = new Holds(file);
		for (const value of values) if (matches(LineSchema, value)) holds.#set(value.conversation, value.session ?? undefined);
		return holds;
	}

	/** The session `conversation` holds; none where it holds none. */
	sessionOf(conversation: string): string | undefined {
		return this.#held.get(conversation);
	}

	/** Whether a conversation holds the session `session`. */
	isHeld(session: string): boolean {
		return this.#holders.has(session);
	}

	/** Keeps that `conversation` holds `session`: the session it held before, where no conversation holds that now. */
	async hold(conversation: string, session: string): Promise<string | undefined> {
		const before = this.#held.get(conversation);
		if (before === session) return undefined;
		await this.#change(conversation, session);
		return before === undefined || this.isHeld(before) ? undefined : before;
	}

	/** Lets `conversation` go, as it ended: the session it held, where no conversation holds that now. */
	async release(conversation: string): Promise<string | undefined> {
		const before = this.#held.get(conversation);
		if (before === undefined) return undefined;
		await this.#change(conversation, undefined);
		return this.isHeld(before) ? undefined : before;
	}

	/** Lets every conversation that holds `session` go of it, as the session is gone. */
	async drop(session: string): Promise<void> {
		for (const [conversation, held] of [...this.#held]) if (held === session) await this.#change(conversation, undefined);
	}

	/** Keeps that `conversation` holds `session`, or none, in the file too. */
	async #change(conversation: string, session: string | undefined): Promise<void> {
		this.#set(conversation, session);
		if (this.#file === undefined) return;
		if (this.#file.lines < 2 * this.#held.size + SLACK_LINES) return this.#file.append({ conversation, session: session ?? null });
		await this.#file.rewrite([...this.#held].map(([held, by]) => ({ conversation: held, session: by })));
	}

	#set(conversation: string, session: string | undefined): void {
		const before = this.#held.get(conversation);
		if (before !== undefined) {
			const left = (this.#holders.get(before) ?? 1) - 1;
			if (left > 0) this.#holders.set(before, left);
			else this.#holders.delete(before);
		}
		if (session === undefined) {
			this.#held.delete(conversation);
			return;
		}
		this.#held.set(conversation, session);
		this.#holders.set(session, (this.#holders.get(session) ?? 0) + 1);
	}
}

const LineSchema = Type.Object({ conversation: Type.String(), session: Type.Union([Type.String(), Type.Null()]) });
