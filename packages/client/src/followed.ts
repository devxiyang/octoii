/** A value an interface reads and follows: its listeners hear each change. */

/** A value, and how to hear it change. */
export type Followed<T> = { readonly value: T; subscribe(listener: () => void): () => void };

/** A value its owner sets, whose listeners hear each change of identity. */
export class Value<T> implements Followed<T> {
	private current: T;
	private readonly listeners = new Set<() => void>();

	constructor(initial: T) {
		this.current = initial;
	}

	get value(): T {
		return this.current;
	}

	set(next: T): void {
		if (Object.is(next, this.current)) return;
		this.current = next;
		for (const listener of [...this.listeners]) listener();
	}

	subscribe(listener: () => void): () => void {
		this.listeners.add(listener);
		return () => this.listeners.delete(listener);
	}
}

/** What one follows until they let it go: its view, the same object until it changes, how to hear it change, and how to let it go. */
export type Followable<View> = {
	view(): View;
	subscribe(listener: () => void): () => void;
	release(): void;
};

/** What is followed, and how many read it. */
export type Reading<Thing> = { readonly thing: Thing; holders: number };

/** One more reader of what `held` holds: its view and its changes, and `end` once the last reader lets it go. */
export function holding<Thing, View>(
	held: Reading<Thing>,
	subscribe: (listener: () => void) => () => void,
	view: () => View,
	end: () => void,
): Followable<View> {
	held.holders += 1;
	let released = false;
	return {
		view,
		subscribe,
		release: () => {
			if (released) return;
			released = true;
			held.holders -= 1;
			if (held.holders === 0) end();
		},
	};
}
