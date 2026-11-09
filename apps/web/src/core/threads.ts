/**
 * The threads as the sidebar and the palette show them, read from their rows as the node lists them: each thread's
 * title, its project — the folder it works in, by its name — how it stands, as its status icon says, what it asks the
 * person, and when it began; how it stands with the sub-threads it delegated to; when it last brought the person
 * something, and whether they have seen it; the projects, the folders the threads work in, the latest used first; and
 * the sidebar's sections — those pinned atop, then those open to the person, those that work, those snoozed and the
 * earlier kept apart, those archived in none, a sub-thread in none — and the times one is snoozed till.
 */
import type { Ask, Listed } from "@octoii-works/octoii-client";
import { linksAsWords } from "./links.ts";
import { mintedAt } from "./time.ts";

/** A project: the folder its threads work in, by its path and its name. */
export type Project = { readonly folder: string; readonly name: string };

/** How a thread stands, as its row's icon says: asking the person, working, failed, or at rest. */
export type ThreadStatus = "asks" | "working" | "failed" | "ready";

/** How a thread stands: what waits on the person first, then a turn that runs or inputs that wait, then how the last ended. */
export function statusOf(row: Listed): ThreadStatus {
	if (asksOf(row).length > 0) return "asks";
	if (row.state.status === "running" || row.state.inbox.length > 0) return "working";
	return row.state.status === "failed" ? "failed" : "ready";
}

/** What a thread waits on the person for, each as its fiber asks it. */
export function asksOf(row: Listed): readonly Ask[] {
	return row.state.processes.flatMap((process) =>
		process.requests.filter((request) => request.answer !== undefined).map((request) => ({ fiber: process.key, call: undefined, request })),
	);
}

/** When a thread asked the person last, in ms, as the key of its newest request was minted; none where it asks nothing. */
export function askedAt(row: Listed): number {
	return Math.max(0, ...asksOf(row).map((ask) => mintedAt(ask.request.key)));
}

/** How a thread stands with the sub-threads it delegated to, and since when. */
export type ThreadStanding = { readonly status: ThreadStatus; readonly since: number };

/**
 * How each thread among `rows` stands with its sub-threads there, at any depth, as the work it was given stands —
 * waiting on the person where any of them asks, since the newest ask; else working where any of them works, since the
 * first of those began; else as its own last turn ended, since it ended.
 */
export function standingsOf(rows: readonly Listed[]): (row: Listed) => ThreadStanding {
	const delegated = subThreadsBy(rows);
	const known = new Map<string, ThreadStanding>();
	const standingOf = (row: Listed): ThreadStanding => {
		const found = known.get(row.id);
		if (found !== undefined) return found;
		const status = statusOf(row);
		const own = { status, since: sinceOf(row, status) };
		// Its own first, so that a line of parents that came back to it would end.
		known.set(row.id, own);
		const standing = standingOfAll([own, ...(delegated.get(row.id) ?? []).map(standingOf)]) ?? own;
		known.set(row.id, standing);
		return standing;
	};
	return standingOf;
}

/** Since when a thread stands as `status` says on its own: since it asked, since its turn began, or since it ended. */
function sinceOf(row: Listed, status: ThreadStatus): number {
	if (status === "asks") return askedAt(row);
	if (status === "working") return activeAt(row);
	return row.state.ended_at ?? activeAt(row);
}

/**
 * When a thread last brought the person something, by its own times, standing as `standing` says with its
 * sub-threads: what it or one of them asks, since the newest ask; else its last turn's end. None, 0, while it works,
 * or where it brought nothing yet.
 */
export function arrivedAt(row: Listed, standing: ThreadStanding): number {
	if (standing.status === "asks") return standing.since;
	if (standing.status === "working") return 0;
	return row.state.ended_at ?? 0;
}

/** Whether a thread brought the person something they have not seen yet. */
export function isUnread(row: Listed, standing: ThreadStanding): boolean {
	return arrivedAt(row, standing) > (row.manifest.seen_until ?? 0);
}

/** How long what a thread brought keeps it among those open to the person, after which it rests among the earlier: a week. */
export const OPEN_FOR_MS = 7 * 24 * 60 * 60 * 1000;

/**
 * Whether a thread is open to the person at `now`: it asks them, or it brought them something within `OPEN_FOR_MS`.
 * Every other rests among the earlier by itself, the person never asked to say they are done with it; one they would
 * put away sooner they archive.
 */
export function isOpen(row: Listed, standing: ThreadStanding, now: number): boolean {
	if (standing.status === "asks") return true;
	const arrived = arrivedAt(row, standing);
	return arrived > 0 && now - arrived <= OPEN_FOR_MS;
}

/** Whether a thread may be marked unread: it brought something, and the person has seen it. */
export function canMarkUnread(row: Listed, standing: ThreadStanding): boolean {
	return arrivedAt(row, standing) > 0 && !isUnread(row, standing);
}

/** How a thread and its sub-threads stand as one, by how each does: none where none of them asks or works. */
function standingOfAll(standings: readonly ThreadStanding[]): ThreadStanding | undefined {
	const asking = standings.filter((each) => each.status === "asks");
	if (asking.length > 0) return { status: "asks", since: Math.max(...asking.map((each) => each.since)) };
	const working = standings.filter((each) => each.status === "working");
	if (working.length > 0) return { status: "working", since: Math.min(...working.map((each) => each.since)) };
	return undefined;
}

/** The sub-threads among `rows` by the thread that delegated to them, newest first as the rows are, those archived left out. */
export function subThreadsBy(rows: readonly Listed[]): ReadonlyMap<string, readonly Listed[]> {
	const delegated = new Map<string, Listed[]>();
	for (const row of rows) {
		const parent = row.manifest.parent?.thread;
		if (parent === undefined || isArchived(row)) continue;
		const siblings = delegated.get(parent);
		if (siblings === undefined) delegated.set(parent, [row]);
		else siblings.push(row);
	}
	return delegated;
}

/** The thread `id` and those above it among `rows`, nearest first: the thread that delegated to it, that one's, and on up. */
export function lineOf(rows: readonly Listed[], id: string): readonly string[] {
	const parents = new Map(rows.map((row) => [row.id, row.manifest.parent?.thread]));
	const line = [id];
	for (let parent = parents.get(id); parent !== undefined && !line.includes(parent); parent = parents.get(parent)) line.push(parent);
	return line;
}

/** The longest title a thread is given from its first message. */
const TITLE_CHARACTERS = 80;

/**
 * The title a thread is given from its first message: its first line, each link by its words — a file mentioned by its
 * name — cut at a word past `TITLE_CHARACTERS`.
 */
export function titleOf(message: string): string {
	const line = linksAsWords(message.trim().split("\n")[0]?.trim() ?? "");
	if (line.length <= TITLE_CHARACTERS) return line;
	const cut = line.slice(0, TITLE_CHARACTERS);
	const space = cut.lastIndexOf(" ");
	return `${(space > TITLE_CHARACTERS / 2 ? cut.slice(0, space) : cut).trimEnd()}…`;
}

/** A thread's title in a list: the one it was given, else what a new one is called. */
export function threadTitle(row: Listed): string {
	return row.manifest.title ?? "New thread";
}

/** When a thread last set to work, in ms: its latest turn's beginning, else its making, as its id was minted. */
export function activeAt(row: Listed): number {
	return row.state.began_at ?? mintedAt(row.id);
}

/** A thread's project: the folder of the repository it works in, else the folder it works in; none for one that works in no folder. */
export function projectOf(row: Listed): Project | undefined {
	const folder = row.manifest.project;
	return folder === undefined ? undefined : { folder, name: folderName(folder) };
}

/** The projects the threads work in, the one its newest thread works in first. */
export function projectsOf(rows: readonly Listed[]): readonly Project[] {
	const folders = new Map<string, Project>();
	for (const row of rows) {
		const project = projectOf(row);
		if (project !== undefined && !folders.has(project.folder)) folders.set(project.folder, project);
	}
	return [...folders.values()];
}

/** A folder's name: the last part of its path. */
export function folderName(folder: string): string {
	return (
		folder
			.replace(/[/\\]+$/, "")
			.split(/[/\\]/)
			.at(-1) ?? folder
	);
}

/** The threads that hold `query` in their title or their project's name, ignoring case; all of them for an empty query. */
export function matchingRows(rows: readonly Listed[], query: string): readonly Listed[] {
	const wanted = query.trim().toLowerCase();
	if (wanted === "") return rows;
	return rows.filter((row) => `${threadTitle(row)} ${projectOf(row)?.name ?? ""}`.toLowerCase().includes(wanted));
}

/** Whether the person pinned the thread, which keeps it atop their threads. */
export function isPinned(row: Listed): boolean {
	return row.manifest.pinned === true;
}

/** Whether the person archived the thread, which keeps it out of their threads. */
export function isArchived(row: Listed): boolean {
	return row.manifest.archived === true;
}

/** Whether the person snoozed the thread till a time that has not come by `now`. */
export function isSnoozed(row: Listed, now: number): boolean {
	return (row.manifest.snoozed_until ?? 0) > now;
}

/** The sidebar's sections of threads. */
export type Sections = {
	/** The threads the person pinned, atop, in the order the list gives them. */
	readonly pinned: readonly Listed[];
	/** The rest open to the person: those that ask them first, then by what they brought, the latest first. */
	readonly open: readonly Listed[];
	/** Those that work, with their sub-threads, in the order the list gives them. */
	readonly working: readonly Listed[];
	/** Those snoozed till a time to come, kept apart till then. */
	readonly snoozed: readonly Listed[];
	/** Those that brought the person nothing within `OPEN_FOR_MS`, by what they last brought, the latest first. */
	readonly earlier: readonly Listed[];
};

/** The sub-threads of the thread `id` among `rows`, those it delegated to, newest first as the rows are. */
export function subThreadsOf(rows: readonly Listed[], id: string): readonly Listed[] {
	return rows.filter((row) => row.manifest.parent?.thread === id);
}

/**
 * The sub-thread of the thread `id` among `rows` a delegating call gave its task to, where there is one: the one its
 * arguments name, or else the one it made, which names the call by Siphon's id of it, which no other call has.
 */
export function subThreadOf(
	rows: readonly Listed[],
	id: string,
	call: { readonly fiber: string | undefined; readonly thread: string | undefined },
): Listed | undefined {
	const ours = subThreadsOf(rows, id);
	if (call.thread !== undefined) return ours.find((row) => row.id === call.thread);
	if (call.fiber === undefined) return undefined;
	return ours.find((row) => row.manifest.parent?.call === call.fiber);
}

/**
 * The threads in the sidebar's sections, at `now`, each standing as `standingOf` tells: those archived in none of them,
 * and a sub-thread in none where its parent is among `rows`, the parent's card standing for it.
 */
export function rowsBySection(rows: readonly Listed[], now: number, standingOf: (row: Listed) => ThreadStanding): Sections {
	const ids = new Set(rows.map((row) => row.id));
	const listed = rows.filter((row) => !isArchived(row) && !ids.has(row.manifest.parent?.thread ?? ""));
	const snoozed = listed.filter((row) => isSnoozed(row, now));
	const awake = listed.filter((row) => !isSnoozed(row, now));
	const pinned = awake.filter(isPinned);
	const rest = awake.filter((row) => !isPinned(row));
	const works = (row: Listed): boolean => standingOf(row).status === "working";
	const resting = rest.filter((row) => !works(row));
	const open = resting.filter((row) => isOpen(row, standingOf(row), now));
	const earlier = resting.filter((row) => !isOpen(row, standingOf(row), now));
	// What asks the person stands before what only brought them something; within each, the latest first.
	const asks = (row: Listed): number => (standingOf(row).status === "asks" ? 1 : 0);
	const arrived = (row: Listed): number => arrivedAt(row, standingOf(row));
	const latestFirst = (left: Listed, right: Listed): number => arrived(right) - arrived(left);
	return {
		pinned,
		open: open.toSorted((left, right) => asks(right) - asks(left) || latestFirst(left, right)),
		working: rest.filter(works),
		snoozed,
		earlier: earlier.toSorted(latestFirst),
	};
}

/** A time a thread may be snoozed till: its name, and when, in ms. */
export type SnoozeTime = { readonly label: string; readonly until: number };

/**
 * The times a thread may be snoozed till, from `now` in the device's own time: an hour on; this evening at six, where
 * it is not yet five; tomorrow at nine; and next Monday at nine.
 */
export function snoozeTimes(now: number): readonly SnoozeTime[] {
	const at = (days: number, hour: number): number => {
		const day = new Date(now);
		day.setDate(day.getDate() + days);
		day.setHours(hour, 0, 0, 0);
		return day.getTime();
	};
	const today = new Date(now);
	const evening = today.getHours() < 17 ? [{ label: "This evening", until: at(0, 18) }] : [];
	const toMonday = ((8 - today.getDay()) % 7) + (today.getDay() === 1 ? 7 : 0);
	return [
		{ label: "In an hour", until: now + 60 * 60 * 1000 },
		...evening,
		{ label: "Tomorrow", until: at(1, 9) },
		{ label: "Next week", until: at(toMonday, 9) },
	];
}
