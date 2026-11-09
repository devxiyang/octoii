/**
 * Usage: how much of each plan's limits its accounts used, pooled by the node's providers — a card for each window, a
 * line for each account with its meter, how much it used and when it is given again, the soonest first — asked of the
 * node as the page opens, again as a connection opens, and on asking.
 */
import { type ReactNode, useState } from "react";
import { RefreshCw } from "lucide-react";
import { wakeLabel } from "../../core/time.ts";
import { type UsageLine, type UsageWindow, usageOf } from "../../core/usage.ts";
import { useNow } from "../effects/now.ts";
import { useRead } from "../effects/read.ts";
import { useStatuses } from "../effects/statuses.ts";
import { Button } from "../ui/button.tsx";
import { Meter } from "../ui/meter.tsx";
import { Page, SectionHeading } from "./layout.tsx";

/** The page. */
export function UsagePage(): ReactNode {
	const [asked, setAsked] = useState(0);
	const providers = useRead("providers.list", {})?.providers;
	const statuses = useStatuses(providers, asked);
	const now = useNow(60_000);
	const groups = providers === undefined || statuses === undefined ? undefined : usageOf(providers, statuses);
	return (
		<Page>
			<SectionHeading
				title="Usage"
				action={
					<Button size="xs" variant="ghost-muted" disabled={statuses === undefined} onClick={() => setAsked((count) => count + 1)} className="group/again">
						<RefreshCw className="group-disabled/again:animate-spin" />
						Ask again
					</Button>
				}
			/>
			{groups === undefined ? <p className="px-1 text-xs text-muted-foreground">Asking the providers…</p> : null}
			{groups?.length === 0 ? (
				<p className="px-1 text-xs text-balance text-muted-foreground">
					No provider tells how much of its plan is used. Claude does, once Claude Code is signed in.
				</p>
			) : null}
			{groups?.map((group) => (
				<section key={group.provider} className="flex flex-col gap-2">
					<SectionHeading title={group.provider} />
					{group.windows.map((window) => (
						<WindowCard key={window.key} window={window} now={now} />
					))}
				</section>
			))}
		</Page>
	);
}

/** A window's card: its title, and each account's line under it. */
function WindowCard(props: { readonly window: UsageWindow; readonly now: number }): ReactNode {
	return (
		<div className="flex flex-col gap-2.5 rounded-xl border border-border/60 bg-card/40 px-3.5 py-3 shadow-xs">
			<p className="text-ui font-medium">{props.window.title}</p>
			{props.window.lines.map((line) => (
				<div key={line.account} className="flex flex-col gap-1">
					<div className="flex items-baseline justify-between gap-3 text-xs">
						<span className="min-w-0 truncate">{line.account}</span>
						<span className="shrink-0 text-muted-foreground tabular-nums">{wordsOf(line, props.now)}</span>
					</div>
					<Meter
						value={line.usedPercent ?? 0}
						max={100}
						label={`${line.account}: ${props.window.title}`}
						valueText={wordsOf(line, props.now)}
						tone={toneOf(line.usedPercent)}
					/>
				</div>
			))}
		</div>
	);
}

/** How much of a window an account used, and when it is given again, in words. */
function wordsOf(line: UsageLine, now: number): string {
	const used = line.usedPercent === undefined ? "Used: not told" : `${String(Math.round(line.usedPercent))}% used`;
	return line.resetsAt === undefined ? used : `${used} · resets ${wakeLabel(line.resetsAt, now)}`;
}

/** A meter's tone: the error's once all is used, the warning's near it. */
function toneOf(used: number | undefined): "default" | "warning" | "error" {
	if (used === undefined || used < 80) return "default";
	return used >= 100 ? "error" : "warning";
}
