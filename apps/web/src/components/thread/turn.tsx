/**
 * A turn of the thread: the words that began it, or that steered it on — the person's, a task its parent gave it, or
 * what came of one it gave a sub-thread in the background; its work — as it comes while it works, folded under how long
 * it worked once it ended, but for the sub-threads it delegated to that still work; then its reply, a block at a time,
 * the files it changed, what waits on the person, why it failed where it did, and, as its last line, what it does now
 * and how long it has worked while it works, or its reply's foot once it ended. The reply stands in one place as the
 * turn works and once it ended, so the blocks drawn while it was written are kept as it ends; and a turn the same as it
 * was is not drawn again, as only the turn that runs changes. A turn that works only grows as it goes: its steps are
 * added at the end, each fading in as it comes, and what it does now changes its words in one line of its own, so
 * nothing of it moves back as it calls its tools.
 */
import { memo, type ReactNode } from "react";
import { CircleAlert, Globe } from "lucide-react";
import { useThreads } from "@octoii-works/octoii-client/react";
import { standingOf } from "../../core/sub-threads.ts";
import { subThreadOf } from "../../core/threads.ts";
import { duration, pastLabel, runningTime } from "../../core/time.ts";
import { callsIn, type Laid, laidOut, replyOf, type Said, type TimelineTurn, type Work } from "../../core/timeline.ts";
import { verbOf } from "../../core/tools.ts";
import { useArrived } from "../effects/arrived.ts";
import { Counting, useNow } from "../effects/now.ts";
import { cn } from "../ui/cn.ts";
import { Collapsible, CollapsiblePanel, CollapsibleTrigger, FoldChevron } from "../ui/collapsible.tsx";
import { CopyButton } from "../ui/copy-button.tsx";
import { AskInline } from "../composer/asks.tsx";
import { Calls, Thought } from "./calls.tsx";
import { TurnChanges } from "./changes.tsx";
import { Prose } from "./markdown.tsx";
import { Mark } from "./marks.tsx";
import { Reply } from "./reply.tsx";
import { Delegations, SubThreadTold } from "./sub-thread.tsx";
import { UserMessage } from "./user-message.tsx";

/** The words of a reply, as the page sets them: larger and airier than the work's lines. */
const WORDS = "text-body";

/**
 * A turn of the thread `thread`, whose parent, where it is a sub-thread, is `parent`: the words that began it, then its
 * work and reply as it works or as it ended — the message nearer its reply than one turn is to the next.
 */
export const Turn = memo(function Turn(props: { readonly thread: string; readonly parent: string | undefined; readonly turn: TimelineTurn }): ReactNode {
	const { turn } = props;
	const working = turn.ending.state === "working";
	return (
		<div className="flex flex-col gap-4 pb-8 contain-layout contain-style">
			{turn.said.map((said) => (
				<Words key={said.key} said={said} parent={props.parent} />
			))}
			<div className="flex flex-col gap-2">
				{working ? <LiveWork thread={props.thread} turn={turn} /> : <EndedWork thread={props.thread} turn={turn} />}
				<Reply text={replyOf(turn)} className={WORDS} />
				{working ? null : <TurnChanges changes={turn.changes} />}
				{turn.asks.map((ask) => (
					<AskInline key={ask.request.key} thread={props.thread} ask={ask} />
				))}
				{turn.ending.state === "failed" ? <FailureLine text={turn.ending.why} /> : null}
				{working ? <Doing turn={turn} /> : <ReplyFoot text={replyOf(turn)} endedAt={turn.endedAt} />}
			</div>
		</div>
	);
});

/**
 * The foot of an ended turn's reply, the turn's last line: a button that copies the reply as it was written, and when
 * the turn ended. Nothing where the turn wrote no reply.
 */
function ReplyFoot(props: { readonly text: string; readonly endedAt: number | undefined }): ReactNode {
	if (props.text === "") return null;
	return (
		<div className="-ms-1.5 flex min-h-control-sm items-center gap-1 text-xs text-faint-foreground tabular-nums">
			<CopyButton text={props.text} label="Copy reply" />
			{props.endedAt === undefined ? null : <Ended at={props.endedAt} />}
		</div>
	);
}

/** When a turn ended, as the day it is read on says it — its hour that day, its date on another — the whole of it its tip. */
function Ended(props: { readonly at: number }): ReactNode {
	const now = useNow(60_000);
	const at = new Date(props.at);
	return (
		<time dateTime={at.toISOString()} title={at.toLocaleString()}>
			{pastLabel(props.at, now)}
		</time>
	);
}

/** Words a turn took: what came of a task given to a sub-thread, as its row; the person's, or a task from `parent`, as theirs. */
function Words(props: { readonly said: Said; readonly parent: string | undefined }): ReactNode {
	const { said } = props;
	if (said.from !== undefined && said.from !== props.parent) return <SubThreadTold said={said} />;
	return <UserMessage said={said} />;
}

/** The work of a turn that works, as it comes: its steps laid out, each that came after the work was first drawn fading in. */
function LiveWork(props: { readonly thread: string; readonly turn: TimelineTurn }): ReactNode {
	const laid = laidOut(props.turn.work);
	const arrived = useArrived(laid.map(keyOf));
	return (
		<div className="work-list empty:hidden">
			<LaidSteps thread={props.thread} laid={laid} arrived={arrived} />
		</div>
	);
}

/** The work of a turn that ended, folded — but for the delegations of a step whose sub-threads still work, which stay in view. */
function EndedWork(props: { readonly thread: string; readonly turn: TimelineTurn }): ReactNode {
	const laid = laidOut(props.turn.work);
	if (!laid.some((each) => each.kind === "delegations")) return <FoldedWork thread={props.thread} turn={props.turn} laid={laid} />;
	return <WithDelegations thread={props.thread} turn={props.turn} laid={laid} />;
}

/** An ended turn's work, as `laid` lays it out, with delegations among it: those whose sub-threads still work kept in view, under the fold of the rest. */
function WithDelegations(props: { readonly thread: string; readonly turn: TimelineTurn; readonly laid: readonly Laid[] }): ReactNode {
	const rows = useThreads() ?? [];
	const working = (laid: Laid): boolean =>
		laid.kind === "delegations" && laid.calls.some((call) => standingOf(subThreadOf(rows, props.thread, call), call) === "running");
	const kept = props.laid.filter(working);
	return (
		<>
			<FoldedWork thread={props.thread} turn={props.turn} laid={props.laid.filter((each) => !working(each))} />
			{kept.length === 0 ? null : (
				<div className="work-list">
					<LaidSteps thread={props.thread} laid={kept} />
				</div>
			)}
		</>
	);
}

/**
 * An ended turn's work, as `laid` lays it out, folded under how long the turn worked — or that the person stopped it —
 * and how many calls it made; open, its steps.
 */
function FoldedWork(props: { readonly thread: string; readonly turn: TimelineTurn; readonly laid: readonly Laid[] }): ReactNode {
	const { turn } = props;
	const took = turn.startedAt === undefined || turn.endedAt === undefined ? undefined : duration(turn.endedAt - turn.startedAt);
	const stopped = turn.ending.state === "stopped";
	const label = stopped
		? took === undefined
			? "You stopped this response"
			: `You stopped after ${took}`
		: took === undefined
			? "Worked"
			: `Worked for ${took}`;
	const calls = callsIn(turn.work);
	const told = calls === 0 ? null : <span className="text-faint-foreground">· {calls === 1 ? "1 call" : `${String(calls)} calls`}</span>;
	// With nothing left to fold — all it did stays in view — the line still tells how long it worked.
	if (props.laid.length === 0) {
		return stopped || calls > 0 ? (
			<p className="meta-line">
				{label}
				{told}
			</p>
		) : null;
	}
	return (
		<Collapsible>
			<CollapsibleTrigger className="meta-line rounded-md outline-none hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring">
				{label}
				{told}
				<FoldChevron className="quiet-chevron" />
			</CollapsibleTrigger>
			<CollapsiblePanel>
				<div className="work-list pt-1">
					<LaidSteps thread={props.thread} laid={props.laid} />
				</div>
			</CollapsiblePanel>
		</Collapsible>
	);
}

/** The key of what is laid out: a stretch's, delegations', or its step's. */
function keyOf(laid: Laid): string {
	if (laid.kind !== "step") return laid.key;
	return laid.step.kind === "call" ? laid.step.id : laid.step.key;
}

/**
 * Work of the thread `thread` as `laid` lays it out, in order: a stretch of calls as one line, delegations as
 * sub-threads, each other step on its own; where the work goes on, each that `arrived` names fading in.
 */
function LaidSteps(props: { readonly thread: string; readonly laid: readonly Laid[]; readonly arrived?: (key: string) => boolean }): ReactNode {
	const { arrived } = props;
	return props.laid.map((laid) => {
		const key = keyOf(laid);
		const shown = (() => {
			switch (laid.kind) {
				case "calls":
					return <Calls thread={props.thread} steps={laid.steps} calls={laid.calls} />;
				case "delegations":
					return <Delegations thread={props.thread} calls={laid.calls} />;
				case "step":
					return <WorkStep thread={props.thread} step={laid.step} />;
			}
		})();
		if (arrived === undefined) return <ArrivedStep key={key}>{shown}</ArrivedStep>;
		return (
			<ArrivedStep key={key} fades={arrived(key)}>
				{shown}
			</ArrivedStep>
		);
	});
}

/** A step of the work, fading in as it came after the work was first drawn. */
function ArrivedStep(props: { readonly fades?: boolean; readonly children: ReactNode }): ReactNode {
	return <div className={cn("flex flex-col gap-0.5", props.fades === true && "animate-fade-in motion-reduce:animate-none")}>{props.children}</div>;
}

/** One step of the work on its own: a call that waits on the person, what the model thought, a search of the web, its words on the way, a request that came to nothing, or the thread summed up. */
function WorkStep(props: { readonly thread: string; readonly step: Work }): ReactNode {
	const { step } = props;
	switch (step.kind) {
		case "call":
			return <Calls thread={props.thread} steps={[step]} calls={[step]} />;
		case "thought":
			return <Thought text={step.text} took={step.took} />;
		case "web-search":
			return (
				<p className="work-line">
					<Mark>
						<Globe />
					</Mark>
					<span className="truncate">{step.query === undefined ? "Searched the web" : `Searched the web for ${step.query}`}</span>
				</p>
			);
		case "words":
			// Words on the way stand among the lines, a paragraph's breath above and below them.
			return <Prose text={step.text} className={cn(WORDS, "py-1.5 text-foreground")} />;
		case "failure":
			return <FailureLine text={step.text} />;
		case "compaction":
			return <SummedUp />;
	}
}

/** That the thread's window was summed up there, as a rule across the column: within a turn's work, or between turns. */
export function SummedUp(): ReactNode {
	return (
		<div className="flex items-center gap-3 py-2 text-xs text-muted-foreground">
			<span className="h-px flex-1 bg-border" />
			What came before was summed up
			<span className="h-px flex-1 bg-border" />
		</div>
	);
}

/** Why something came to nothing, as a line of the work, red. */
function FailureLine(props: { readonly text: string }): ReactNode {
	return (
		<p className="work-line text-error-foreground">
			<Mark troubled>
				<CircleAlert />
			</Mark>
			<span className="min-w-0">{props.text}</span>
		</p>
	);
}

/**
 * What a turn that works does now — thinks, while the request it waits on has written nothing; forms a call, by its
 * tool's verb; or works — and how long it has worked, counted on each second: one line in one place, its words changing
 * as the turn goes, so the turn neither grows nor shrinks as its model thinks and calls.
 */
function Doing(props: { readonly turn: TimelineTurn }): ReactNode {
	const { turn } = props;
	return (
		<p className="meta-line">
			<span className="shimmer">{doingOf(turn)}</span>
			{turn.startedAt === undefined ? null : (
				<span className="text-faint-foreground">
					· <Counting since={turn.startedAt} written={runningTime} />
				</span>
			)}
		</p>
	);
}

/** What a turn that works does now, in words. */
function doingOf(turn: TimelineTurn): string {
	const [forming, ...more] = turn.writing.calls;
	if (forming !== undefined) {
		const verb = verbOf({ tool: forming.tool, state: "running" }) ?? `Calling ${forming.tool}`;
		return more.length === 0 ? verb : `${verb}, and ${String(more.length)} more`;
	}
	if (turn.asking !== undefined && turn.writing.words === "") return "Thinking";
	return "Working";
}
