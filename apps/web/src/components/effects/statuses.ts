/**
 * How the node's providers stand, each asked of the node by its id — for a page that shows them all at once, such as
 * the usage page — as the component that asks first draws, again as a connection opens, and as it asks again.
 */
import { useEffect, useState } from "react";
import type { Provider, ProviderStatus } from "@octoii-works/octoii-client";
import { useClient, useConnection } from "@octoii-works/octoii-client/react";

/**
 * How each of `providers` stands, asked of the node by each one's id as the page opens, again as a connection opens and
 * as `asked` changes; none till every one answered. One that could not be asked is left out.
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
		void Promise.all(each.map(async (id) => [id, await client.providerStatus(id).catch(() => undefined)] as const)).then((answered) => {
			if (!current) return;
			setRead({ key, statuses: new Map(answered.flatMap(([id, status]) => (status === undefined ? [] : [[id, status] as const]))) });
		});
		return () => {
			current = false;
		};
	}, [client, ids, key, open]);
	return read?.key === key ? read.statuses : undefined;
}
