/**
 * The thread details card, one for the app: whether it shows at the chat's top right, where the chat has room for it
 * beside its column — kept as the person goes between threads, as the panel's place is. Where the chat has no room, the
 * card opens from the header's button instead, as a popover of its own. A store of the page's, outside any component.
 */
import { useSyncExternalStore } from "react";

let shown = true;
const listeners = new Set<() => void>();

function subscribe(listener: () => void): () => void {
	listeners.add(listener);
	return () => listeners.delete(listener);
}

/** Whether the card shows beside the chat's column, read again as it changes. */
export function useDetailsShown(): boolean {
	return useSyncExternalStore(subscribe, () => shown);
}

/** Shows the card beside the chat's column, or hides it. */
export function showDetails(next: boolean): void {
	shown = next;
	for (const listener of [...listeners]) listener();
}
