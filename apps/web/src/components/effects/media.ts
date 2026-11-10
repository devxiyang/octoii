/**
 * What the page's media queries say, as it changes: whether the page is narrow — under 48rem, Tailwind's `md`, as a
 * phone's is — where the sidebar is a drawer over the page rather than beside it; and whether its pointer is fine, a
 * mouse's or a trackpad's, rather than a finger, for which a field takes the focus as its popup opens, as a phone's
 * keys would rise over what the popup shows; and whether the person asked for less motion, which moves at once rather
 * than gliding.
 */
import { useCallback, useSyncExternalStore } from "react";

/** The page narrow. */
export const NARROW = "(width < 48rem)";

/** A pointer that is fine, as a mouse is. */
export const FINE_POINTER = "(pointer: fine)";

/** Less motion asked for. */
export const REDUCED_MOTION = "(prefers-reduced-motion: reduce)";

/** Whether `query` holds, drawn again as it turns to or from holding. */
export function useMedia(query: string): boolean {
	const watch = useCallback(
		(changed: () => void) => {
			const media = window.matchMedia(query);
			media.addEventListener("change", changed);
			return () => media.removeEventListener("change", changed);
		},
		[query],
	);
	return useSyncExternalStore(watch, () => window.matchMedia(query).matches);
}
