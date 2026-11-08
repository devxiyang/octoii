/**
 * A thread as a client follows it: its log's latest entries — as many as it keeps, read first, then each as it is
 * appended, the oldest let go past the bound, as a terminal keeps its latest lines — and older ones only as a reader
 * reads further back; its state as it changes; and what streams of each request while it is acted on — a model's
 * answer as it comes, a command's output — by its offset, let go once the state holds the request open no more; and
 * its terminals and its pages in the browser, as they come, change and go. It is
 * followed again from where its reader stands on each connection that opens, as a reader of a stream resumes from an
 * offset, so every entry is taken once; what streamed is sent again from each stream's start.
 */
import { ClientError } from "./errors.ts";
import type { Cursor, Entry, Event, PageListed, State, TerminalListed } from "./protocol.ts";

/** A followed thread as the interface reads it. */
export type ThreadView = {
	/** Its latest entries, as many as the client keeps, and those read further back. */
	readonly entries: readonly Entry[];
	/** Whether its latest entries were read: till they are, what it holds is not the thread yet. */
	readonly read: boolean;
	/** Whether the entries reach the log's start: none is left to read further back. */
	readonly complete: boolean;
	/** Its state, once the node sent it. */
	readonly state: State | undefined;
	/** What streamed of each request the state holds open, by the request's key, in the order it came. */
	readonly streaming: ReadonlyMap<string, readonly unknown[]>;
	/** Why the node could not feed it, last time it could not. */
	readonly failure: ClientError | undefined;
	/** Its terminals, in the order they were opened. */
	readonly terminals: readonly TerminalListed[];
	/** Its pages in the browser, in the order they were opened. */
	readonly pages: readonly PageListed[];
};

/** A thread the client follows, and those who read it. */
export class FollowedThread {
	readonly id: string;
	#cursor: Cursor | undefined;
	/** How many entries it keeps: as many as the client keeps, and the pages read further back. */
	#bound: number;
	#view: ThreadView = { entries: [], read: false, complete: false, state: undefined, streaming: new Map(), failure: undefined, terminals: [], pages: [] };
	readonly #listeners = new Set<() => void>();

	constructor(id: string, kept: number) {
		this.id = id;
		this.#bound = kept;
	}

	/** Whether its latest entries were read, so it is followed on from where its reader stands. */
	get begun(): boolean {
		return this.#view.read;
	}

	/** Takes its latest entries as a read of them gave them: where the log then ended, it is followed on from. */
	begin(entries: readonly Entry[], end: Cursor | undefined, complete: boolean): void {
		this.#cursor = end;
		this.#publish({ ...this.#view, entries, read: true, complete });
	}

	/** Takes entries read further back, before those it holds: it keeps them too. */
	prepend(entries: readonly Entry[], complete: boolean): void {
		this.#bound += entries.length;
		this.#publish({ ...this.#view, entries: [...entries, ...this.#view.entries], complete });
	}

	/** What the thread is, as far as the client has read it: the same object until it changes. */
	get view(): ThreadView {
		return this.#view;
	}

	/** Where its reader stands; none before the first entry came. */
	get cursor(): Cursor | undefined {
		return this.#cursor;
	}

	subscribe(listener: () => void): () => void {
		this.#listeners.add(listener);
		return () => this.#listeners.delete(listener);
	}

	/** Lets go of what streamed, as the thread is followed again: the node sends each stream again from its start. */
	restart(): void {
		if (this.#view.streaming.size === 0) return;
		this.#publish({ ...this.#view, streaming: new Map() });
	}

	#publish(view: ThreadView): void {
		this.#view = view;
		for (const listener of [...this.#listeners]) listener();
	}

	/** Takes an event of the thread's. */
	take(event: Event): void {
		const view = this.#view;
		switch (event.event) {
			case "entries": {
				if (event.cursor !== undefined) this.#cursor = event.cursor;
				// Past its bound, the oldest entries are let go: the log keeps them, to read back.
				const appended = [...view.entries, ...event.entries];
				const kept = appended.length > this.#bound ? appended.slice(appended.length - this.#bound) : appended;
				this.#view = {
					...view,
					entries: kept,
					complete: view.complete && kept.length === appended.length,
				};
				break;
			}
			case "state":
				this.#view = { ...view, state: event.state, streaming: ofOpenRequests(view.streaming, event.state) };
				break;
			case "stream": {
				// A stream is taken in order, each event at the offset that follows what is held: what comes again, as a stream
				// sent from its start on following again, or past a gap, is left.
				const held = view.streaming.get(event.request) ?? [];
				if (event.offset !== held.length) return;
				this.#view = { ...view, streaming: new Map([...view.streaming, [event.request, [...held, event.data]]]) };
				break;
			}
			case "failed":
				this.#view = { ...view, failure: new ClientError(event.error.code, event.error.message) };
				break;
			case "terminals":
				this.#view = { ...view, terminals: event.terminals };
				break;
			case "pages":
				this.#view = { ...view, pages: event.pages };
				break;
		}
		for (const listener of [...this.#listeners]) listener();
	}
}

/**
 * `streaming` but for the requests `state` holds open no more: a stream lives while its request is acted on, and what
 * came of it is then the log's — a reply, a result — as the state is sent after the entries it stands on.
 */
function ofOpenRequests(streaming: ReadonlyMap<string, readonly unknown[]>, state: State): ReadonlyMap<string, readonly unknown[]> {
	const open = new Set(state.processes.flatMap((process) => process.requests.map((request) => request.key)));
	if ([...streaming.keys()].every((request) => open.has(request))) return streaming;
	return new Map([...streaming].filter(([request]) => open.has(request)));
}
