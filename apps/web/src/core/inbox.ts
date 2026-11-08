/**
 * The inbox, the page's home: the threads that wait on the person, to be answered on their cards — a sub-thread among
 * them on its own, named by the thread it works for — the threads whose work goes on, and those whose work ended of
 * late, each newest first, each of these two with its sub-threads under it, and standing as they and it do together.
 * A thread archived stands in none, and one snoozed in none but the first: what waits on the person waits all the same.
 */
import type { Listed } from "@octoii-works/octoii-client";
import { askedAt, isArchived, isSnoozed, standingsOf, statusOf, type ThreadStanding } from "./threads.ts";

/** The inbox's columns, and how a thread in them stands with its sub-threads. */
export type Inbox = {
	readonly asking: readonly Listed[];
	readonly working: readonly Listed[];
	readonly done: readonly Listed[];
	readonly standingOf: (row: Listed) => ThreadStanding;
};

/** How many threads done of late the inbox shows. */
export const DONE_SHOWN = 20;

/** The inbox of `rows` at `now`. */
export function inboxOf(rows: readonly Listed[], now: number): Inbox {
	const kept = rows.filter((row) => !isArchived(row));
	const ids = new Set(kept.map((row) => row.id));
	const top = kept.filter((row) => !ids.has(row.manifest.parent?.thread ?? ""));
	const standingOf = standingsOf(kept);
	// A thread's work goes on while it, or a sub-thread of it, works or waits on the person.
	const goesOn = (row: Listed): boolean => standingOf(row).status === "asks" || standingOf(row).status === "working";
	return {
		asking: newestFirst(
			kept.filter((row) => statusOf(row) === "asks"),
			askedAt,
		),
		working: newestFirst(
			top.filter((row) => goesOn(row) && statusOf(row) !== "asks"),
			(row) => standingOf(row).since,
		),
		done: newestFirst(
			top.filter((row) => !goesOn(row) && row.state.began_at !== undefined && !isSnoozed(row, now)),
			(row) => row.state.ended_at ?? 0,
		).slice(0, DONE_SHOWN),
		standingOf,
	};
}

/** `rows`, the one whose `at` is the latest first. */
function newestFirst(rows: readonly Listed[], at: (row: Listed) => number): readonly Listed[] {
	return rows.toSorted((a, b) => at(b) - at(a));
}
