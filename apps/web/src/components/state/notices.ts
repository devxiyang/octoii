/**
 * What the person is told in passing — an action of theirs that failed, and why — as notices over the page: one
 * manager for the app, which any component tells through and the app's notices show. A failure is announced at once,
 * as an alert is, and kept a while longer than a notice that tells of nothing gone wrong; the developer's console is
 * told it whole.
 */
import { Toast } from "@base-ui/react/toast";

/** The app's notices. */
export const notices = Toast.createToastManager();

/** How long a failure is shown before it goes of itself, in ms, unless the person holds it by pointing at it. */
const failure_ms = 8000;

/** Tells the person `what` failed — "The message could not be sent" — and why, as `error` says. */
export function failed(what: string, error: unknown): void {
	console.error(error);
	notices.add({ type: "error", title: what, description: reasonOf(error), priority: "high", timeout: failure_ms });
}

/** Why `error` happened, in its own words. */
function reasonOf(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}
