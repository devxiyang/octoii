/**
 * What a thread brought the person, marked seen while the page shows it to them: its newest, as the thread's own times
 * tell it, kept on the node, so the thread's card stops standing out as unread on every device. A page hidden — the
 * browser's tab in the background, the window minimised — marks nothing.
 */
import { useEffect, useSyncExternalStore } from "react";
import { useClient, useThreads } from "@octoii-works/octoii-client/react";
import { arrivedAt, standingsOf } from "../../core/threads.ts";
import { failed } from "../state/notices.ts";

/** Marks what `thread` brought as seen while the page shows it. */
export function useSeen(thread: string): void {
	const client = useClient();
	const rows = useThreads();
	const shown = useSyncExternalStore(subscribe, () => document.visibilityState === "visible");
	const row = rows?.find((each) => each.id === thread);
	const arrived = row === undefined || rows === undefined ? 0 : arrivedAt(row, standingsOf(rows)(row));
	const seen = row?.manifest.seen_until ?? 0;
	useEffect(() => {
		if (!shown || arrived <= seen) return;
		client.configure(thread, { seen_until: arrived }).catch((error: unknown) => failed("The thread could not be marked seen", error));
	}, [client, thread, shown, arrived, seen]);
}

function subscribe(changed: () => void): () => void {
	document.addEventListener("visibilitychange", changed);
	return () => document.removeEventListener("visibilitychange", changed);
}
