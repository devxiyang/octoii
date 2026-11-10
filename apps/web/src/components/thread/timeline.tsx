/**
 * A thread's timeline: its rows in a column of the chat's width — each turn laid out flat, its words, each part of its
 * work, its reply and its end, and what is the thread's own between turns — in the order their ids give, on a list
 * that draws the rows in view alone, each as tall as it measures, so a long thread, its images among it, costs what is
 * seen. It opens at its end and keeps to it as it grows while the reader is there — at once, as a glide would chase
 * each growth and the rows below what grows would be seen to move — and lets be once they scroll up, a button bringing
 * them back down; what the person last sent stands near the top, the reply growing under it, space kept below it till
 * the reply fills the room; a row above what is read that grows or shrinks moves nothing read, as earlier turns read in
 * above it do not.
 * Nothing of the thread stands till its latest entries are read; then its rows fade in, so a thread opens rather than
 * appears; and each row that comes after fades in as it does, once. Above the rows, where the client holds the latest
 * of the log alone, a button that reads further back. The list takes the room between the page's header and what
 * docks at its foot.
 */
import { type AnimationEvent, createContext, memo, type ReactNode, type Ref, use, useImperativeHandle, useMemo, useState } from "react";
import { ArrowDown, ShieldQuestion } from "lucide-react";
import { LegendList, type MaintainScrollAtEndOptions } from "@legendapp/list/react";
import { type Room, rowsOf, steadyRows, type TimelineRow } from "../../core/rows.ts";
import type { TimelineItem } from "../../core/timeline.ts";
import { AskLine } from "./ask-line.tsx";
import { LimitedCard } from "./limited.tsx";
import { Reply } from "./reply.tsx";
import { useArrived } from "../effects/arrived.ts";
import { useDebounced } from "../effects/debounced.ts";
import { useListEnd } from "../effects/list-end.ts";
import { REDUCED_MOTION, useMedia } from "../effects/media.ts";
import { cn } from "../ui/cn.ts";
import { SummedUp, TurnEndPart, Words, WORDS, WorkPart } from "./turn.tsx";

/**
 * What the timeline shows: the thread, and its parent where it is a sub-thread; its items, whether they reach the log's
 * start, and how to read further back; and the input the person last sent, kept near the top.
 */
export type TimelineProps = {
	readonly thread: string;
	readonly parent: string | undefined;
	readonly items: readonly TimelineItem[];
	/** Whether the thread's latest entries were read: till they are, nothing of it stands. */
	readonly read: boolean;
	readonly complete: boolean;
	/** How many requests wait on the person, whose lines stand in the turns. */
	readonly waiting: number;
	/** The input the person last sent, by the id it was delivered by: its words are kept near the top as the reply grows under them. */
	readonly sent: string | undefined;
	readonly onEarlier: () => void;
	readonly ref?: Ref<TimelineHandle>;
};

/** What the timeline's page does with it: brings the reader to its end, as the person sends. */
export type TimelineHandle = { readonly toEnd: () => void };

/** Where the person's words they last sent stand, from the top of the list's room, in pixels. */
const SENT_OFFSET = 16;

/** Kept to the end as the rows change, each grows or the room does — at once. */
const FOLLOW = { animated: false, on: { dataChange: true, itemLayout: true, layout: true } } as const satisfies MaintainScrollAtEndOptions;

/** What is read stays where it stands as rows above it grow or shrink and as rows are read in above them. */
const KEEP_READ = { data: true, size: true } as const;

/** What each row of the list is drawn with: the thread, its parent, and which rows fade in as they come — once. */
type Shown = {
	readonly thread: string;
	readonly parent: string | undefined;
	readonly arrived: (key: string) => boolean;
	readonly faded: Set<string>;
};

const ShownContext = createContext<Shown | undefined>(undefined);

export function Timeline({ ref, ...props }: TimelineProps): ReactNode {
	const { attach, atEnd, onScroll, toEnd } = useListEnd();
	const rows = useSteadyRows(props.items);
	// What came after the thread's latest entries were read fades in as it comes, once: a row the list draws again as it
	// is scrolled back to stands as it was.
	const arrived = useArrived(props.read ? rows.map((row) => row.key) : undefined);
	const [faded] = useState(() => new Set<string>());
	// The same while what it holds is, so a row is drawn again only as it changes.
	const shown = useMemo<Shown>(() => ({ thread: props.thread, parent: props.parent, arrived, faded }), [props.thread, props.parent, arrived, faded]);
	const lessMotion = useMedia(REDUCED_MOTION);
	// The way back down shows once the reader has been away from the end a while, so it does not flash as a thread opens
	// and settles; it goes as they come back.
	const awhile = useDebounced(!atEnd, AWAY_AFTER);
	const sent = props.sent === undefined ? -1 : rows.findIndex((row) => row.kind === "said" && row.said.delivery === props.sent);
	useImperativeHandle(ref, () => ({ toEnd: () => toEnd(false) }), [toEnd]);
	return (
		<div
			className={cn(
				"relative flex min-h-0 flex-1 flex-col transition-opacity duration-300 ease-drawer starting:opacity-0 motion-reduce:transition-none",
				!props.read && "opacity-0",
			)}
		>
			<ShownContext value={shown}>
				<LegendList<TimelineRow>
					ref={attach}
					className="min-h-0 flex-1 overscroll-y-contain scrollbar-even [overflow-anchor:none]"
					data={rows}
					keyExtractor={keyOf}
					getItemType={kindOf}
					renderItem={drawRow}
					estimatedItemSize={40}
					initialScrollAtEnd
					maintainScrollAtEnd={FOLLOW}
					maintainVisibleContentPosition={KEEP_READ}
					{...(sent < 0 ? {} : { anchoredEndSpace: { anchorIndex: sent, anchorOffset: SENT_OFFSET } })}
					onScroll={onScroll}
					ListHeaderComponent={<Head read={props.read} complete={props.complete} empty={rows.length === 0} onEarlier={props.onEarlier} />}
					ListFooterComponent={FOOT}
				/>
			</ShownContext>
			{!atEnd && awhile ? <Latest waiting={props.waiting} onLatest={() => toEnd(!lessMotion)} /> : null}
		</div>
	);
}

/** The rows of `items`, each that did not change since the items before the same object as it was. */
function useSteadyRows(items: readonly TimelineItem[]): readonly TimelineRow[] {
	const [held, setHeld] = useState(() => ({ items, ...steadyRows(rowsOf(items), new Map()) }));
	if (held.items === items) return held.rows;
	const next = { items, ...steadyRows(rowsOf(items), held.byKey) };
	// The rows follow the items as they change, as React keeps what a render learnt of the one before.
	setHeld(next);
	return next.rows;
}

/** How long the reader is away from the end before the way back down shows, in milliseconds. */
const AWAY_AFTER = 250;

function keyOf(row: TimelineRow): string {
	return row.key;
}

function kindOf(row: TimelineRow): string {
	return row.kind;
}

function drawRow(props: { readonly item: TimelineRow }): ReactNode {
	return <RowFrame row={props.item} />;
}

/** The room each kind of room leaves above its row. */
const ROOM: Readonly<Record<Room, string>> = { turn: "pt-8", message: "pt-4", part: "pt-2", line: "pt-0.5" };

/** A row in the chat's column, the room above it its own, fading in where it came after the thread was read — once. */
const RowFrame = memo(function RowFrame(props: { readonly row: TimelineRow }): ReactNode {
	const shown = use(ShownContext);
	if (shown === undefined) throw new Error("A timeline row is drawn outside its timeline");
	const { row } = props;
	const fades = shown.arrived(row.key) && !shown.faded.has(row.key);
	const done = (event: AnimationEvent): void => {
		if (event.target === event.currentTarget) shown.faded.add(row.key);
	};
	return (
		<div
			className={cn("chat-column contain-layout contain-style", ROOM[row.room], fades && "animate-fade-in motion-reduce:animate-none")}
			onAnimationEnd={fades ? done : undefined}
		>
			<Row thread={shown.thread} parent={shown.parent} row={row} />
		</div>
	);
});

/** A row: the person's words, a part of a turn's work, its reply or its end; or the thread's own between turns. */
function Row(props: { readonly thread: string; readonly parent: string | undefined; readonly row: TimelineRow }): ReactNode {
	const { row } = props;
	switch (row.kind) {
		case "said":
			return <Words said={row.said} parent={props.parent} />;
		case "work":
			return (
				<div className="flex flex-col gap-0.5">
					<WorkPart thread={props.thread} laid={row.laid} />
				</div>
			);
		case "reply":
			return <Reply text={row.text} className={WORDS} />;
		case "end":
			return <TurnEndPart end={row.end} />;
		case "summed-up":
			return <SummedUp />;
		case "ask":
			return <AskLine ask={row.ask} />;
		case "limited":
			return <LimitedCard thread={props.thread} limited={row.limited} resumingAt={row.resumingAt} />;
	}
}

/** The room under the last row, as a turn leaves above the next. */
const FOOT = <div aria-hidden className="h-8" />;

/** The list's head: what reads further back, where the client holds the latest of the log alone; or that nothing was said yet; nothing till the thread's latest entries are read. */
function Head(props: { readonly read: boolean; readonly complete: boolean; readonly empty: boolean; readonly onEarlier: () => void }): ReactNode {
	if (!props.read) return null;
	if (props.complete && props.empty) {
		return <p className="py-20 text-center text-ui text-muted-foreground">Send a message to start the conversation.</p>;
	}
	if (props.complete) return null;
	return (
		<div className="flex justify-center pt-4">
			<button type="button" onClick={props.onEarlier} className="rounded-md px-2 py-1 text-xs text-muted-foreground hover:bg-accent hover:text-foreground">
				Show earlier
			</button>
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
