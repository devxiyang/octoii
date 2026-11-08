/**
 * A watch the node keeps for the client while anyone reads it — the list of threads, the settings: what holds what it
 * was told, made as its first reader comes; begun then, and again as each connection opens, its answer and its events
 * given to what holds them; and ended once its last reader lets it go.
 */
import { type Followable, holding, type Reading } from "./followed.ts";

/** What a watch is: what holds what it is told, what a reader sees of it and hears change, and how it begins and ends. */
export type WatchOf<Thing, View> = {
	readonly make: () => Thing;
	readonly view: (thing: Thing) => View;
	readonly subscribe: (thing: Thing, listener: () => void) => () => void;
	/** Asks the node to begin the watch, its answer given to `thing`. */
	readonly begin: (thing: Thing) => void;
	/** Asks the node to end it. */
	readonly end: () => void;
};

export class Watch<Thing, View> {
	#reading: Reading<Thing> | undefined;
	readonly #of: WatchOf<Thing, View>;
	readonly #isOpen: () => boolean;

	constructor(of: WatchOf<Thing, View>, isOpen: () => boolean) {
		this.#of = of;
		this.#isOpen = isOpen;
	}

	/** What holds what the watch was told, while one reads it. */
	get thing(): Thing | undefined {
		return this.#reading?.thing;
	}

	/** Begins it again, as a connection opens, where one reads it. */
	again(): void {
		if (this.#reading !== undefined) this.#of.begin(this.#reading.thing);
	}

	/** One more reader of it: one watch for all who read it, begun as the first comes. */
	hold(): Followable<View> {
		if (this.#reading === undefined) {
			this.#reading = { thing: this.#of.make(), holders: 0 };
			if (this.#isOpen()) this.#of.begin(this.#reading.thing);
		}
		const { thing } = this.#reading;
		return holding(
			this.#reading,
			(listener) => this.#of.subscribe(thing, listener),
			() => this.#of.view(thing),
			() => {
				this.#reading = undefined;
				if (this.#isOpen()) this.#of.end();
			},
		);
	}
}
