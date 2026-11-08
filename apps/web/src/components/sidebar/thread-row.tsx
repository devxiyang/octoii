/**
 * A thread's row in the sidebar: a card of its title over its project's monogram and name, its model, how many
 * sub-threads it delegated to, and on the right how it stands with them — waiting on the person, running for how long,
 * the time going on, or failed — when it began where it is at rest, or till when it is snoozed. Its sub-threads have no
 * cards: they open from its timeline and its details. A right click opens the thread's menu: pin it, snooze it till a time,
 * rename it, show its project's threads alone, copy its id, archive it, or delete it once the person says so again.
 */
import { type ReactNode, useState } from "react";
import type { Configured, Listed } from "@octoii-works/octoii-client";
import { useClient } from "@octoii-works/octoii-client/react";
import { AlarmClock, AlarmClockOff, Archive, Bot, Copy, FolderTree, Pencil, Pin, PinOff, Trash2 } from "lucide-react";
import { isPinned, isSnoozed, projectOf, snoozeTimes, threadTitle, type ThreadStanding } from "../../core/threads.ts";
import { type Directory, modelLabel } from "../../core/models.ts";
import { runningTime, shortAgo, wakeLabel } from "../../core/time.ts";
import { Counting } from "../effects/now.ts";
import { go } from "../state/navigation.ts";
import { ContextMenu, ContextMenuPopup, ContextMenuTrigger, MenuItem, MenuItemLabel, MenuPopup, MenuSeparator, MenuSub, MenuSubTrigger } from "../ui/menu.tsx";
import { cn } from "../ui/cn.ts";
import { Monogram } from "../ui/monogram.tsx";
import { StatusMark } from "../thread/status-mark.tsx";
import { DeleteDialog } from "./delete-dialog.tsx";
import { failed } from "../state/notices.ts";

/**
 * What a row shows besides its thread: how it stands with its sub-threads and how many they are, whether it is the
 * thread shown or the one a sub-thread shown works for, the time now, the models its model is named from, and the
 * project filter.
 */
type RowProps = {
	readonly row: Listed;
	readonly standing: ThreadStanding;
	readonly subThreads: number;
	readonly current: boolean;
	readonly now: number;
	readonly directory: Directory | undefined;
	readonly onFilter: (folder: string) => void;
};

/** A thread's card. */
export function ThreadCard(props: RowProps): ReactNode {
	const { row, current } = props;
	const [renaming, setRenaming] = useState(false);
	const [deleting, setDeleting] = useState(false);
	const { status } = props.standing;
	// What waits on the person, what failed and the thread shown stand out; what works or rests recedes.
	const recede = status === "working" || (status === "ready" && !current);
	const project = projectOf(row);
	const model = row.manifest.model;
	return (
		<li className="py-px">
			<ContextMenu>
				<ContextMenuTrigger
					aria-current={current ? "page" : undefined}
					className="group/row relative block w-full cursor-pointer rounded-lg border border-transparent px-2.5 py-2 hover:bg-sidebar-row-hover data-popup-open:bg-sidebar-row-hover aria-[current=page]:border-sidebar-border aria-[current=page]:bg-sidebar-row-active aria-[current=page]:shadow-xs/5"
					onClick={() => go({ place: "thread", thread: row.id })}
				>
					{renaming ? (
						<TitleField row={row} onDone={() => setRenaming(false)} />
					) : (
						<div className={cn("truncate text-sm", recede ? "text-sidebar-foreground/80" : "font-medium text-sidebar-foreground")}>{threadTitle(row)}</div>
					)}
					<div className="mt-0.5 flex h-4 items-center gap-1.5 text-xs text-sidebar-muted">
						<Monogram name={project?.name ?? "No project"} faded={project === undefined} />
						<span className="max-w-1/2 shrink-0 truncate">{project?.name ?? "No project"}</span>
						{model === undefined ? (
							<span className="flex-1" />
						) : (
							<>
								<span aria-hidden>·</span>
								<span className="min-w-0 flex-1 truncate">{modelLabel(model, props.directory)}</span>
							</>
						)}
						{props.subThreads === 0 ? null : (
							<span title={`${String(props.subThreads)} sub-threads`} className="flex shrink-0 items-center gap-0.5 tabular-nums">
								<Bot className="size-3.5" />
								{props.subThreads}
							</span>
						)}
						<StatusSlot row={row} standing={props.standing} now={props.now} />
					</div>
				</ContextMenuTrigger>
				<RowMenu {...props} onRename={() => setRenaming(true)} onDelete={() => setDeleting(true)} />
			</ContextMenu>
			<DeleteDialog row={row} open={deleting} onOpenChange={setDeleting} />
		</li>
	);
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
			className="-my-0.5 h-6 w-full rounded border border-primary bg-background px-1 text-sm outline-none"
		/>
	);
}

/**
 * How a thread stands with its sub-threads, by its mark and its words: waiting on the person, running for how long,
 * the time going on, or failed; when it began where it is at rest, or till when it is snoozed.
 */
function StatusSlot(props: { readonly row: Listed; readonly standing: ThreadStanding; readonly now: number }): ReactNode {
	const { row, standing, now } = props;
	const until = row.manifest.snoozed_until;
	if (until !== undefined && until > now) {
		return (
			<span className="flex shrink-0 items-center gap-1 tabular-nums">
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
			return <span className="shrink-0 tabular-nums">{shortAgo(now - standing.since)}</span>;
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

/** A thread's menu: pin it, snooze it, rename it, show its project's threads alone, copy its id, archive it or delete it. */
function RowMenu(props: RowProps & { readonly onRename: () => void; readonly onDelete: () => void }): ReactNode {
	const { row } = props;
	const client = useClient();
	const project = projectOf(row);
	const pinned = isPinned(row);
	const change = (changes: Configured): void =>
		void client.configure(row.id, changes).catch((error: unknown) => failed("The thread could not be changed", error));
	return (
		<ContextMenuPopup className="w-56">
			<MenuItem onClick={() => change({ pinned: !pinned })}>
				{pinned ? <PinOff /> : <Pin />}
				<MenuItemLabel>{pinned ? "Unpin thread" : "Pin thread"}</MenuItemLabel>
			</MenuItem>
			{isSnoozed(row, props.now) ? (
				<MenuItem onClick={() => change({ snoozed_until: props.now })}>
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
						{snoozeTimes(props.now).map((time) => (
							<MenuItem key={time.label} onClick={() => change({ snoozed_until: time.until })}>
								<MenuItemLabel>{time.label}</MenuItemLabel>
								<span className="ms-auto text-xs text-muted-foreground tabular-nums">{wakeLabel(time.until, props.now)}</span>
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
