/**
 * The inbox, the page's home: three columns side by side, each a tray of what it holds under its name and how many —
 * what waits on the person, what runs, what was done of late — one under the other where the page is narrow. What
 * waits and what runs are cards: a thread's title, which opens it; its project and its model; how it stands with its
 * sub-threads and since when, a running one's time going on; what it asks the person, answered on the card as in the
 * thread; for a sub-thread, the thread it works for; and under a top thread its sub-threads as a tree, each opening its
 * own. What was done is a list, a line a thread: how it ended, its project, its title and when.
 */
import type { ReactNode } from "react";
import type { Listed } from "@octoii-works/octoii-client";
import { useThreads } from "@octoii-works/octoii-client/react";
import { CornerLeftUp, SquarePen } from "lucide-react";
import { inboxOf } from "../core/inbox.ts";
import { type Directory, modelLabel } from "../core/models.ts";
import { asksOf, isArchived, projectOf, statusOf, subThreadsOf, threadTitle, type ThreadStanding } from "../core/threads.ts";
import { duration, runningTime, shortAgo } from "../core/time.ts";
import { AskForm } from "../components/composer/asks.tsx";
import { useDirectory } from "../components/composer/directory.ts";
import { Counting, useNow } from "../components/effects/now.ts";
import { go } from "../components/state/navigation.ts";
import { ChatHeader } from "../components/thread/header.tsx";
import { StatusMark } from "../components/thread/status-mark.tsx";
import { IconButton } from "../components/ui/button.tsx";
import { Monogram } from "../components/ui/monogram.tsx";

/** What the inbox is given: the sidebar's state. */
export type InboxScreenProps = { readonly sidebarHidden: boolean; readonly onShowSidebar: () => void };

/** The inbox. */
export function InboxScreen(props: InboxScreenProps): ReactNode {
	const rows = useThreads();
	const now = useNow(30_000);
	const directory = useDirectory();
	const inbox = inboxOf(rows ?? [], now);
	return (
		<div className="panel flex min-w-0 flex-1 flex-col overflow-hidden">
			<ChatHeader
				title="Inbox"
				sidebarHidden={props.sidebarHidden}
				onShowSidebar={props.onShowSidebar}
				actions={
					<IconButton label="New thread" shortcut="⌘N" onClick={() => go({ place: "new" })}>
						<SquarePen className="size-4" />
					</IconButton>
				}
			/>
			<div className="min-h-0 flex-1 overflow-y-auto px-3 pt-2 pb-6 sm:px-5">
				<div className="mx-auto grid max-w-6xl items-start gap-x-10 gap-y-6 md:grid-cols-3">
					<Column title="Needs you" count={inbox.asking.length} empty="Nothing waits on you">
						{inbox.asking.map((row) => (
							<InboxCard key={row.id} row={row} standing={inbox.standingOf(row)} rows={rows ?? []} now={now} directory={directory} />
						))}
					</Column>
					<Column title="Running" count={inbox.working.length} empty="Nothing runs">
						{inbox.working.map((row) => (
							<InboxCard key={row.id} row={row} standing={inbox.standingOf(row)} rows={rows ?? []} now={now} directory={directory} />
						))}
					</Column>
					<Column title="Done" count={inbox.done.length} empty="Nothing done of late">
						<ul className="flex flex-col">
							{inbox.done.map((row) => (
								<DoneRow key={row.id} row={row} now={now} />
							))}
						</ul>
					</Column>
				</div>
			</div>
		</div>
	);
}

/** A column: a tray of its title and how many it holds over what it holds, or words for none. */
function Column(props: { readonly title: string; readonly count: number; readonly empty: string; readonly children: ReactNode }): ReactNode {
	return (
		<section className="tray flex min-w-0 flex-col gap-1.5">
			<h2 className="label-caps flex h-control-sm items-center justify-between ps-2 pe-1">
				{props.title}
				<span className="min-w-5 rounded-md bg-foreground/6 px-1.5 text-center leading-5 tracking-normal tabular-nums">{props.count}</span>
			</h2>
			{props.count === 0 ? <p className="px-2 pb-2 text-ui text-muted-foreground/70">{props.empty}</p> : props.children}
		</section>
	);
}

/** A thread done of late, in a line: how it ended, its project's monogram, its title, which opens it, and when. */
function DoneRow(props: { readonly row: Listed; readonly now: number }): ReactNode {
	const { row } = props;
	const project = projectOf(row);
	const ended = row.state.ended_at;
	return (
		<li>
			<button
				type="button"
				title={project === undefined ? threadTitle(row) : `${threadTitle(row)} · ${project.name}`}
				onClick={() => go({ place: "thread", thread: row.id })}
				className="group/row flex h-control-lg w-full min-w-0 items-center gap-2.5 rounded-lg px-2 text-left outline-none hover:bg-card focus-visible:ring-2 focus-visible:ring-ring/70"
			>
				<StatusMark status={statusOf(row)} />
				<Monogram name={project?.name ?? "No project"} faded={project === undefined} size="md" />
				<span className="min-w-0 flex-1 truncate text-sm">{threadTitle(row)}</span>
				{ended === undefined ? null : <span className="shrink-0 text-xs text-secondary-label tabular-nums">{shortAgo(props.now - ended)}</span>}
			</button>
		</li>
	);
}

/** A thread's card. */
function InboxCard(props: {
	readonly row: Listed;
	readonly standing: ThreadStanding;
	readonly rows: readonly Listed[];
	readonly now: number;
	readonly directory: Directory | undefined;
}): ReactNode {
	const { row } = props;
	const project = projectOf(row);
	const model = row.manifest.model;
	const parent = props.rows.find((each) => each.id === row.manifest.parent?.thread);
	const asks = asksOf(row);
	return (
		<article className="card flex flex-col gap-2 p-3 shadow-xs/5">
			<button
				type="button"
				onClick={() => go({ place: "thread", thread: row.id })}
				className="flex min-w-0 flex-col items-start gap-1 rounded-md text-left outline-none focus-visible:ring-2 focus-visible:ring-ring/70"
			>
				<span className="w-full truncate text-sm font-medium">{threadTitle(row)}</span>
				<span className="flex w-full min-w-0 items-center gap-1.5 text-xs text-muted-foreground">
					{project === undefined ? null : (
						<>
							<Monogram name={project.name} />
							<span className="truncate">{project.name}</span>
						</>
					)}
					{project !== undefined && model !== undefined ? <span className="text-muted-foreground/60">·</span> : null}
					{model === undefined ? null : <span className="truncate">{modelLabel(model, props.directory)}</span>}
				</span>
			</button>
			{parent === undefined ? null : (
				<button
					type="button"
					onClick={() => go({ place: "thread", thread: parent.id })}
					className="flex min-w-0 items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
				>
					<CornerLeftUp className="size-3.5 shrink-0" />
					<span className="truncate">{`For ${threadTitle(parent)}`}</span>
				</button>
			)}
			<Standing row={row} standing={props.standing} now={props.now} />
			{asks.map((ask) => (
				<div key={ask.request.key} className="flex flex-col border-t border-border/60 pt-2.5">
					<AskForm thread={row.id} workspace={row.manifest.workspace} project={row.manifest.project} ask={ask} />
				</div>
			))}
			{row.manifest.parent === undefined ? <SubThreads rows={props.rows} parent={row.id} now={props.now} /> : null}
		</article>
	);
}

/**
 * How a thread stands with its sub-threads, by its mark and its words: waiting on the person since when, running for
 * how long, done in how long and when, or failed when.
 */
function Standing(props: { readonly row: Listed; readonly standing: ThreadStanding; readonly now: number }): ReactNode {
	const { row, standing, now } = props;
	const ended = row.state.ended_at;
	const began = row.state.began_at;
	switch (standing.status) {
		case "asks":
			return <Line mark={<StatusMark status="asks" />}>Waiting for you · {shortAgo(now - standing.since)}</Line>;
		case "working":
			return (
				<Line mark={<StatusMark status="working" />}>
					Running <Counting since={standing.since} written={runningTime} />
				</Line>
			);
		case "failed":
			return <Line mark={<StatusMark status="failed" />}>Failed{ended === undefined ? "" : ` · ${shortAgo(now - ended)}`}</Line>;
		case "ready":
			return (
				<Line mark={<StatusMark status="ready" />}>
					{began === undefined || ended === undefined ? "Done" : `Done in ${duration(ended - began)} · ${shortAgo(now - ended)}`}
				</Line>
			);
	}
}

/** A line of how a thread stands: its mark, then its words. */
function Line(props: { readonly mark: ReactNode; readonly children: ReactNode }): ReactNode {
	return (
		<p className="flex items-center gap-1.5 text-xs text-secondary-label tabular-nums [&_svg]:size-3.5 [&_svg]:shrink-0">
			{props.mark}
			<span className="min-w-0 truncate">{props.children}</span>
		</p>
	);
}

/** The sub-threads of the thread `parent`, under it as a tree: each by its mark, its title and its time, opening it; its own under it. */
function SubThreads(props: { readonly rows: readonly Listed[]; readonly parent: string; readonly now: number }): ReactNode {
	const subs = subThreadsOf(props.rows, props.parent).filter((sub) => !isArchived(sub));
	if (subs.length === 0) return null;
	return (
		<ul className="ms-1.5 flex flex-col gap-0.5 border-s border-border/70 ps-2">
			{subs.map((sub) => (
				<li key={sub.id} className="flex flex-col gap-0.5">
					<button
						type="button"
						onClick={() => go({ place: "thread", thread: sub.id })}
						className="flex min-w-0 items-center gap-2 rounded-md px-1.5 py-1 text-left text-xs outline-none hover:bg-accent/50 focus-visible:ring-2 focus-visible:ring-ring/70"
					>
						<StatusMark status={statusOf(sub)} />
						<span className="min-w-0 flex-1 truncate">{threadTitle(sub)}</span>
						<span className="shrink-0 text-muted-foreground tabular-nums">{subTime(sub, props.now)}</span>
					</button>
					<SubThreads rows={props.rows} parent={sub.id} now={props.now} />
				</li>
			))}
		</ul>
	);
}

/** A sub-thread's time: how long its last turn took, once it ended; else how long ago it began. */
function subTime(row: Listed, now: number): string {
	const { began_at: began, ended_at: ended } = row.state;
	if (began === undefined) return "";
	return ended === undefined ? shortAgo(now - began) : duration(ended - began);
}
