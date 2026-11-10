/**
 * How the node's providers stand, each asked of the node by its id — for a page that shows them all at once, such as
 * the usage page — as the component that asks first draws, again as a connection opens, and as it asks again.
 */
import { useEffect, useState } from "react";
import type { Provider, ProviderStatus } from "@octoii-works/octoii-client";
import { useClient, useConnection } from "@octoii-works/octoii-client/react";
import { inTurns } from "../../core/turns.ts";
import { failureOf } from "./read.ts";

/**
 * How many providers are asked at once: the node runs only so many of a client's requests that run off its loop at a
 * time, eight, and the page's other reads keep the rest.
 */
const AT_ONCE = 3;

/**
 * How each of `providers` stands, asked of the node by each one's id as the page opens, again as a connection opens and
 * as `asked` changes; none till every one answered. One the node would not tell of stands as one that does not answer,
 * the node's words what is wrong.
 */
export function useStatuses(providers: readonly Provider[] | undefined, asked: number): ReadonlyMap<string, ProviderStatus> | undefined {
	const client = useClient();
	const open = useConnection().status === "open";
	const ids = providers?.map((each) => each.id).join(" ");
	const [read, setRead] = useState<{ readonly key: string; readonly statuses: ReadonlyMap<string, ProviderStatus> } | undefined>(undefined);
	const key = `${ids ?? ""}#${String(asked)}`;
	useEffect(() => {
		if (!open || ids === undefined) return undefined;
		let current = true;
		const each = ids === "" ? [] : ids.split(" ");
		const told = async (id: string): Promise<ProviderStatus> =>
			client.providerStatus(id).catch((error: unknown) => ({ connected: false, problem: failureOf(error) }));
		void inTurns(each, AT_ONCE, async (id) => [id, await told(id)] as const).then((answered) => {
			if (current) setRead({ key, statuses: new Map(answered) });
		});
		return () => {
			current = false;
		};
	}, [client, ids, key, open]);
	return read?.key === key ? read.statuses : undefined;
}
