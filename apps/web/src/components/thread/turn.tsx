/**
 * A turn of the thread: the words that began it, or that steered it on — the person's, a task its parent gave it, or
 * what came of one it gave a sub-thread in the background; its work — as it comes while it works, folded under how long
 * it worked once it ended, but for the sub-threads it delegated to that still work; then its reply, a block at a time,
 * the files it changed, what waits on the person, why it failed where it did, and how long it has worked while it
 * works. The reply stands in one place as the turn works and once it ended, so the blocks drawn while it was written
 * are kept as it ends; and a turn the same as it was is not drawn again, as only the turn that runs changes.
 */
import { memo, type ReactNode } from "react";
import { Brain, CircleAlert, Globe } from "lucide-react";
import { useThreads } from "@octoii-works/octoii-client/react";
import { standingOf } from "../../core/sub-threads.ts";
import { subThreadOf } from "../../core/threads.ts";
import { callDuration, duration, runningTime } from "../../core/time.ts";
import { callsIn, type Laid, laidOut, replyOf, type Said, type TimelineTurn, type Work } from "../../core/timeline.ts";
import { toolOf, verbOf } from "../../core/tools.ts";
import { Counting } from "../effects/now.ts";
import { cn } from "../ui/cn.ts";
import { Collapsible, CollapsiblePanel, CollapsibleTrigger, FoldChevron } from "../ui/collapsible.tsx";
import { AskInline } from "../composer/asks.tsx";
import { Calls, Thought } from "./calls.tsx";
import { TurnChanges } from "./changes.tsx";
import { Prose } from "./markdown.tsx";
import { CallMark, Mark } from "./marks.tsx";
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
				{working ? <WorkingFor since={turn.startedAt} /> : null}
			</div>
		</div>
	);
});

/** Words a turn took: what came of a task given to a sub-thread, as its row; the person's, or a task from `parent`, as theirs. */
function Words(props: { readonly said: Said; readonly parent: string | undefined }): ReactNode {
	const { said } = props;
	if (said.from !== undefined && said.from !== props.parent) return <SubThreadTold said={said} />;
	return <UserMessage said={said} />;
}

/**
 * The work of a turn that works, as it comes: its steps laid out; that its model thinks, while the request it waits on
 * has written nothing yet; and the calls being formed.
 */
function LiveWork(props: { readonly thread: string; readonly turn: TimelineTurn }): ReactNode {
	const { turn } = props;
	const thinking = turn.asking !== undefined && turn.writing.words === "" && turn.writing.calls.length === 0;
	return (
		<div className="work-list empty:hidden">
			<LaidSteps thread={props.thread} laid={laidOut(turn.work)} />
			{thinking && turn.asking !== undefined ? <Thinking since={turn.asking} /> : null}
			{turn.writing.calls.map((call) => (
				<FormingCall key={call.id} tool={call.tool} />
			))}
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
	const told = calls === 0 ? null : <span className="text-muted-foreground/70">· {calls === 1 ? "1 call" : `${String(calls)} calls`}</span>;
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
			<CollapsibleTrigger className="meta-line rounded-md outline-none hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring/70">
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

/** Work of the thread `thread` as `laid` lays it out, in order: a stretch of calls as one line, delegations as sub-threads, each other step on its own. */
function LaidSteps(props: { readonly thread: string; readonly laid: readonly Laid[] }): ReactNode {
	return props.laid.map((laid) => {
		switch (laid.kind) {
			case "calls":
				return <Calls key={laid.key} thread={props.thread} steps={laid.steps} calls={laid.calls} />;
			case "delegations":
				return <Delegations key={laid.key} thread={props.thread} calls={laid.calls} />;
			case "step":
				return <WorkStep key={laid.step.kind === "call" ? laid.step.id : laid.step.key} thread={props.thread} step={laid.step} />;
		}
	});
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
			<span className="h-px flex-1 bg-border/70" />
			What came before was summed up
			<span className="h-px flex-1 bg-border/70" />
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

/** That the model thinks, since the request it waits on was made: its line, counting on each second. */
function Thinking(props: { readonly since: number }): ReactNode {
	return (
		<p className="work-line tabular-nums">
			<Mark>
				<Brain />
			</Mark>
			<span className="shimmer">
				Thinking <Counting since={props.since} written={callDuration} />
			</span>
		</p>
	);
}

/** A call being formed, by its tool: its mark, and its verb as it goes — its tool's name where the page has none — shimmering. */
function FormingCall(props: { readonly tool: string }): ReactNode {
	const verb = verbOf({ tool: props.tool, state: "running" });
	return (
		<p className="work-line">
			<CallMark call={{ work: toolOf(props.tool).work, tool: props.tool, state: "running", trouble: undefined }} />
			<span className={cn("shimmer", verb === undefined && "font-mono text-xs")}>{verb ?? props.tool}</span>
		</p>
	);
}

/** How long a turn that works has worked, counted on each second — this line alone drawn again as it counts. */
function WorkingFor(props: { readonly since: number | undefined }): ReactNode {
	return (
		<p className="meta-line">
			<span className="shimmer">
				{props.since === undefined ? (
					"Working"
				) : (
					<>
						Working for <Counting since={props.since} written={runningTime} />
					</>
				)}
			</span>
		</p>
	);
}
