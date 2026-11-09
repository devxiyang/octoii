/**
 * Sub-threads as the thread that delegated to them shows them: how each stands — as it works, or how its work ended —
 * from its own status where it is listed, from the call that gave it its task where it is not; when they worked; and
 * what a sub-thread said, in a line.
 */
import type { Listed } from "@octoii-works/octoii-client";
import type { CallLine } from "./timeline.ts";

/** How a sub-thread stands. */
export type Standing = "running" | "completed" | "failed" | "stopped";

/** How the sub-thread `row` stands, by its status; where it is not listed — not made, or deleted — as `call` stands. */
export function standingOf(row: Listed | undefined, call?: CallLine): Standing {
	if (row !== undefined) {
		switch (row.standing.status) {
			case "created":
			case "running":
				return "running";
			case "replied":
				return "completed";
			case "failed":
				return "failed";
			case "stopped":
				return "stopped";
		}
	}
	switch (call?.state) {
		case "running":
		case "waiting":
			return "running";
		case "done":
			return "completed";
		case "failed":
		case "rejected":
			return "failed";
		case "stopped":
		case undefined:
			return "stopped";
	}
}

/** When sub-threads worked: from the first one's latest turn's beginning to the last one's end — none while any works. */
export type Worked = { readonly began: number; readonly ended: number | undefined };

/** When the sub-threads `rows` worked on what they were last given; none where none began, or none is listed. */
export function workedOf(rows: readonly (Listed | undefined)[]): Worked | undefined {
	const spans = rows.flatMap((row) => (row?.standing.began_at === undefined ? [] : [{ began: row.standing.began_at, ended: row.standing.ended_at }]));
	if (spans.length === 0) return undefined;
	const ends = spans.flatMap((span) => (span.ended === undefined ? [] : [span.ended]));
	return { began: Math.min(...spans.map((span) => span.began)), ended: ends.length < spans.length ? undefined : Math.max(...ends) };
}

/** How many sub-threads stand each way, in words — "2 running · 1 completed" — the ways none stand left out. */
export function standingsSummary(standings: readonly Standing[]): string {
	const order: readonly Standing[] = ["running", "completed", "failed", "stopped"];
	return order
		.map((standing) => [standing, standings.filter((each) => each === standing).length] as const)
		.filter(([, count]) => count > 0)
		.map(([standing, count]) => `${String(count)} ${standing}`)
		.join(" · ");
}

/** What a sub-thread said, as one plain line: its links by their words, its code, emphasis, heading and list marks let go of, its breaks as spaces. */
export function plainLine(text: string): string {
	return text
		.replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
		.replace(/`|\*\*|__/g, "")
		.replace(/^[ \t]*#+[ \t]+/gm, "")
		.replace(/^[ \t]*[-*][ \t]+/gm, "")
		.replace(/\s+/g, " ")
		.trim();
}
