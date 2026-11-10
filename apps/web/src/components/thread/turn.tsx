/**
 * A turn of the thread: the words that began it, or that steered it on — the person's, a task its parent gave it, or
 * what came of one it gave a sub-thread in the background; its work, laid out alike while it works and once it ended —
 * what it said on its way, each stretch of calls a line that opens to its steps, what it thought — so nothing of it moves
 * as it ends; then its reply, a block at a time, the files it changed, what waits on the person, why it failed where it
 * did, and, as its last line, what it does now and how long it has worked while it works, or its foot once it ended. A
 * turn the same as it was is not drawn again, as only the turn that runs changes. A turn that works only grows as it
 * goes: its steps are added at the end, each fading in as it comes, and what it does now changes its words in one line
 * of its own, so nothing of it moves back as it calls its tools.
 */
import { memo, type ReactNode } from "react";
import { CircleAlert, Globe } from "lucide-react";
import { pastLabel, runningTime } from "../../core/time.ts";
import { doingOf, type Laid, laidOut, replyOf, type Said, type TimelineTurn, waitsOnPerson, type Work, workedText } from "../../core/timeline.ts";
import { useArrived } from "../effects/arrived.ts";
import { Counting, useNow } from "../effects/now.ts";
import { cn } from "../ui/cn.ts";
import { CopyButton } from "../ui/copy-button.tsx";
import { AskLine } from "./ask-line.tsx";
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
 * work and reply as it works or as it ended — the message nearer its reply than one turn is to the next. A part the
 * person steered on has no foot: the turn goes on under it.
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
				<TurnWork thread={props.thread} turn={turn} />
				<Reply text={replyOf(turn)} className={WORDS} />
				{working ? null : <TurnChanges changes={turn.changes} />}
				{turn.asks.map((ask) => (
					<AskLine key={ask.request.key} ask={ask} />
				))}
				{turn.ending.state === "failed" ? <FailureLine text={turn.ending.why} /> : null}
				{working ? <Doing turn={turn} /> : turn.ending.state === "steered" ? null : <TurnFoot turn={turn} />}
			</div>
		</div>
	);
});

/**
 * The foot of a turn that ended, its last line: a button that copies its reply as it was written, where it wrote one;
 * how long it worked, or that the person stopped it; and when it ended.
 */
function TurnFoot(props: { readonly turn: TimelineTurn }): ReactNode {
	const { turn } = props;
	const reply = replyOf(turn);
	const worked = workedText(turn);
	return (
		<div className={cn("flex min-h-control-sm items-center gap-1 text-xs text-faint-foreground tabular-nums", reply !== "" && "-ms-1.5")}>
			{reply === "" ? null : <CopyButton text={reply} label="Copy reply" />}
			{worked === undefined ? null : <span>{worked}</span>}
			{worked === undefined || turn.endedAt === undefined ? null : <span aria-hidden>·</span>}
			{turn.endedAt === undefined ? null : <Ended at={turn.endedAt} />}
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

/** A turn's work, laid out alike while it works and once it ended: each step that came after it was first drawn fading in. */
function TurnWork(props: { readonly thread: string; readonly turn: TimelineTurn }): ReactNode {
	const laid = laidOut(props.turn.work);
	const arrived = useArrived(laid.map(keyOf));
	return (
		<div className="work-list empty:hidden">
			<LaidSteps thread={props.thread} laid={laid} arrived={arrived} />
		</div>
	);
}

/** The key of what is laid out: a stretch's, delegations', or its step's. */
function keyOf(laid: Laid): string {
	if (laid.kind !== "step") return laid.key;
	return laid.step.kind === "call" ? laid.step.id : laid.step.key;
}

/**
 * Work of the thread `thread` as `laid` lays it out, in order: a stretch of calls as one line, delegations as
 * sub-threads, each other step on its own; each that `arrived` names fading in.
 */
function LaidSteps(props: { readonly thread: string; readonly laid: readonly Laid[]; readonly arrived: (key: string) => boolean }): ReactNode {
	return props.laid.map((laid) => {
		const key = keyOf(laid);
		return (
			<div key={key} className={cn("flex flex-col gap-0.5", props.arrived(key) && "animate-fade-in motion-reduce:animate-none")}>
				<LaidStep thread={props.thread} laid={laid} />
			</div>
		);
	});
}

/** One item of the laid-out work: a stretch of calls, delegations, or a step on its own. */
function LaidStep(props: { readonly thread: string; readonly laid: Laid }): ReactNode {
	const { laid } = props;
	switch (laid.kind) {
		case "calls":
			return <Calls thread={props.thread} steps={laid.steps} calls={laid.calls} />;
		case "delegations":
			return <Delegations thread={props.thread} calls={laid.calls} />;
		case "step":
			return <WorkStep thread={props.thread} step={laid.step} />;
	}
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
 * What a turn that works does now — waits on the person; thinks, while the request it waits on has written nothing;
 * forms a call, by its tool's verb; or works — and how long it has worked, counted on each second: one line in one
 * place, its words changing as the turn goes, so the turn neither grows nor shrinks as its model thinks and calls.
 */
function Doing(props: { readonly turn: TimelineTurn }): ReactNode {
	const { turn } = props;
	return (
		<p className="meta-line">
			<span className={waitsOnPerson(turn) ? "text-warning-foreground" : "shimmer"}>{doingOf(turn)}</span>
			{turn.startedAt === undefined ? null : (
				<span className="text-faint-foreground">
					· <Counting since={turn.startedAt} written={runningTime} />
				</span>
			)}
		</p>
	);
}
