/**
 * The threads the client follows: one following of each for all who read it — read first, its latest entries alone,
 * then followed on from where its log ended as it was read, and so again as each connection opens; read back a page at
 * a time as a reader asks; let go once its last reader does.
 */
import type { Connection } from "./connection.ts";
import { READ_BACK_PAGE } from "./constants.ts";
import { type Followable, holding, type Reading } from "./followed.ts";
import type { Event } from "./protocol.ts";
import { FollowedThread, type ThreadView } from "./thread.ts";

export class Follows {
	readonly #followed = new Map<string, Reading<FollowedThread>>();
	readonly #connection: Connection;
	/** How many of a thread's latest entries are kept. */
	readonly #kept: number;
	/** Tells of a failure that is not the connection's own. */
	readonly #told: (error: unknown) => void;

	constructor(connection: Connection, kept: number, told: (error: unknown) => void) {
		this.#connection = connection;
		this.#kept = kept;
		this.#told = told;
	}

	/** Follows each thread again, as a connection opens. */
	again(): void {
		for (const { thing } of this.#followed.values()) this.#followAgain(thing);
	}

	/** Gives the thread an event of it, where it is followed. */
	take(event: Event & { readonly thread: string }): void {
		this.#followed.get(event.thread)?.thing.take(event);
	}

	/** One more reader of the thread `id`: one following of it for all who read it, begun as the first comes. */
	follow(id: string): Followable<ThreadView> {
		let held = this.#followed.get(id);
		if (held === undefined) {
			held = { thing: new FollowedThread(id, this.#kept), holders: 0 };
			this.#followed.set(id, held);
			if (this.#isOpen()) this.#followAgain(held.thing);
		}
		const thread = held.thing;
		return holding(
			held,
			thread.subscribe.bind(thread),
			() => thread.view,
			() => {
				this.#followed.delete(id);
				if (this.#isOpen()) this.#connection.call("threads.unfollow", { thread: id }).catch(this.#told);
			},
		);
	}

	/** Reads back a page of the thread `id` before the earliest entry its readers hold, where its log goes back further. */
	async readOlder(id: string): Promise<void> {
		const thread = this.#followed.get(id)?.thing;
		const first = thread?.view.entries[0];
		if (thread === undefined || thread.view.complete) return;
		const page = await this.#connection.call(
			"threads.read",
			first === undefined ? { thread: id, limit: READ_BACK_PAGE } : { thread: id, before: first.id, limit: READ_BACK_PAGE },
		);
		thread.prepend(page.entries, page.complete);
	}

	#isOpen(): boolean {
		return this.#connection.status.value.status === "open";
	}

	async #followOn(thread: FollowedThread): Promise<void> {
		const from = thread.cursor;
		await this.#connection.call("threads.follow", from === undefined ? { thread: thread.id } : { thread: thread.id, from });
	}

	/** A thread is read first, its latest entries alone, then followed on from where the log ended as it was read. */
	#followAgain(thread: FollowedThread): void {
		thread.restart();
		if (thread.begun) {
			this.#followOn(thread).catch(this.#told);
			return;
		}
		this.#connection
			.call("threads.read", { thread: thread.id, limit: this.#kept })
			.then((page) => {
				thread.begin(page.entries, page.end, page.complete);
				return this.#followOn(thread);
			})
			.catch(this.#told);
	}
}
