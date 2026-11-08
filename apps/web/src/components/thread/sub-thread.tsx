/**
 * Sub-threads in the timeline of the thread that delegated to them, as lines of its work: a row for each — a bot's
 * round mark with a dot of how it stands, its title, what it said or how it stands, how long it worked, and a way into
 * it — for the calls that gave them tasks, those of one step gathered under their marks, stacked, how many there are,
 * how they stand and how long they worked, opened to list them; and a row for what came of a task given in the
 * background, as the sub-thread told it, marked how its work ended and when.
 */
import type { ReactNode } from "react";
import type { Listed } from "@octoii-works/octoii-client";
import { useThreads } from "@octoii-works/octoii-client/react";
import { Bot, ChevronRight } from "lucide-react";
import { plainLine, type Standing, standingOf, standingsSummary, type Worked, workedOf } from "../../core/sub-threads.ts";
import { subThreadOf } from "../../core/threads.ts";
import { duration } from "../../core/time.ts";
import type { CallLine, Said } from "../../core/timeline.ts";
import { callWords } from "../../core/tools.ts";
import { Counting } from "../effects/now.ts";
import { go } from "../state/navigation.ts";
import { cn } from "../ui/cn.ts";
import { Collapsible, CollapsiblePanel, CollapsibleTrigger, FoldChevron } from "../ui/collapsible.tsx";
import { Mark, MarkStack } from "./marks.tsx";

/** Each way a sub-thread stands: its dot's colour, and its words. */
const STANDINGS: Readonly<Record<Standing, { readonly dot: string; readonly label: string }>> = {
	running: { dot: "bg-info", label: "Running" },
	completed: { dot: "bg-success", label: "Completed" },
	failed: { dot: "bg-destructive", label: "Failed" },
	stopped: { dot: "bg-muted-foreground/60", label: "Stopped" },
};

/** How a task given in the background ended, as its sub-thread told it, by how the sub-thread stands since. */
const TOLD: Readonly<Record<Standing, string>> = { running: "Running", completed: "Finished", failed: "Failed", stopped: "Stopped" };

/** The delegations of one step, made by the thread `thread`: one a row, several gathered. */
export function Delegations(props: { readonly thread: string; readonly calls: readonly CallLine[] }): ReactNode {
	const rows = useThreads() ?? [];
	const delegated = props.calls.map((call) => ({ call, row: subThreadOf(rows, props.thread, call) }));
	const [only] = delegated;
	if (only !== undefined && delegated.length === 1) return <DelegationRow call={only.call} row={only.row} />;
	return <Gathered delegated={delegated} />;
}

/** Several delegations of a step, under how many they are and how they stand — clear while one works — opened to list each one's row. */
function Gathered(props: { readonly delegated: readonly { readonly call: CallLine; readonly row: Listed | undefined }[] }): ReactNode {
	const standings = props.delegated.map(({ call, row }) => standingOf(row, call));
	const tone = standings.includes("running") ? "running" : standings.includes("failed") ? "failed" : undefined;
	const worked = workedOf(props.delegated.map(({ row }) => row));
	return (
		<Collapsible>
			<CollapsibleTrigger data-tone={tone} className="work-line work-opens">
				<MarkStack marks={props.delegated.map(({ call }, index) => ({ key: call.id, mark: <SubThreadMark standing={standings[index] ?? "running"} /> }))} />
				<span className="shrink-0 text-foreground">{`${String(standings.length)} sub-threads`}</span>
				<span className="min-w-0 truncate group-data-[tone=failed]/fold:text-error-foreground group-data-[tone=running]/fold:text-info-foreground">
					{standingsSummary(standings)}
				</span>
				<FoldChevron className="quiet-chevron" />
				<span className="flex-1" />
				{worked === undefined ? null : (
					<span className="shrink-0 text-xs text-muted-foreground/80 tabular-nums">
						<WorkedFor worked={worked} />
					</span>
				)}
			</CollapsibleTrigger>
			<CollapsiblePanel>
				<div className="work-list work-tight work-indent">
					{props.delegated.map(({ call, row }) => (
						<DelegationRow key={call.id} call={call} row={row} />
					))}
				</div>
			</CollapsiblePanel>
		</Collapsible>
	);
}

/** A delegation's row: its sub-thread as it stands, or, where it is not listed, the call as it stands. */
function DelegationRow(props: { readonly call: CallLine; readonly row: Listed | undefined }): ReactNode {
	const { call, row } = props;
	const standing = standingOf(row, call);
	const worked = workedOf([row]);
	return (
		<SubThreadRow
			title={row?.manifest.title ?? call.subject ?? callWords(call)}
			standing={standing}
			detail={undefined}
			label={STANDINGS[standing].label}
			time={worked === undefined ? undefined : <WorkedFor worked={worked} />}
			thread={row?.id}
		/>
	);
}

/** What came of a task given in the background, as the sub-thread `said` it: marked as it ended, and when. */
export function SubThreadTold(props: { readonly said: Said }): ReactNode {
	const { said } = props;
	const row = useThreads()?.find((each) => each.id === said.from);
	const standing = standingOf(row);
	const detail = plainLine(said.text);
	const when = new Date(said.at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
	return (
		<div>
			<SubThreadRow
				title={row?.manifest.title ?? "Sub-thread"}
				standing={standing}
				detail={detail === "" ? undefined : detail}
				label={row === undefined ? "Deleted" : TOLD[standing]}
				time={when}
				thread={row?.id}
			/>
		</div>
	);
}

/**
 * A sub-thread's row, a line of the work: its mark, with a dot of how it stands; its title; what it said, where there
 * is that, else how it stands; how it stands again beside what it said, then its time — when it told, or how long it
 * worked; and, where it is listed, a way into it.
 */
function SubThreadRow(props: {
	readonly title: string;
	readonly standing: Standing;
	readonly detail: string | undefined;
	readonly label: string;
	readonly time: ReactNode;
	readonly thread: string | undefined;
}): ReactNode {
	const content = (
		<>
			<SubThreadMark standing={props.standing} />
			<span className="shrink-0 truncate text-foreground">{props.title}</span>
			<span className="min-w-0 flex-1 truncate group-data-[standing=failed]/sub-thread:text-error-foreground">{props.detail ?? props.label}</span>
			{props.detail === undefined ? null : (
				<span className="shrink-0 text-xs text-muted-foreground group-data-[standing=failed]/sub-thread:text-error-foreground">{props.label}</span>
			)}
			{props.time === undefined ? null : <span className="shrink-0 text-xs text-muted-foreground/80 tabular-nums">{props.time}</span>}
			{props.thread === undefined ? null : (
				<ChevronRight className="size-3.5 shrink-0 text-muted-foreground/70 opacity-0 transition-opacity group-hover/sub-thread:opacity-100 group-focus-visible/sub-thread:opacity-100" />
			)}
		</>
	);
	const className = "group/sub-thread work-line";
	const thread = props.thread;
	if (thread === undefined) {
		return (
			<div data-standing={props.standing} className={className}>
				{content}
			</div>
		);
	}
	return (
		<button
			type="button"
			aria-label={`Open ${props.title}`}
			aria-description={props.label}
			data-standing={props.standing}
			onClick={() => go({ place: "thread", thread })}
			className={cn(className, "work-opens cursor-pointer")}
		>
			{content}
		</button>
	);
}

/** How long sub-threads worked: counted on each second while one works, as it stood once all ended. */
export function WorkedFor(props: { readonly worked: Worked }): ReactNode {
	const { began, ended } = props.worked;
	return ended === undefined ? <Counting since={began} written={duration} /> : duration(ended - began);
}

/** A sub-thread's mark among the lines of the work: a bot on a round, with a dot of how it stands. */
function SubThreadMark(props: { readonly standing: Standing }): ReactNode {
	return (
		<Mark className="relative">
			<Bot />
			<span className={cn("absolute -right-0.5 -bottom-0.5 size-1.5 rounded-full ring-2 ring-background", STANDINGS[props.standing].dot)} />
		</Mark>
	);
}

/** A sub-thread's avatar, as a card lists it: a bot, with a dot of how it stands where `standing` is given. */
export function SubThreadAvatar(props: { readonly standing: Standing | undefined }): ReactNode {
	return (
		<span className="relative inline-flex size-6 shrink-0 items-center justify-center rounded-full border border-border/70 bg-muted ring-2 ring-background">
			<Bot className="size-3.5 text-muted-foreground" />
			{props.standing === undefined ? null : (
				<span className={cn("absolute -right-px -bottom-px size-2 rounded-full ring-2 ring-background", STANDINGS[props.standing].dot)} />
			)}
		</span>
	);
}
