/**
 * The shelf: what the hooks of one client follow, by key, each taken when a component first reads it and kept while a
 * component subscribes, then released `REACT_RELEASE_MS` after the last one goes, or after a read no subscribe follows.
 */
import { REACT_RELEASE_MS } from "../constants.ts";
import type { Followable } from "../followed.ts";
import type { Clock } from "../options.ts";

/** What `useSyncExternalStore` takes for one key: stable functions, the same for every component that follows it. */
export type Binding<View> = {
	readonly subscribe: (listener: () => void) => () => void;
	readonly snapshot: () => View;
};

/** One followed thing on the shelf, its view as of its last change, and who holds it. */
type Shelved = {
	readonly followable: Followable<unknown>;
	view: unknown;
	holders: number;
	readonly listeners: Set<() => void>;
	stop: () => void;
	cancelRelease: (() => void) | undefined;
};

/** The followed things of one client, by key. */
export class Shelf {
	private readonly shelved = new Map<string, Shelved>();
	private readonly bindings = new Map<string, Binding<unknown>>();
	private readonly clock: Clock;

	constructor(clock: Clock) {
		this.clock = clock;
	}

	/** The binding of a key, taking what it follows with `take` when it is not on the shelf. */
	binding<View>(key: string, take: () => Followable<View>): Binding<View> {
		const held = this.bindings.get(key);
		if (held !== undefined) {
			// SAFETY: a key names one followed thing, always taken by the same `take`, so its binding answers that View.
			return held as Binding<View>;
		}
		const binding: Binding<View> = {
			subscribe: (listener) => this.subscribe(key, take, listener),
			snapshot: () => {
				// SAFETY: the view on the shelf under `key` is what `take`'s followable made, a View.
				return this.take(key, take).view as View;
			},
		};
		this.bindings.set(key, binding);
		return binding;
	}

	private subscribe(key: string, take: () => Followable<unknown>, listener: () => void): () => void {
		const shelved = this.take(key, take);
		shelved.holders += 1;
		shelved.cancelRelease?.();
		shelved.cancelRelease = undefined;
		shelved.listeners.add(listener);
		let subscribed = true;
		return () => {
			if (!subscribed) return;
			subscribed = false;
			shelved.listeners.delete(listener);
			shelved.holders -= 1;
			if (shelved.holders === 0) this.releaseLater(key, shelved);
		};
	}

	/** What a key follows, taken now if the shelf does not hold it, and released later if no one subscribes. */
	private take(key: string, take: () => Followable<unknown>): Shelved {
		const held = this.shelved.get(key);
		if (held !== undefined) return held;
		const followable = take();
		const shelved: Shelved = { followable, view: followable.view(), holders: 0, listeners: new Set(), stop: () => undefined, cancelRelease: undefined };
		shelved.stop = followable.subscribe(() => {
			shelved.view = followable.view();
			for (const listener of [...shelved.listeners]) listener();
		});
		this.shelved.set(key, shelved);
		this.releaseLater(key, shelved);
		return shelved;
	}

	private releaseLater(key: string, shelved: Shelved): void {
		shelved.cancelRelease = this.clock.setTimer(() => {
			if (shelved.holders > 0 || this.shelved.get(key) !== shelved) return;
			this.shelved.delete(key);
			this.bindings.delete(key);
			shelved.stop();
			shelved.followable.release();
		}, REACT_RELEASE_MS);
	}
}
