/**
 * The plans' limits, pooled as the usage page shows them: for each of the node's providers whose accounts tell theirs,
 * a card for each window — five hours, a week, a week of some models alone — with how much its accounts have left
 * together, how they spend it against its time, what the next reset gives back, and a segment for each account that
 * tells limits, in the order the accounts were added, so that an account stands in the same place on every card.
 */
import type { Limit, Provider, ProviderStatus } from "@octoii-works/octoii-client";
import { windowWords } from "./limits.ts";
import { type Hue, monogramHue } from "./monogram.ts";

/** How a window is spent against its time: faster than it passes, at its pace, or slower, leaving room. */
export type Pace = "ahead" | "on" | "under";

/**
 * An account's segment of a window's bar: its name, its monogram's hue, how much of the window it has left, in percent,
 * when it is given again, and how much of the window's time is left, from 0 to 1 — as much as would be left of it were
 * it used evenly — each where the account tells.
 */
export type UsageSegment = {
	readonly account: string;
	readonly hue: Hue;
	readonly leftPercent: number | undefined;
	readonly resetsAt: number | undefined;
	readonly timeLeft: number | undefined;
};

/** An account's column on a window's card, by the account's id: its segment, or none where it tells no such window. */
export type UsageColumn = { readonly id: string; readonly segment: UsageSegment | undefined };

/** What a window's next reset gives back: how much of the pool, in percent, and when. */
export type GivenBack = { readonly percent: number; readonly at: number };

/**
 * A window's card: its title, how long it lasts, in minutes, how much its accounts have left together, in percent, how
 * they spend it, what its next reset gives back where it has several accounts, and a column for each account of the
 * provider that tells limits.
 */
export type UsageWindow = {
	readonly key: string;
	readonly title: string;
	readonly minutes: number;
	readonly leftPercent: number | undefined;
	readonly pace: Pace | undefined;
	readonly next: GivenBack | undefined;
	readonly columns: readonly UsageColumn[];
};

/** A provider's cards: its name, and a card for each window its accounts tell. */
export type UsageGroup = { readonly provider: string; readonly windows: readonly UsageWindow[] };

/** A window as its accounts told it: one of their limits, for its length and title, and the accounts' segments. */
type Told = { readonly limit: Limit; readonly columns: UsageColumn[] };

/** The cards of the providers whose accounts told their limits in `statuses`, by each provider's id, in the node's order, at `now`. */
export function usageOf(providers: readonly Provider[], statuses: ReadonlyMap<string, ProviderStatus>, now: number): readonly UsageGroup[] {
	const hosts = providers.filter((each) => each.account === undefined);
	return hosts.flatMap((host) => {
		const accounts = providers.filter((each) => (each.id === host.id || each.account?.of === host.id) && (statuses.get(each.id)?.limits?.length ?? 0) > 0);
		const windows = new Map<string, Told>();
		for (const [column, account] of accounts.entries()) {
			for (const limit of statuses.get(account.id)?.limits ?? []) {
				const key = `${String(limit.window_minutes)} ${limit.scope ?? ""}`;
				const told = windows.get(key) ?? { limit, columns: accounts.map((each) => ({ id: each.id, segment: undefined })) };
				told.columns[column] = { id: account.id, segment: segmentOf(account, limit, now) };
				windows.set(key, told);
			}
		}
		if (windows.size === 0) return [];
		return [{ provider: host.name, windows: [...windows].map(([key, told]) => windowOf(key, told)) }];
	});
}

/** An account's segment of the window `limit` tells, at `now`. */
function segmentOf(account: Provider, limit: Limit, now: number): UsageSegment {
	return {
		account: account.account?.name ?? account.name,
		hue: monogramHue(account.name),
		leftPercent: limit.used_percent === undefined ? undefined : 100 - percentOf(limit.used_percent),
		resetsAt: limit.resets_at_ms,
		timeLeft: timeLeftOf(limit.resets_at_ms, limit.window_minutes, now),
	};
}

/**
 * A window's card, from what its accounts told: what they have left, on average — each account's share of the pool
 * the same — their pace, judged of those whose resets are known, and what the soonest reset gives back of the pool.
 */
function windowOf(key: string, told: Told): UsageWindow {
	const segments = told.columns.flatMap(({ segment }) =>
		segment?.leftPercent === undefined ? [] : [{ left: segment.leftPercent, resetsAt: segment.resetsAt, timeLeft: segment.timeLeft }],
	);
	const timed = segments.flatMap((each) => (each.timeLeft === undefined ? [] : [{ left: each.left, timeLeft: each.timeLeft }]));
	const soonest = segments.flatMap((each) => (each.resetsAt === undefined ? [] : [{ left: each.left, at: each.resetsAt }])).toSorted((a, b) => a.at - b.at)[0];
	return {
		key,
		title: titleOf(told.limit),
		minutes: told.limit.window_minutes,
		leftPercent: segments.length === 0 ? undefined : meanOf(segments.map((each) => each.left)),
		pace: timed.length === 0 ? undefined : paceOf(100 - meanOf(timed.map((each) => each.left)), 1 - meanOf(timed.map((each) => each.timeLeft))),
		next:
			told.columns.length > 1 && soonest !== undefined && soonest.left < 100 ? { percent: (100 - soonest.left) / segments.length, at: soonest.at } : undefined,
		columns: told.columns,
	};
}

/** A window's title: its length, and the models it is of where it is of some alone — "5-hour limit", "Weekly limit · Opus". */
function titleOf(limit: Limit): string {
	const words = windowWords(limit.window_minutes) ?? "";
	const named = `${words.charAt(0).toUpperCase()}${words.slice(1)} limit`;
	return limit.scope === undefined ? named : `${named} · ${limit.scope}`;
}

/**
 * How a window is spent: ahead where more of it is used, in percent, than of its time passed, `elapsed`, from 0 to 1,
 * by more than five points; under where less by as much; else on its pace.
 */
export function paceOf(usedPercent: number, elapsed: number): Pace {
	const gap = usedPercent - elapsed * 100;
	if (gap > 5) return "ahead";
	if (gap < -5) return "under";
	return "on";
}

/** How much of the time of a window of `minutes` given again at `resetsAt` is left at `now`, from 0 to 1; none where its reset is not known. */
function timeLeftOf(resetsAt: number | undefined, minutes: number, now: number): number | undefined {
	if (resetsAt === undefined || minutes <= 0) return undefined;
	return Math.min(1, Math.max(0, (resetsAt - now) / (minutes * 60_000)));
}

/** A percentage as a bar holds it: from 0 to 100. */
function percentOf(value: number): number {
	return Math.min(100, Math.max(0, value));
}

function meanOf(values: readonly number[]): number {
	return values.reduce((sum, each) => sum + each, 0) / values.length;
}

/** How long till `at`, from `now`, as a countdown reads it: "2d 7h", "3h 51m", "12m". */
export function countdown(at: number, now: number): string {
	const minutes = Math.max(0, Math.ceil((at - now) / 60_000));
	const days = Math.floor(minutes / (24 * 60));
	const hours = Math.floor((minutes % (24 * 60)) / 60);
	if (days > 0) return `${String(days)}d ${String(hours)}h`;
	if (hours > 0) return `${String(hours)}h ${String(minutes % 60)}m`;
	return `${String(minutes)}m`;
}
