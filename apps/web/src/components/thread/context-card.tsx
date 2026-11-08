/**
 * What fills a thread's window, opened from its details' Context row: the tokens it holds of the most its model takes,
 * a bar of each part's share, then each by its words and its tokens — estimated, as no tokenizer is run — and what
 * compacts the window now: in the background while a turn runs on, once at a time, the button telling it compacts
 * till it is done. Read again as the compaction ends.
 */
import type { ReactNode } from "react";
import { useClient } from "@octoii-works/octoii-client/react";
import { PARTS, type PartShare, sharesOf } from "../../core/context.ts";
import { tokens } from "../../core/numbers.ts";
import { useOutcome } from "../effects/read.ts";
import { failed } from "../state/notices.ts";
import { Button } from "../ui/button.tsx";
import { cn } from "../ui/cn.ts";
import { hueClassOf } from "../ui/monogram.tsx";

/** What the card is given: the thread, the most its model takes, and whether it compacts now. */
export type ContextCardProps = { readonly thread: string; readonly window: number; readonly compacting: boolean };

/** The card. */
export function ContextCard(props: ContextCardProps): ReactNode {
	const client = useClient();
	const outcome = useOutcome("threads.context", { thread: props.thread }, props.compacting ? "compacting" : "still");
	const compact = (): void => {
		client.call("threads.compact", { thread: props.thread }).catch((error: unknown) => failed("The thread could not be compacted", error));
	};
	const composition = outcome !== undefined && "result" in outcome ? outcome.result : undefined;
	const shares = composition === undefined ? [] : sharesOf(composition, props.window);
	return (
		<div className="flex flex-col gap-3 p-3">
			<div className="flex items-baseline justify-between gap-3 px-0.5">
				<p className="text-sm font-medium">Context window</p>
				{composition === undefined ? null : (
					<span className="text-xs text-muted-foreground tabular-nums">
						≈ {tokens(composition.tokens)} of {tokens(props.window)}
					</span>
				)}
			</div>
			{outcome !== undefined && "failure" in outcome ? <p className="px-0.5 text-xs text-muted-foreground">{outcome.failure}</p> : null}
			<div aria-hidden className="flex h-2 overflow-hidden rounded-full bg-muted">
				{shares.map((share) => (
					<span key={share.part} style={{ width: `${String(share.fraction * 100)}%` }} className={cn("h-full bg-current", hueOf(share))} />
				))}
			</div>
			<ul className="flex flex-col gap-0.5">
				{shares.map((share) => (
					<li key={share.part} className="flex items-center gap-2 px-0.5 text-ui">
						<span className={cn("size-2 shrink-0 rounded-full bg-current", hueOf(share))} />
						<span className="flex-1 truncate">{PARTS[share.part].label}</span>
						<span className="text-xs text-muted-foreground tabular-nums">{tokens(share.tokens)}</span>
					</li>
				))}
			</ul>
			<div className="flex items-center gap-3 border-t border-border/60 pt-2.5">
				<p className="flex-1 text-xs text-muted-foreground">Shares are estimated. Compacting recaps the older work; a turn runs on meanwhile.</p>
				<Button size="xs" variant="outline" disabled={props.compacting} onClick={compact}>
					{props.compacting ? "Compacting…" : "Compact now"}
				</Button>
			</div>
		</div>
	);
}

/** The colour a share is drawn in: its part's hue, else the muted ink. */
function hueOf(share: PartShare): string {
	const hue = PARTS[share.part].hue;
	return hue === undefined ? "text-muted-foreground/60" : hueClassOf(hue);
}
