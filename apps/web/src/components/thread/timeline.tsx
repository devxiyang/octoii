/**
 * A thread's timeline: its rows in a column of the chat's width — its turns, and what is the thread's own between them,
 * its window summed up or what waits on the person — in the order their ids give, on a list that draws the rows in view
 * alone, each as tall as it measures — so a long thread, its images among it, costs what is seen — followed at its end
 * at once as it grows while the reader is there, what comes fading in, and let be once they scroll up, a button bringing
 * them back down; its place kept as earlier turns are read in above it. Nothing of the thread stands till its latest
 * entries are read; then its turns fade in, as the page first shows them, so a thread opens rather than appears; and
 * each row that comes after fades in as it does, once. Above the turns, where the client holds the latest of the
 * log alone, a button that reads further back. The list takes the room between the page's header and what docks at
 * its foot, and keeps to its end as that room shrinks under a reader who is there.
 */
import { type AnimationEvent, type ComponentProps, type ReactNode, useRef, useState } from "react";
import { ArrowDown, ShieldQuestion } from "lucide-react";
import { type ContextProp, Virtuoso, type VirtuosoHandle } from "react-virtuoso";
import type { TimelineRow } from "../../core/timeline.ts";
import { AskInline } from "../composer/asks.tsx";
import { LimitedCard } from "./limited.tsx";
import { useArrived } from "../effects/arrived.ts";
import { cn } from "../ui/cn.ts";
import { SummedUp, Turn } from "./turn.tsx";

/**
 * What the timeline shows: the thread, and its parent where it is a sub-thread; the rows held, whether they reach the
 * log's start, and how to read further back.
 */
export type TimelineProps = {
	readonly thread: string;
	readonly parent: string | undefined;
	readonly rows: readonly TimelineRow[];
	/** Whether the thread's latest entries were read: till they are, nothing of it stands. */
	readonly read: boolean;
	readonly complete: boolean;
	/** How many requests wait on the person, whose cards stand in the turns. */
	readonly waiting: number;
	readonly onEarlier: () => void;
};

/** What the list's head and its turns are given: whether the thread's latest entries were read, whether the turns reach the log's start and there are any, and how to read further back. */
type Ends = {
	readonly read: boolean;
	readonly complete: boolean;
	readonly empty: boolean;
	readonly onEarlier: () => void;
};

/** Where the first turn the list ever held stands: high enough that the turns read in before it keep numbers above nought. */
const FIRST_INDEX = 1_000_000;

export function Timeline(props: TimelineProps): ReactNode {
	const list = useRef<VirtuosoHandle>(null);
	const [atBottom, setAtBottom] = useState(true);
	const firstIndex = useFirstIndex(props.rows);
	// What came after the thread's latest entries were read fades in as it comes, once: a row the list draws again as it
	// is scrolled back to stands as it was.
	const arrived = useArrived(props.read ? props.rows.map((row) => row.key) : undefined);
	const faded = useRef(new Set<string>());
	const ends: Ends = { read: props.read, complete: props.complete, empty: props.rows.length === 0, onEarlier: props.onEarlier };
	return (
		<div className="relative flex min-h-0 flex-1 flex-col">
			<Virtuoso<TimelineRow, Ends>
				ref={list}
				className="min-h-0 flex-1 scrollbar-even"
				data={props.rows}
				context={ends}
				firstItemIndex={firstIndex}
				initialTopMostItemIndex={{ index: "LAST", align: "end" }}
				computeItemKey={(_, row) => row.key}
				// Kept to the end at once as the turns grow while the reader is there — what comes fades in, so a scroll that
				// glided would chase it, each growth starting another; let be once they scroll up.
				followOutput={(bottom) => (bottom ? "auto" : false)}
				atBottomStateChange={setAtBottom}
				atBottomThreshold={64}
				increaseViewportBy={{ top: 1200, bottom: 600 }}
				components={{ Header: Head, List: Turns }}
				itemContent={(_, row) => {
					const fades = arrived(row.key) && !faded.current.has(row.key);
					const done = (event: AnimationEvent): void => {
						if (event.target === event.currentTarget) faded.current.add(row.key);
					};
					return (
						<div className={cn("chat-column", fades && "animate-fade-in motion-reduce:animate-none")} onAnimationEnd={fades ? done : undefined}>
							<Row thread={props.thread} parent={props.parent} row={row} />
						</div>
					);
				}}
			/>
			{atBottom ? null : <Latest waiting={props.waiting} onLatest={() => list.current?.scrollToIndex({ index: "LAST", align: "end", behavior: "smooth" })} />}
		</div>
	);
}

/** A row: a turn, or the thread's own between turns — its window summed up, or what waits on the person, set apart as a turn is. */
function Row(props: { readonly thread: string; readonly parent: string | undefined; readonly row: TimelineRow }): ReactNode {
	const { row } = props;
	switch (row.kind) {
		case "turn":
			return <Turn thread={props.thread} parent={props.parent} turn={row.turn} />;
		case "summed-up":
			return (
				<div className="pb-8">
					<SummedUp />
				</div>
			);
		case "ask":
			return (
				<div className="pb-8">
					<AskInline thread={props.thread} ask={row.ask} />
				</div>
			);
		case "limited":
			return (
				<div className="pb-8">
					<LimitedCard thread={props.thread} limited={row.limited} resumingAt={row.resumingAt} />
				</div>
			);
	}
}

/**
 * The index the first of `turns` stands at in the list: lower by as many turns as were read in before the first it had,
 * so the list keeps its place; as it was where the first is let go of, as the client keeps the latest alone.
 */
function useFirstIndex(turns: readonly TimelineRow[]): number {
	const first = turns[0]?.key;
	const [held, setHeld] = useState({ first, index: FIRST_INDEX });
	if (first === held.first) return held.index;
	const before = turns.findIndex((turn) => turn.key === held.first);
	const next = { first, index: before > 0 ? held.index - before : held.index };
	// The index follows the turns as they change, as React keeps what a render learnt of the one before.
	setHeld(next);
	return next.index;
}

/** What the list gives the element its turns stand in: them, where they stand, and a way to reach it. */
type TurnsProps = Pick<ComponentProps<"div">, "children" | "style" | "ref"> & { readonly "data-testid"?: string } & ContextProp<Ends>;

/** The list's turns: hidden till the thread's latest entries are read, faded in as they are or as the page first shows them. */
function Turns({ context, ...props }: TurnsProps): ReactNode {
	return (
		<div
			{...props}
			className={cn("transition-opacity duration-300 ease-drawer starting:opacity-0 motion-reduce:transition-none", !context.read && "opacity-0")}
		/>
	);
}

/** The list's head: what reads further back, where the client holds the latest of the log alone; or that nothing was said yet; nothing till the thread's latest entries are read. */
function Head(props: ContextProp<Ends>): ReactNode {
	const { context } = props;
	if (!context.read) return null;
	if (context.complete && context.empty) {
		return <p className="py-20 text-center text-ui text-muted-foreground">Send a message to start the conversation.</p>;
	}
	return (
		<div className="flex justify-center pt-4 pb-4">
			{context.complete ? null : (
				<button type="button" onClick={context.onEarlier} className="rounded-md px-2 py-1 text-xs text-muted-foreground hover:bg-accent hover:text-foreground">
					Show earlier
				</button>
			)}
		</div>
	);
}

/** Where the way back down stands: over the list's foot, in its middle, coming in as the reader leaves the end. */
const LATEST =
	"absolute bottom-3 left-1/2 z-10 flex h-control -translate-x-1/2 items-center justify-center rounded-full border border-border bg-background shadow-floating transition-[opacity,scale] duration-150 starting:scale-90 starting:opacity-0 motion-reduce:transition-none";

/** The way back down to the list's end, where the reader left it — saying how many requests wait on the person there, where any do. */
function Latest(props: { readonly waiting: number; readonly onLatest: () => void }): ReactNode {
	if (props.waiting > 0) {
		return (
			<button type="button" onClick={props.onLatest} className={cn(LATEST, "gap-1.5 px-3 text-ui whitespace-nowrap text-warning-foreground")}>
				<ShieldQuestion className="size-4" />
				{props.waiting === 1 ? "Waiting for you" : `${String(props.waiting)} waiting for you`}
				<ArrowDown className="size-3.5" />
			</button>
		);
	}
	return (
		<button
			type="button"
			aria-label="Back to the latest"
			onClick={props.onLatest}
			className={cn(LATEST, "w-control text-muted-foreground hover:text-foreground")}
		>
			<ArrowDown className="size-4" />
		</button>
	);
}
