/**
 * A stretch of calls as one line of the work — one call's own, or several gathered — led by their marks, stacked, so a
 * call that joins the stretch is pushed into the marks it joins. One call's line says what it does and on what — its
 * subject as code where it is code — and beside it what came of it: the lines a read held, what an edit changed, what
 * the calls made under it did, their marks stacked after its own; at its end, how it went wrong or how it stands, and
 * how long it took or has run; opened, the calls made under it, then what it was given and what it told. Several say
 * what they did as a person says it, how many failed, and how long they took; opened, each on a line of its own, closer
 * together, what was thought between them among them. What a command prints shows only opened: folded, the line holds
 * one height as calls join it — each pushed into the marks — so the work grows by whole lines alone.
 */
import { memo, type ReactNode } from "react";
import { Ban, Brain } from "lucide-react";
import { callDuration, duration } from "../../core/time.ts";
import { type CallLine, declinedText, type Work } from "../../core/timeline.ts";
import { summaryOf } from "../../core/tools.ts";
import { useArrived } from "../effects/arrived.ts";
import { Counting } from "../effects/now.ts";
import { cn } from "../ui/cn.ts";
import { Collapsible, CollapsiblePanel, CollapsibleTrigger, FoldChevron } from "../ui/collapsible.tsx";
import { Waiting } from "./ask-line.tsx";
import { CallDetail } from "./call-detail.tsx";
import { ChangeCount } from "./changes.tsx";
import { Prose } from "./markdown.tsx";
import { CallMark, Mark, MarkStack } from "./marks.tsx";

/** What a stretch's line is given: the thread whose work it is, its steps — its calls and what was thought between them — and its calls. */
type StretchProps = { readonly thread: string; readonly steps: readonly Work[]; readonly calls: readonly CallLine[] };

/** Whether two stretches hold the same steps and calls, each the same object, at the same place: a line kept the same is not drawn again. */
function sameStretch(a: StretchProps, b: StretchProps): boolean {
	return a.thread === b.thread && sameItems(a.steps, b.steps) && sameItems(a.calls, b.calls);
}

/** Whether two lists hold the same items, in order. */
function sameItems<Item>(a: readonly Item[], b: readonly Item[]): boolean {
	return a.length === b.length && a.every((item, index) => item === b[index]);
}

/** The line of a stretch of calls: one call's own, or several gathered. */
export const Calls = memo(function Calls(props: StretchProps): ReactNode {
	const [only] = props.calls;
	const one = props.calls.length === 1 ? only : undefined;
	const marked = one === undefined ? props.calls : [one, ...one.calls];
	return <StretchLine thread={props.thread} steps={props.steps} calls={props.calls} one={one} marked={marked} />;
}, sameStretch);

/** The line of a stretch: its marks, its words, how it ends and its time; opened, what it holds. */
function StretchLine(props: StretchProps & { readonly one: CallLine | undefined; readonly marked: readonly CallLine[] }): ReactNode {
	const { one, marked } = props;
	return (
		<Collapsible>
			<CollapsibleTrigger data-state={one?.state ?? stateOf(props.calls)} className="group/call work-line work-opens">
				<MarkStack marks={marked.map((call) => ({ key: call.id, mark: <CallMark call={call} /> }))} />
				{one === undefined ? <GatheredWords calls={props.calls} /> : <CallWords call={one} />}
				<FoldChevron className="quiet-chevron" />
				<span className="flex-1" />
				{one === undefined ? <Failed calls={props.calls} /> : <CallEnd call={one} />}
				<span className="shrink-0 text-xs text-muted-foreground tabular-nums">
					<StretchTime calls={props.calls} />
				</span>
			</CollapsibleTrigger>
			<CollapsiblePanel>
				{one === undefined ? (
					<Steps thread={props.thread} steps={props.steps} />
				) : (
					<div className="work-indent">
						{one.calls.length === 0 ? null : (
							<div className="work-list work-tight">
								{one.calls.map((call) => (
									<Calls key={call.id} thread={props.thread} steps={[call]} calls={[call]} />
								))}
							</div>
						)}
						<CallDetail call={one} />
					</div>
				)}
			</CollapsiblePanel>
		</Collapsible>
	);
}

/** The steps a stretch gathered, opened, each on a line of its own: one that joins the stretch as it is open fading in. */
function Steps(props: { readonly thread: string; readonly steps: readonly Work[] }): ReactNode {
	const arrived = useArrived(props.steps.map(stepKey));
	return (
		<div className="work-list work-tight work-indent">
			{props.steps.map((step) => (
				<div key={stepKey(step)} className={cn(arrived(stepKey(step)) && "animate-fade-in motion-reduce:animate-none")}>
					<Step thread={props.thread} step={step} />
				</div>
			))}
		</div>
	);
}

function stepKey(step: Work): string {
	return step.kind === "call" ? step.id : step.key;
}

/** A step among those a stretch gathered: a call's line, or what was thought. */
function Step(props: { readonly thread: string; readonly step: Work }): ReactNode {
	const { step } = props;
	if (step.kind === "call") return <Calls thread={props.thread} steps={[step]} calls={[step]} />;
	return step.kind === "thought" ? <Thought text={step.text} took={step.took} /> : null;
}

/** How a stretch of several stands, as its line marks it: running while one runs or waits on the person, else done. */
function stateOf(calls: readonly CallLine[]): string {
	return calls.some((call) => call.state === "running" || call.state === "waiting") ? "running" : "done";
}

/** What a call does, as its line says it: its verb — shimmering while it runs — and what it works on, its tool's name where it has no verb; then what it says beside them. */
function CallWords(props: { readonly call: CallLine }): ReactNode {
	const { call } = props;
	return (
		<>
			{call.verb === undefined ? (
				<span className="shrink-0 font-mono text-xs text-foreground group-data-[state=running]/call:shimmer">{call.tool}</span>
			) : (
				<span className="shrink-0 group-data-[state=running]/call:shimmer">{call.verb}</span>
			)}
			{call.subject === undefined ? null : <span className={cn("min-w-0 truncate text-foreground", call.code && "font-mono text-xs")}>{call.subject}</span>}
			{call.aside === undefined ? null : call.aside.kind === "change" ? (
				<ChangeCount added={call.aside.added} removed={call.aside.removed} />
			) : (
				<span className="min-w-0 shrink-0 truncate text-muted-foreground">{call.aside.text}</span>
			)}
		</>
	);
}

/** What several calls did, as a person says it, its first letter a capital — shimmering while one runs. */
function GatheredWords(props: { readonly calls: readonly CallLine[] }): ReactNode {
	return <span className="min-w-0 truncate first-letter:uppercase group-data-[state=running]/call:shimmer">{summaryOf(props.calls)}</span>;
}

/** How many of several calls failed; nothing where none did. */
function Failed(props: { readonly calls: readonly CallLine[] }): ReactNode {
	const failed = props.calls.filter((call) => call.state === "failed" || call.trouble !== undefined).length;
	return failed === 0 ? null : <span className="shrink-0 text-xs text-error-foreground">{failed} failed</span>;
}

/** What a call's line says at its end of how it stands: failed, how it went wrong though it ran, waiting for the person, declined, or stopped; nothing while it runs or once it went well. */
function CallEnd(props: { readonly call: CallLine }): ReactNode {
	const { call } = props;
	switch (call.state) {
		case "failed":
			return <span className="shrink-0 text-xs text-error-foreground">Failed</span>;
		case "waiting":
			return <Waiting />;
		case "rejected":
			return (
				<span className="flex shrink-0 items-center gap-1 text-xs text-muted-foreground">
					<Ban className="size-3.5" />
					{declinedText(call)}
				</span>
			);
		case "stopped":
			return <span className="shrink-0 text-xs text-muted-foreground">Stopped</span>;
		case "done":
			return call.trouble === undefined ? null : <span className="shrink-0 font-mono text-xs text-error-foreground">{call.trouble}</span>;
		case "running":
			return null;
	}
}

/** How long a stretch's calls took, from the first's start to the last's end, or have run while one runs; nothing where none began. */
function StretchTime(props: { readonly calls: readonly CallLine[] }): ReactNode {
	const began = Math.min(...props.calls.flatMap((call) => (call.began === undefined ? [] : [call.began])));
	if (!Number.isFinite(began)) return null;
	if (props.calls.some((call) => call.state === "running")) return <Counting since={began} written={callDuration} />;
	const ended = Math.max(...props.calls.flatMap((call) => (call.ended === undefined ? [] : [call.ended])));
	return Number.isFinite(ended) ? callDuration(ended - began) : null;
}

/** What the model thought on its way, as its reply gave it: folded under how long its request took; open, its words. */
export const Thought = memo(function Thought(props: { readonly text: string; readonly took: number | undefined }): ReactNode {
	return (
		<Collapsible>
			<CollapsibleTrigger className="work-line work-opens">
				<Mark>
					<Brain />
				</Mark>
				{props.took === undefined || props.took <= 0 ? "Thought" : `Thought for ${duration(props.took)}`}
				<FoldChevron className="quiet-chevron" />
			</CollapsibleTrigger>
			<CollapsiblePanel>
				<Prose text={props.text} className="work-indent pt-0.5 pb-2 text-ui text-muted-foreground" />
			</CollapsiblePanel>
		</Collapsible>
	);
});
