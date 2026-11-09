/**
 * A thread's row in the sidebar. A card for one pinned, open to the person, working or snoozed: its project over its
 * title — the project's monogram in its hue and its name, which shows the project's threads alone, how many sub-threads
 * it delegated to, and on the right how it stands with them: waiting on the person, running for how long, failed, when
 * it came to rest, or till when it is snoozed — the title in full weight while what it brought is unread. A line for
 * one of the earlier: its monogram, its title and how it stands. Its sub-threads have no rows: they open from its
 * timeline and its details. A right click opens the thread's menu: mark it unread, pin it, snooze it till a time,
 * rename it, show its project's threads alone, copy its id, archive it, or delete it once the person says so again.
 */
import { type ReactNode, useState } from "react";
import type { Configured, Listed } from "@octoii-works/octoii-client";
import { useClient } from "@octoii-works/octoii-client/react";
import { AlarmClock, AlarmClockOff, Archive, Bot, CircleDot, Copy, FolderTree, Pencil, Pin, PinOff, Trash2 } from "lucide-react";
import { canMarkUnread, isPinned, isSnoozed, isUnread, type Project, projectOf, snoozeTimes, threadTitle, type ThreadStanding } from "../../core/threads.ts";
import { runningTime, shortAgo, wakeLabel } from "../../core/time.ts";
import { Counting } from "../effects/now.ts";
import { go } from "../state/navigation.ts";
import { failed } from "../state/notices.ts";
import { ContextMenu, ContextMenuPopup, ContextMenuTrigger, MenuItem, MenuItemLabel, MenuPopup, MenuSeparator, MenuSub, MenuSubTrigger } from "../ui/menu.tsx";
import { cn } from "../ui/cn.ts";
import { ProjectMark } from "../files/project-mark.tsx";
import { StatusMark } from "../thread/status-mark.tsx";
import { DeleteDialog } from "./delete-dialog.tsx";

/**
 * What a row shows besides its thread: how it stands with its sub-threads and how many they are, whether it is the
 * thread shown or the one a sub-thread shown works for, the time now, and the project filter.
 */
type RowProps = {
	readonly row: Listed;
	readonly standing: ThreadStanding;
	readonly subThreads: number;
	readonly current: boolean;
	readonly now: number;
	readonly onFilter: (folder: string) => void;
};

/** A thread's card. */
export function ThreadCard(props: RowProps): ReactNode {
	const { row, standing } = props;
	const [renaming, setRenaming] = useState(false);
	const [deleting, setDeleting] = useState(false);
	const project = projectOf(row);
	return (
		<li className="py-px">
			<ContextMenu>
				<ContextMenuTrigger
					aria-current={props.current ? "page" : undefined}
					className="group/row relative grid w-full cursor-pointer grid-cols-[auto_minmax(0,1fr)] items-center gap-x-1.5 gap-y-1 rounded-lg border border-transparent px-2.5 py-2 hover:bg-sidebar-row-hover data-popup-open:bg-sidebar-row-hover aria-[current=page]:border-sidebar-border aria-[current=page]:bg-sidebar-row-active aria-[current=page]:shadow-xs/5"
					onClick={() => go({ place: "thread", thread: row.id })}
				>
					<ProjectMark project={project} size="md" />
					<div className="flex h-5 min-w-0 items-center gap-1.5 text-xs">
						<ProjectName project={project} onFilter={props.onFilter} />
						<span className="flex-1" />
						<SubThreads count={props.subThreads} />
						<StatusSlot row={row} standing={standing} now={props.now} />
					</div>
					<div className="col-start-2 flex min-w-0 items-center">
						{renaming ? <TitleField row={row} onDone={() => setRenaming(false)} /> : <Title row={row} standing={standing} />}
					</div>
				</ContextMenuTrigger>
				<RowMenu {...props} onRename={() => setRenaming(true)} onDelete={() => setDeleting(true)} />
			</ContextMenu>
			<DeleteDialog row={row} open={deleting} onOpenChange={setDeleting} />
		</li>
	);
}

/** One of the earlier threads, as a line: its project's monogram, its title, and how it stands. */
export function ThreadLine(props: RowProps): ReactNode {
	const { row, standing } = props;
	const [renaming, setRenaming] = useState(false);
	const [deleting, setDeleting] = useState(false);
	const project = projectOf(row);
	return (
		<li>
			<ContextMenu>
				<ContextMenuTrigger
					aria-current={props.current ? "page" : undefined}
					className="group/row flex h-control w-full cursor-pointer items-center gap-1.5 rounded-lg border border-transparent px-2.5 text-xs hover:bg-sidebar-row-hover data-popup-open:bg-sidebar-row-hover aria-[current=page]:border-sidebar-border aria-[current=page]:bg-sidebar-row-active"
					onClick={() => go({ place: "thread", thread: row.id })}
				>
					<ProjectMark project={project} faded />
					{renaming ? (
						<TitleField row={row} onDone={() => setRenaming(false)} />
					) : (
						<span className="min-w-0 flex-1 truncate text-ui text-sidebar-foreground/70 group-hover/row:text-sidebar-foreground">{threadTitle(row)}</span>
					)}
					<span className="text-sidebar-muted">
						<StatusSlot row={row} standing={standing} now={props.now} />
					</span>
				</ContextMenuTrigger>
				<RowMenu {...props} onRename={() => setRenaming(true)} onDelete={() => setDeleting(true)} />
			</ContextMenu>
			<DeleteDialog row={row} open={deleting} onOpenChange={setDeleting} />
		</li>
	);
}

/** The project's name, which shows the project's threads alone; words of no project where the thread works in none. */
function ProjectName(props: { readonly project: Project | undefined; readonly onFilter: (folder: string) => void }): ReactNode {
	const { project } = props;
	if (project === undefined) return <span className="truncate text-sidebar-muted">No project</span>;
	return (
		<button
			type="button"
			title={`Show ${project.name}'s threads alone`}
			className="min-w-0 truncate font-medium text-sidebar-foreground hover:underline"
			onClick={(event) => {
				event.stopPropagation();
				props.onFilter(project.folder);
			}}
		>
			{project.name}
		</button>
	);
}

/** A thread's title: in full weight while what it brought is unread, quieter once seen. */
function Title(props: { readonly row: Listed; readonly standing: ThreadStanding }): ReactNode {
	const unread = isUnread(props.row, props.standing);
	return (
		<span className={cn("min-w-0 flex-1 truncate text-sm", unread ? "font-medium text-sidebar-foreground" : "text-sidebar-foreground/80")}>
			{threadTitle(props.row)}
		</span>
	);
}

/** How many sub-threads a thread delegated to; nothing where it delegated to none. */
function SubThreads(props: { readonly count: number }): ReactNode {
	if (props.count === 0) return null;
	return (
		<span title={`${String(props.count)} sub-threads`} className="flex shrink-0 items-center gap-0.5 text-sidebar-muted tabular-nums">
			<Bot className="size-3.5" />
			{props.count}
		</span>
	);
}

/** How the thread's changes go to the node, what it refused told as a notice. */
function useChange(row: Listed): (changes: Configured) => void {
	const client = useClient();
	return (changes) => void client.configure(row.id, changes).catch((error: unknown) => failed("The thread could not be changed", error));
}

/** The field a title is written in, over the row's title: Enter keeps it; Escape or leaving drops it. */
function TitleField(props: { readonly row: Listed; readonly onDone: () => void }): ReactNode {
	const client = useClient();
	const [title, setTitle] = useState(threadTitle(props.row));
	const keep = (): void => {
		const kept = title.trim();
		if (kept !== "" && kept !== threadTitle(props.row))
			client.configure(props.row.id, { title: kept }).catch((error: unknown) => failed("The thread could not be renamed", error));
		props.onDone();
	};
	return (
		<input
			aria-label="Thread title"
			// The field opens as the person asks to rename from the menu, which gives the focus back as it closes: the field takes it after.
			ref={(field) => {
				if (field !== null) requestAnimationFrame(() => field.focus());
			}}
			value={title}
			maxLength={120}
			onChange={(event) => setTitle(event.target.value)}
			onClick={(event) => event.stopPropagation()}
			onFocus={(event) => event.target.select()}
			onBlur={props.onDone}
			onKeyDown={(event) => {
				if (event.key === "Enter") keep();
				if (event.key === "Escape") props.onDone();
			}}
			className="-my-0.5 h-6 w-full min-w-0 flex-1 rounded border border-primary bg-background px-1 text-sm outline-none"
		/>
	);
}

/**
 * How a thread stands with its sub-threads, by its mark and its words: waiting on the person, running for how long,
 * failed, or how long ago it came to rest; till when it is snoozed.
 */
function StatusSlot(props: { readonly row: Listed; readonly standing: ThreadStanding; readonly now: number }): ReactNode {
	const { row, standing, now } = props;
	const until = row.manifest.snoozed_until;
	if (until !== undefined && until > now) {
		return (
			<span className="flex shrink-0 items-center gap-1 text-sidebar-muted tabular-nums">
				<AlarmClock className="size-3.5" />
				{wakeLabel(until, now)}
			</span>
		);
	}
	const { status } = standing;
	switch (status) {
		case "asks":
			return (
				<Standing mark={<StatusMark status={status} />} className="text-warning-foreground">
					Needs you
				</Standing>
			);
		case "working":
			return (
				<Standing mark={<StatusMark status={status} />} className="text-info-foreground">
					<Counting since={standing.since} written={runningTime} />
				</Standing>
			);
		case "failed":
			return (
				<Standing mark={<StatusMark status={status} />} className="text-error-foreground">
					Failed
				</Standing>
			);
		case "ready":
			return <span className="shrink-0 text-sidebar-muted tabular-nums">{shortAgo(now - standing.since)}</span>;
	}
}

/** How a thread stands that is not at rest: its mark, then its words, in its colour. */
function Standing(props: { readonly mark: ReactNode; readonly className: string; readonly children: ReactNode }): ReactNode {
	return (
		<span className={cn("flex shrink-0 items-center gap-1 tabular-nums", props.className)}>
			{props.mark}
			{props.children}
		</span>
	);
}

/** A thread's menu: mark it unread, pin it, snooze it, rename it, show its project's threads alone, copy its id, archive it or delete it. */
function RowMenu(props: RowProps & { readonly onRename: () => void; readonly onDelete: () => void }): ReactNode {
	const { row, standing, now } = props;
	const change = useChange(row);
	const project = projectOf(row);
	const pinned = isPinned(row);
	return (
		<ContextMenuPopup className="w-56">
			{canMarkUnread(row, standing) ? (
				<MenuItem onClick={() => change({ seen_until: 0 })}>
					<CircleDot />
					<MenuItemLabel>Mark as unread</MenuItemLabel>
				</MenuItem>
			) : null}
			<MenuItem onClick={() => change({ pinned: !pinned })}>
				{pinned ? <PinOff /> : <Pin />}
				<MenuItemLabel>{pinned ? "Unpin thread" : "Pin thread"}</MenuItemLabel>
			</MenuItem>
			{isSnoozed(row, now) ? (
				<MenuItem onClick={() => change({ snoozed_until: now })}>
					<AlarmClockOff />
					<MenuItemLabel>Unsnooze</MenuItemLabel>
				</MenuItem>
			) : (
				<MenuSub>
					<MenuSubTrigger>
						<AlarmClock />
						<MenuItemLabel>Snooze</MenuItemLabel>
					</MenuSubTrigger>
					<MenuPopup side="right" align="start" sideOffset={6} className="w-48">
						{snoozeTimes(now).map((time) => (
							<MenuItem key={time.label} onClick={() => change({ snoozed_until: time.until })}>
								<MenuItemLabel>{time.label}</MenuItemLabel>
								<span className="ms-auto text-xs text-muted-foreground tabular-nums">{wakeLabel(time.until, now)}</span>
							</MenuItem>
						))}
					</MenuPopup>
				</MenuSub>
			)}
			<MenuItem onClick={props.onRename}>
				<Pencil />
				<MenuItemLabel>Rename thread</MenuItemLabel>
			</MenuItem>
			{project === undefined ? null : (
				<MenuItem onClick={() => props.onFilter(project.folder)}>
					<FolderTree />
					<MenuItemLabel>{`Filter by ${project.name}`}</MenuItemLabel>
				</MenuItem>
			)}
			<MenuSeparator />
			<MenuItem onClick={() => void navigator.clipboard.writeText(row.id)}>
				<Copy />
				<MenuItemLabel>Copy thread ID</MenuItemLabel>
			</MenuItem>
			<MenuSeparator />
			<MenuItem onClick={() => change({ archived: true })}>
				<Archive />
				<MenuItemLabel>Archive thread</MenuItemLabel>
			</MenuItem>
			<MenuItem variant="destructive" onClick={props.onDelete}>
				<Trash2 />
				<MenuItemLabel>Delete thread…</MenuItemLabel>
			</MenuItem>
		</ContextMenuPopup>
	);
}
