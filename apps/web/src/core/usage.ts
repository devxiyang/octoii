/**
 * The plans' limits, pooled as the usage page shows them: for each of the node's providers whose accounts tell theirs,
 * a card for each window — five hours, a week, a week of some models alone — with a line for each account, the one
 * given again soonest first.
 */
import type { Limit, Provider, ProviderStatus } from "@octoii-works/octoii-client";
import { windowWords } from "./limits.ts";

/** An account's line on a window's card: its name, how much is used, in percent, and when it is given again. */
export type UsageLine = { readonly account: string; readonly usedPercent: number | undefined; readonly resetsAt: number | undefined };

/** A window's card: its title, and a line for each account. */
export type UsageWindow = { readonly key: string; readonly title: string; readonly lines: readonly UsageLine[] };

/** A provider's cards: its name, and a card for each window its accounts tell. */
export type UsageGroup = { readonly provider: string; readonly windows: readonly UsageWindow[] };

/** The cards of the providers whose accounts told their limits in `statuses`, by each provider's id, in the node's order. */
export function usageOf(providers: readonly Provider[], statuses: ReadonlyMap<string, ProviderStatus>): readonly UsageGroup[] {
	const hosts = providers.filter((each) => each.account === undefined);
	return hosts.flatMap((host) => {
		const accounts = providers.filter((each) => each.id === host.id || each.account?.of === host.id);
		const windows = new Map<string, { title: string; lines: UsageLine[] }>();
		for (const account of accounts) {
			for (const limit of statuses.get(account.id)?.limits ?? []) {
				const key = `${String(limit.window_minutes)} ${limit.scope ?? ""}`;
				const window = windows.get(key) ?? { title: titleOf(limit), lines: [] };
				window.lines.push({ account: account.account?.name ?? account.name, usedPercent: limit.used_percent, resetsAt: limit.resets_at_ms });
				windows.set(key, window);
			}
		}
		if (windows.size === 0) return [];
		const cards = [...windows].map(([key, window]) => ({ key, title: window.title, lines: window.lines.toSorted(bySoonest) }));
		return [{ provider: host.name, windows: cards }];
	});
}

/** A window's title: its length, and the models it is of where it is of some alone — "5-hour limit", "Weekly limit · Opus". */
function titleOf(limit: Limit): string {
	const words = windowWords(limit.window_minutes) ?? "";
	const named = `${words.charAt(0).toUpperCase()}${words.slice(1)} limit`;
	return limit.scope === undefined ? named : `${named} · ${limit.scope}`;
}

/** The line given again sooner first; one whose reset is not known last. */
function bySoonest(a: UsageLine, b: UsageLine): number {
	return (a.resetsAt ?? Number.POSITIVE_INFINITY) - (b.resetsAt ?? Number.POSITIVE_INFINITY);
}
