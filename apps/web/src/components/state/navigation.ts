/**
 * Going places: the window's place is its address after `#`, read as it changes, and going somewhere is writing it, so
 * the browser's back and forward walk the places the person went.
 */
import { useSyncExternalStore } from "react";
import { type Route, routeAddress, routeOf } from "../../core/route.ts";

/** Goes to `route`. */
export function go(route: Route): void {
	window.location.hash = routeAddress(route);
}

/** The window's place, read again as its address changes. */
export function useRoute(): Route {
	const address = useSyncExternalStore(subscribe, () => window.location.hash);
	return routeOf(address);
}

function subscribe(changed: () => void): () => void {
	window.addEventListener("hashchange", changed);
	return () => window.removeEventListener("hashchange", changed);
}
