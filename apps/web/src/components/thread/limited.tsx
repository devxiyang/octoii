/**
 * A thread its model's quota limits, as a card at its timeline's end: whose quota, over what window, used up till when;
 * and the ways on — another account of the same provider with room, its model the same; going on as the quota is given
 * again, or no more; or the thread put away till then.
 */
import type { ReactNode } from "react";
import type { Limited } from "@octoii-works/octoii-client";
import { useClient, useThreads } from "@octoii-works/octoii-client/react";
import { Gauge } from "lucide-react";
import { onwardOf, windowWords } from "../../core/limits.ts";
import { wakeLabel } from "../../core/time.ts";
import { useDirectory } from "../composer/directory.ts";
import { useNow } from "../effects/now.ts";
import { failed } from "../state/notices.ts";
import { Button } from "../ui/button.tsx";
import { IconTile } from "../ui/icon-tile.tsx";

/** The person's word to go on with, on another account. */
const GO_ON = "Continue where you stopped.";

/** The card of `thread`, limited as `limited` says, going on at `resumingAt` where the person asked it to. */
export function LimitedCard(props: { readonly thread: string; readonly limited: Limited; readonly resumingAt: number | undefined }): ReactNode {
	const client = useClient();
	const directory = useDirectory();
	const model = useThreads()?.find((row) => row.id === props.thread)?.manifest.model;
	const now = useNow(60_000);
	const { limited } = props;
	const provider = directory?.providers.find((each) => each.id === limited.provider)?.name ?? limited.provider;
	const window = windowWords(limited.window_minutes);
	const at = wakeLabel(limited.reset_at_ms, now);
	const onward = directory === undefined || model === undefined ? [] : onwardOf(directory, limited, model);
	const goOnWith = (reference: string): void =>
		void client
			.configure(props.thread, { model: reference })
			.then(() => client.deliver(props.thread, { message: { role: "user", content: GO_ON } }))
			.catch((error: unknown) => failed("The thread could not go on with that account", error));
	const resume = (when: number | undefined): void =>
		void client.resume(props.thread, when).catch((error: unknown) => failed("The thread's resume could not be set", error));
	const snooze = (): void =>
		void client.configure(props.thread, { snoozed_until: limited.reset_at_ms }).catch((error: unknown) => failed("The thread could not be snoozed", error));
	return (
		<div className="card flex w-full flex-col gap-3 p-4">
			<div className="flex items-start gap-3">
				<IconTile className="bg-warning-surface text-warning-foreground">
					<Gauge />
				</IconTile>
				<div className="min-w-0 flex-1">
					<p className="text-sm font-medium">{`${provider}'s ${window === undefined ? "" : `${window} `}limit is used up`}</p>
					<p className="text-xs text-muted-foreground">
						{props.resumingAt === undefined ? `Given again at ${at}.` : `Given again at ${at}; the thread goes on then.`}
					</p>
				</div>
			</div>
			<div className="flex flex-wrap items-center gap-2">
				{onward.map((each) => (
					<Button key={each.provider.id} size="sm" variant="outline" onClick={() => goOnWith(each.reference)}>
						Go on with {each.provider.account?.name ?? each.provider.name}
					</Button>
				))}
				{props.resumingAt === undefined ? (
					<Button size="sm" variant="outline" onClick={() => resume(limited.reset_at_ms)}>
						Go on at {at}
					</Button>
				) : (
					<Button size="sm" variant="ghost-muted" onClick={() => resume(undefined)}>
						Don't go on then
					</Button>
				)}
				<Button size="sm" variant="ghost-muted" onClick={snooze}>
					Snooze till then
				</Button>
			</div>
		</div>
	);
}
