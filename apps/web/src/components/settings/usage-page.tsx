/**
 * Usage: how much of each plan's limits its accounts have left, pooled by the node's providers — a card for each window,
 * how much its accounts have left together large on it, how they spend it against its time beside, and what its next
 * reset gives back; then a bar with a segment for each account, in its monogram's hue: what it has left filled, what it
 * used hatched where it is given back, a tick where it would stand were it used evenly, and how long till it is given
 * again — its details on hovering it. Asked of the node as the page opens, again as a connection opens, and on asking.
 */
import { type CSSProperties, type ReactNode, useState } from "react";
import { Gauge, RefreshCw, TrendingDown, TrendingUp } from "lucide-react";
import { wakeLabel } from "../../core/time.ts";
import { countdown, type Pace, type UsageSegment, type UsageWindow, usageOf } from "../../core/usage.ts";
import { useNow } from "../effects/now.ts";
import { useRead } from "../effects/read.ts";
import { useStatuses } from "../effects/statuses.ts";
import { Button } from "../ui/button.tsx";
import { cn } from "../ui/cn.ts";
import { hueClassOf, Monogram } from "../ui/monogram.tsx";
import { Popover, PopoverPopup, PopoverTrigger } from "../ui/popover.tsx";
import { Tip } from "../ui/tooltip.tsx";
import { Page, SectionHeading } from "./layout.tsx";

/** The page. */
export function UsagePage(): ReactNode {
	const [asked, setAsked] = useState(0);
	const providers = useRead("providers.list", {})?.providers;
	const statuses = useStatuses(providers, asked);
	const now = useNow(60_000);
	const groups = providers === undefined || statuses === undefined ? undefined : usageOf(providers, statuses, now);
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
				<section key={group.provider} className="@container flex flex-col gap-2">
					<SectionHeading title={group.provider} icon={<Monogram name={group.provider} />} />
					{group.windows.map((window) => (
						<WindowCard key={window.key} window={window} now={now} />
					))}
				</section>
			))}
		</Page>
	);
}

/** A window's card: its title, how much its accounts have left together and their pace, and its bar. */
function WindowCard(props: { readonly window: UsageWindow; readonly now: number }): ReactNode {
	const { window, now } = props;
	return (
		<div className="card grid items-center gap-x-6 gap-y-3 p-4 @lg:grid-cols-[9.5rem_minmax(0,1fr)]">
			<div className="flex min-w-0 flex-col gap-1">
				<p className="truncate text-ui font-medium">{window.title}</p>
				<p className="flex items-baseline gap-2">
					<span className="text-title font-semibold tabular-nums">{percentWords(window.leftPercent)}</span>
					<span className="inline-flex items-center gap-1.5 text-ui text-muted-foreground">
						left
						{window.pace === undefined ? null : <PaceMark pace={window.pace} />}
					</span>
				</p>
				{window.next === undefined ? null : (
					<p className="text-xs text-muted-foreground tabular-nums">
						<span className="font-medium text-foreground">↻ +{Math.round(window.next.percent)}%</span> in {countdown(window.next.at, now)}
					</p>
				)}
			</div>
			<div className="grid min-w-0 gap-1" style={{ gridTemplateColumns: `repeat(${String(window.columns.length)}, minmax(0, 1fr))` }}>
				{/* An account that tells no such window holds its place, so that each stands where it does on the other cards. */}
				{window.columns.map((column) =>
					column.segment === undefined ? (
						<span key={column.id} />
					) : (
						<Segment key={column.id} segment={column.segment} named={window.columns.length > 1} now={now} />
					),
				)}
			</div>
		</div>
	);
}

/** Each pace's words, and its mark. */
const PACES: Readonly<Record<Pace, { readonly words: string; readonly Mark: typeof Gauge }>> = {
	ahead: { words: "Ahead of pace: used faster than its time passes", Mark: TrendingUp },
	on: { words: "On pace with its time", Mark: Gauge },
	under: { words: "Under pace: room left for the rest of its time", Mark: TrendingDown },
};

/** How a window is spent against its time, as a mark, its words on hovering it. */
function PaceMark(props: { readonly pace: Pace }): ReactNode {
	const { words, Mark } = PACES[props.pace];
	return (
		<Tip label={words}>
			<span role="img" aria-label={words} className="inline-flex">
				<Mark className="size-3.5" aria-hidden />
			</span>
		</Tip>
	);
}

/**
 * An account's segment of a window's bar: what it has left filled from the start, what it used hatched where its reset
 * is known, and a tick where it would stand were it used evenly, in a gap cut from the bar; its name and how much it has
 * left where the bar has several, and how long till it is given again, each as its room allows; its details on hovering it.
 */
function Segment(props: { readonly segment: UsageSegment; readonly named: boolean; readonly now: number }): ReactNode {
	const { segment, now } = props;
	const left = segment.leftPercent ?? 0;
	const tick = segment.timeLeft === undefined ? undefined : `clamp(3px, ${String(segment.timeLeft * 100)}%, calc(100% - 3px))`;
	return (
		<Popover>
			<PopoverTrigger
				openOnHover
				delay={150}
				aria-label={wordsOf(segment, now)}
				className={cn(
					"relative h-8 min-w-0 rounded-md bg-muted outline-none focus-visible:ring-2 focus-visible:ring-ring data-popup-open:ring-1 data-popup-open:ring-border",
					hueClassOf(segment.hue),
				)}
				style={tick === undefined ? undefined : trackGappedAt(tick)}
			>
				<span aria-hidden className="absolute inset-0 overflow-hidden rounded-md" style={tick === undefined ? undefined : gapAt(tick)}>
					<span className="absolute inset-y-0 left-0 rounded-md bg-current opacity-35" style={{ width: `${String(left)}%` }} />
					{segment.resetsAt === undefined || left >= 100 ? null : (
						<span
							className="absolute inset-y-0 right-0 opacity-25 [background-image:repeating-linear-gradient(135deg,currentColor_0_1px,transparent_1px_5px)]"
							style={{ width: `${String(100 - left)}%` }}
						/>
					)}
				</span>
				{tick === undefined ? null : (
					<span aria-hidden className="absolute inset-y-0.5 w-0.5 -translate-x-1/2 rounded-full bg-foreground" style={{ left: tick }} />
				)}
				<span aria-hidden className="@container/segment absolute inset-0 flex items-center gap-1.5 px-2 text-xs text-foreground">
					{props.named ? (
						<>
							<span className="hidden min-w-0 truncate font-medium @min-[6rem]/segment:block">{segment.account}</span>
							<span className="hidden shrink-0 font-semibold tabular-nums @min-[6rem]/segment:block">{percentWords(segment.leftPercent)}</span>
						</>
					) : null}
					{segment.resetsAt === undefined ? null : (
						<span
							className={cn(
								"ms-auto hidden shrink-0 rounded-sm bg-background px-1.5 py-0.5 text-2xs tabular-nums",
								props.named ? "@min-[11rem]/segment:block" : "@min-[5rem]/segment:block",
							)}
						>
							↻ {countdown(segment.resetsAt, now)}
						</span>
					)}
				</span>
			</PopoverTrigger>
			<PopoverPopup side="top" align="center" className="w-64 p-3">
				<div className="flex items-baseline justify-between gap-3">
					<p className="min-w-0 truncate text-ui font-medium">{segment.account}</p>
					<p className="shrink-0 text-ui tabular-nums">
						<span className="font-semibold">{percentWords(segment.leftPercent)}</span> <span className="text-muted-foreground">left</span>
					</p>
				</div>
				<dl className="mt-2 grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1 text-xs">
					{segment.resetsAt === undefined ? null : (
						<>
							<dt className="text-muted-foreground">Given again</dt>
							<dd className="text-right tabular-nums">
								{wakeLabel(segment.resetsAt, now)} · in {countdown(segment.resetsAt, now)}
							</dd>
						</>
					)}
					{segment.timeLeft === undefined ? null : (
						<>
							<dt className="text-muted-foreground">Even pace</dt>
							<dd className="text-right tabular-nums">{Math.round(segment.timeLeft * 100)}% left by now</dd>
						</>
					)}
				</dl>
			</PopoverPopup>
		</Popover>
	);
}

/** A bar's track with a gap cut at `tick`, painted, so that its focus ring, drawn on it, is not cut as a clip would. */
function trackGappedAt(tick: string): CSSProperties {
	const [from, to] = [`calc(${tick} - 3px)`, `calc(${tick} + 3px)`];
	return {
		backgroundColor: "transparent",
		backgroundImage: `linear-gradient(to right, var(--color-muted) ${from}, transparent ${from}, transparent ${to}, var(--color-muted) ${to})`,
	};
}

/**
 * A gap cut at `tick` from what a bar holds, a slot of a clip — its polygon reaching a pixel past the box, so that only
 * the slot's edges clip and the bar's rounded ends keep their smoothing.
 */
function gapAt(tick: string): CSSProperties {
	const [from, to] = [`calc(${tick} - 3px)`, `calc(${tick} + 3px)`];
	const [near, far] = ["-1px", "calc(100% + 1px)"];
	return { clipPath: `polygon(${near} ${near}, ${from} ${near}, ${from} ${far}, ${to} ${far}, ${to} ${near}, ${far} ${near}, ${far} ${far}, ${near} ${far})` };
}

/** A share left in words: "19%", or a dash where it is not told. */
function percentWords(percent: number | undefined): string {
	return percent === undefined ? "–" : `${String(Math.round(percent))}%`;
}

/** An account's segment in words, as assistive technology tells it. */
function wordsOf(segment: UsageSegment, now: number): string {
	const left = `${segment.account}: ${segment.leftPercent === undefined ? "how much is left is not told" : `${percentWords(segment.leftPercent)} left`}`;
	const reset = segment.resetsAt === undefined ? "" : `, given again in ${countdown(segment.resetsAt, now)}`;
	const pace = segment.timeLeft === undefined ? "" : `, ${String(Math.round(segment.timeLeft * 100))}% of its time left`;
	return `${left}${reset}${pace}`;
}
