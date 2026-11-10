/** Asking for many things at most a few at a time: a peer that runs only so many of a client's requests at once is never asked past them. */

/** What `each` gives for every one of `items`, in their order, at most `most` of them asked at a time, the next as one is given. */
export async function inTurns<Item, Given>(items: readonly Item[], most: number, each: (item: Item) => Promise<Given>): Promise<readonly Given[]> {
	const given: Given[] = [];
	// One queue for every turn: each takes the next item as it is given its last.
	const queue = items.entries();
	const turn = async (): Promise<void> => {
		for (let next = queue.next(); next.done !== true; next = queue.next()) {
			const [at, item] = next.value;
			given[at] = await each(item);
		}
	};
	await Promise.all(Array.from({ length: Math.min(most, items.length) }, turn));
	return given;
}
