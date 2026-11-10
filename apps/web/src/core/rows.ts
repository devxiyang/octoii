/**
 * The timeline's rows, as its list draws them: each turn laid out flat — the words that began it or steered it on, each
 * part of its work, its reply, and its end: what it does now while it works, else what it changed, what waits on the
 * person, why it failed and its foot — and what is the thread's own between turns, a row each; every row with the room
 * it leaves above it, by what stands before it in its turn. A row that is the same as it was stays the same object, so
 * the list draws again only the rows that changed.
 */
import type { Ask, Limited } from "@octoii-works/octoii-client";
import {
	type Changed,
	doingOf,
	type Laid,
	laidOut,
	replyOf,
	type Said,
	type TimelineItem,
	type TimelineTurn,
	waitsOnPerson,
	type Work,
	workedText,
} from "./timeline.ts";

/** The room a row leaves above it: a turn's, a message's, a part of a turn's, or a line of its work's. */
export type Room = "turn" | "message" | "part" | "line";

/** What a turn that works does now, as its last line tells it: in words, whether that waits on the person, and since when it works. */
export type Doing = { readonly words: string; readonly waits: boolean; readonly since: number | undefined };

/** The foot of a turn that ended: its reply as it was written, how long it worked, or that it was stopped, and when it ended. */
export type Foot = { readonly reply: string; readonly worked: string | undefined; readonly endedAt: number | undefined };

/**
 * The end of a turn, its last row: the files it changed, once it ended; what waits on the person that no call asks;
 * why it failed, where it did; and what it does now while it works, or its foot once it ended — none for a part the
 * person steered on, as the turn goes on under it.
 */
export type TurnEnd = {
	readonly changes: readonly Changed[];
	readonly asks: readonly Ask[];
	readonly failure: string | undefined;
	readonly doing: Doing | undefined;
	readonly foot: Foot | undefined;
};

/** A row of the timeline, by its key, which it keeps as the thread grows, and the room it leaves above it. */
export type TimelineRow =
	| { readonly kind: "said"; readonly key: string; readonly room: Room; readonly said: Said }
	| { readonly kind: "work"; readonly key: string; readonly room: Room; readonly laid: Laid }
	| { readonly kind: "reply"; readonly key: string; readonly room: Room; readonly text: string }
	| { readonly kind: "end"; readonly key: string; readonly room: Room; readonly end: TurnEnd }
	| { readonly kind: "summed-up"; readonly key: string; readonly room: Room }
	| { readonly kind: "ask"; readonly key: string; readonly room: Room; readonly ask: Ask }
	| { readonly kind: "limited"; readonly key: string; readonly room: Room; readonly limited: Limited; readonly resumingAt: number | undefined };

/** The rows of the timeline's items, in their order. */
export function rowsOf(items: readonly TimelineItem[]): readonly TimelineRow[] {
	return items.flatMap((item): readonly TimelineRow[] => {
		switch (item.kind) {
			case "turn":
				return turnRows(item.turn);
			case "summed-up":
				return [{ kind: "summed-up", key: `summed-up:${item.key}`, room: "turn" }];
			case "ask":
				return [{ kind: "ask", key: `ask:${item.key}`, room: "turn", ask: item.ask }];
			case "limited":
				return [{ kind: "limited", key: "limited", room: "turn", limited: item.limited, resumingAt: item.resumingAt }];
		}
	});
}

/** Each turn that ended laid out as rows, by the turn as the page shows it: laid out once, as a turn that ended is the same. */
const laidTurns = new WeakMap<TimelineTurn, readonly TimelineRow[]>();

/**
 * The rows of `turn`: its words, each part of its work, its reply and its end — the first with a turn's room above it,
 * a message's after its words, a part's between the parts of what it did, a line's between the lines of its work.
 */
function turnRows(turn: TimelineTurn): readonly TimelineRow[] {
	const known = laidTurns.get(turn);
	if (known !== undefined) return known;
	const rows: TimelineRow[] = [];
	const roomAfter = (kind: TimelineRow["kind"]): Room => {
		const last = rows.at(-1);
		if (last === undefined) return "turn";
		if (last.kind === "said") return "message";
		return kind === "work" && last.kind === "work" ? "line" : "part";
	};
	for (const said of turn.said) rows.push({ kind: "said", key: `said:${said.key}`, room: roomAfter("said"), said });
	for (const laid of laidOut(turn.work)) rows.push({ kind: "work", key: `work:${laidKey(laid)}`, room: roomAfter("work"), laid });
	const reply = replyOf(turn);
	if (reply !== "") rows.push({ kind: "reply", key: `reply:${turn.key}`, room: roomAfter("reply"), text: reply });
	const end = endOf(turn, reply);
	if (end !== undefined) rows.push({ kind: "end", key: `end:${turn.key}`, room: roomAfter("end"), end });
	if (turn.ending.state !== "working") laidTurns.set(turn, rows);
	return rows;
}

/** The key of what is laid out: a stretch's, delegations', or its step's. */
export function laidKey(laid: Laid): string {
	if (laid.kind !== "step") return laid.key;
	return laid.step.kind === "call" ? laid.step.id : laid.step.key;
}

/** The end of `turn`, whose reply is `reply`; none for a part the person steered on that changed nothing and waits on nothing. */
function endOf(turn: TimelineTurn, reply: string): TurnEnd | undefined {
	const working = turn.ending.state === "working";
	const end: TurnEnd = {
		changes: working ? [] : turn.changes,
		asks: turn.asks,
		failure: turn.ending.state === "failed" ? turn.ending.why : undefined,
		doing: working ? { words: doingOf(turn), waits: waitsOnPerson(turn), since: turn.startedAt } : undefined,
		foot: working || turn.ending.state === "steered" ? undefined : { reply, worked: workedText(turn), endedAt: turn.endedAt },
	};
	const empty = end.changes.length === 0 && end.asks.length === 0 && end.failure === undefined && end.doing === undefined && end.foot === undefined;
	return empty ? undefined : end;
}

/**
 * `rows`, each that is the same as the row of its key in `previous` given as that row — so a row that did not change
 * stays the same object — and the rows by their keys, to give as `previous` next time.
 */
export function steadyRows(
	rows: readonly TimelineRow[],
	previous: ReadonlyMap<string, TimelineRow>,
): { readonly rows: readonly TimelineRow[]; readonly byKey: ReadonlyMap<string, TimelineRow> } {
	const byKey = new Map<string, TimelineRow>();
	const steady = rows.map((row) => {
		const before = previous.get(row.key);
		const kept = before !== undefined && sameRow(before, row) ? before : row;
		byKey.set(row.key, kept);
		return kept;
	});
	return { rows: steady, byKey };
}

/** Whether two rows of one key show the same: the same kind, room and content. */
function sameRow(a: TimelineRow, b: TimelineRow): boolean {
	if (a === b) return true;
	if (a.room !== b.room) return false;
	switch (a.kind) {
		case "said":
			return b.kind === "said" && a.said === b.said;
		case "work":
			return b.kind === "work" && sameLaid(a.laid, b.laid);
		case "reply":
			return b.kind === "reply" && a.text === b.text;
		case "end":
			return b.kind === "end" && sameEnd(a.end, b.end);
		case "summed-up":
			return b.kind === "summed-up";
		case "ask":
			return b.kind === "ask" && a.ask === b.ask;
		case "limited":
			return b.kind === "limited" && a.limited === b.limited && a.resumingAt === b.resumingAt;
	}
}

/** Whether two laid-out parts of work are the same: their steps the same, a call's line the same object. */
function sameLaid(a: Laid, b: Laid): boolean {
	switch (a.kind) {
		case "step":
			return b.kind === "step" && sameWork(a.step, b.step);
		case "calls":
			return b.kind === "calls" && a.key === b.key && sameItems(a.steps, b.steps, sameWork) && sameItems(a.calls, b.calls, Object.is);
		case "delegations":
			return b.kind === "delegations" && a.key === b.key && sameItems(a.calls, b.calls, Object.is);
	}
}

/** Whether two steps of work are the same: a call's line the same object, any other step the same in what it shows. */
function sameWork(a: Work, b: Work): boolean {
	if (a === b) return true;
	switch (a.kind) {
		case "call":
			return false;
		case "thought":
			return b.kind === "thought" && a.key === b.key && a.text === b.text && a.took === b.took;
		case "words":
		case "failure":
			return b.kind === a.kind && a.key === b.key && a.text === b.text;
		case "web-search":
			return b.kind === "web-search" && a.key === b.key && a.query === b.query;
		case "compaction":
			return b.kind === "compaction" && a.key === b.key;
	}
}

/** Whether two ends of a turn show the same. */
function sameEnd(a: TurnEnd, b: TurnEnd): boolean {
	return (
		sameItems(a.changes, b.changes, (x, y) => x.path === y.path && x.added === y.added && x.removed === y.removed) &&
		sameItems(a.asks, b.asks, Object.is) &&
		a.failure === b.failure &&
		(a.doing === b.doing ||
			(a.doing !== undefined &&
				b.doing !== undefined &&
				a.doing.words === b.doing.words &&
				a.doing.waits === b.doing.waits &&
				a.doing.since === b.doing.since)) &&
		(a.foot === b.foot ||
			(a.foot !== undefined && b.foot !== undefined && a.foot.reply === b.foot.reply && a.foot.worked === b.foot.worked && a.foot.endedAt === b.foot.endedAt))
	);
}

/** Whether two lists hold the same items in order, as `same` compares them. */
function sameItems<Item>(a: readonly Item[], b: readonly Item[], same: (x: Item, y: Item) => boolean): boolean {
	return (
		a.length === b.length &&
		a.every((item, index) => {
			const other = b[index];
			return other !== undefined && same(item, other);
		})
	);
}
