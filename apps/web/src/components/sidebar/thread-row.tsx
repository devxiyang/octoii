/**
 * A thread's row in the sidebar. A card for one that is active, pinned, working or snoozed: on its first line its
 * project's monogram, a pin where it is pinned, the project's name, how many sub-threads it delegated to, and at the end
 * how it stands — waiting on the person, running for how long, failed, when it came to rest, or till when it is snoozed —
 * which, as the row is pointed at, gives way to what it is done with there: snoozed till a time, and settled, or, where
 * it sleeps, woken; under them its title, in full weight while what it brought is unread, and the mark of its model's
 * maker. A line for one settled: its monogram, its title and when something last came of it, which gives way to bringing
 * it back. Its sub-threads have no rows: they open from its timeline and its details. A right click opens the thread's
 * menu: mark it unread, pin it, snooze it till a time, settle it or bring it back, rename it, show its project's threads
 * alone, copy its id, archive it, or delete it once the person says so again.
 */
import { type MouseEvent, type ReactNode, useState } from "react";
import type { Configured, Listed } from "@octoii-works/octoii-client";
import { useClient } from "@octoii-works/octoii-client/react";
import { AlarmClock, AlarmClockOff, Archive, Bot, Check, CircleDot, Copy, FolderTree, Pencil, Pin, PinOff, Trash2, Undo2 } from "lucide-react";
import { canMarkUnread, isPinned, isSettled, isSnoozed, isUnread, projectOf, snoozeTimes, threadTitle, type ThreadStanding } from "../../core/threads.ts";
import { runningTime, shortAgo, wakeLabel } from "../../core/time.ts";
import type { Vendor } from "../../core/vendors.ts";
import { Counting } from "../effects/now.ts";
import { go } from "../state/navigation.ts";
import { failed } from "../state/notices.ts";
import {
	ContextMenu,
	ContextMenuPopup,
	ContextMenuTrigger,
	Menu,
	MenuItem,
	MenuItemLabel,
	MenuPopup,
	MenuSeparator,
	MenuSub,
	MenuSubTrigger,
	MenuTrigger,
} from "../ui/menu.tsx";
import { cn } from "../ui/cn.ts";
import { VendorMark } from "../ui/vendor-mark.tsx";
import { ProjectMark } from "../files/project-mark.tsx";
import { StatusMark } from "../thread/status-mark.tsx";
import { DeleteDialog } from "./delete-dialog.tsx";

/**
 * What a row shows besides its thread: how it stands with its sub-threads and how many they are, the maker of its
 * model, whether it is the thread shown or the one a sub-thread shown works for, the time now, and the project filter.
 */
type RowProps = {
	readonly row: Listed;
	readonly standing: ThreadStanding;
	readonly subThreads: number;
	readonly vendor: Vendor | undefined;
	readonly current: boolean;
	readonly now: number;
	readonly onFilter: (folder: string) => void;
	/** Whether it came into the list after the list was first drawn, so fades in; one that moves glides instead. */
	readonly fades?: boolean;
};

/** A thread's card. */
export function ThreadCard(props: RowProps): ReactNode {
	const { row, standing } = props;
	const [renaming, setRenaming] = useState(false);
	const [deleting, setDeleting] = useState(false);
	const project = projectOf(row);
	return (
		<li data-glide={row.id} className={cn("py-px", props.fades === true && "animate-fade-in motion-reduce:animate-none")}>
			<ContextMenu>
				<ContextMenuTrigger
					aria-current={props.current ? "page" : undefined}
					className="group/row relative w-full cursor-pointer rounded-md px-2.5 py-2 hover:bg-accent data-popup-open:bg-accent aria-[current=page]:bg-selected"
					onClick={() => go({ place: "thread", thread: row.id })}
				>
					<div className="flex h-5 min-w-0 items-center gap-1.5 text-xs">
						<ProjectMark project={project} />
						{isPinned(row) ? <PinMark row={row} /> : null}
						<span className="min-w-0 flex-1 truncate text-muted-foreground">{project?.name ?? "No project"}</span>
						<SubThreads count={props.subThreads} />
						<Slot standing={<StatusSlot row={row} standing={standing} now={props.now} />} actions={<CardActions {...props} />} />
					</div>
					<div className="mt-1 flex min-w-0 items-center gap-1.5">
						{renaming ? <TitleField row={row} onDone={() => setRenaming(false)} /> : <Title row={row} standing={standing} />}
						{props.vendor === undefined ? null : <VendorMark vendor={props.vendor} name="" />}
					</div>
				</ContextMenuTrigger>
				<RowMenu {...props} onRename={() => setRenaming(true)} onDelete={() => setDeleting(true)} />
			</ContextMenu>
			<DeleteDialog row={row} open={deleting} onOpenChange={setDeleting} />
		</li>
	);
}

/** A settled thread, as a line: its project's monogram, its title, and when something last came of it. */
export function ThreadLine(props: RowProps): ReactNode {
	const { row, standing } = props;
	const [renaming, setRenaming] = useState(false);
	const [deleting, setDeleting] = useState(false);
	const project = projectOf(row);
	const change = useChange(row);
	return (
		<li data-glide={row.id} className={cn(props.fades === true && "animate-fade-in motion-reduce:animate-none")}>
			<ContextMenu>
				<ContextMenuTrigger
					aria-current={props.current ? "page" : undefined}
					className="group/row flex h-control w-full cursor-pointer items-center gap-2 rounded-md border border-transparent px-2.5 text-xs hover:bg-accent data-popup-open:bg-accent aria-[current=page]:border-border aria-[current=page]:bg-selected"
					onClick={() => go({ place: "thread", thread: row.id })}
				>
					<ProjectMark project={project} faded={!props.current} />
					{renaming ? <TitleField row={row} onDone={() => setRenaming(false)} /> : <Title row={row} standing={standing} />}
					<Slot
						standing={<span className="text-muted-foreground tabular-nums">{shortAgo(props.now - standing.since)}</span>}
						actions={
							<RowButton label="Bring back the thread" onClick={() => change({ unsettled_at: Date.now() })}>
								<Undo2 className="size-3.5" />
							</RowButton>
						}
					/>
				</ContextMenuTrigger>
				<RowMenu {...props} onRename={() => setRenaming(true)} onDelete={() => setDeleting(true)} />
			</ContextMenu>
			<DeleteDialog row={row} open={deleting} onOpenChange={setDeleting} />
		</li>
	);
}

/**
 * The end of a row's first line: how the thread stands, which gives way, as the row is pointed at or something in it
 * holds the focus or a menu open, to what the thread is done with there.
 */
function Slot(props: { readonly standing: ReactNode; readonly actions: ReactNode }): ReactNode {
	const doing = "group-hover/row:flex group-focus-within/row:flex group-has-[[data-popup-open]]/row:flex";
	return (
		<span className="relative ms-auto flex h-5 shrink-0 items-center justify-end">
			<span className="flex items-center group-hover/row:invisible group-hover/row:absolute group-hover/row:right-0 group-focus-within/row:invisible group-focus-within/row:absolute group-focus-within/row:right-0 group-has-[[data-popup-open]]/row:invisible group-has-[[data-popup-open]]/row:absolute group-has-[[data-popup-open]]/row:right-0">
				{props.standing}
			</span>
			<span className={cn("hidden items-center gap-0.5", doing)}>{props.actions}</span>
		</span>
	);
}

/** What a card's thread is done with there: one that sleeps woken; else snoozed till a time, and settled where it is at rest. */
function CardActions(props: RowProps): ReactNode {
	const { row, standing, now } = props;
	const change = useChange(row);
	if (isSnoozed(row, now)) {
		return (
			<RowButton label="Wake the thread now" onClick={() => change({ snoozed_until: Date.now() })}>
				<AlarmClockOff className="size-3.5" />
			</RowButton>
		);
	}
	const resting = standing.status !== "asks" && standing.status !== "working";
	return (
		<>
			<SnoozeButton row={row} now={now} />
			{resting ? (
				<RowButton label="Settle the thread" onClick={() => change({ settled_at: Date.now() })}>
					<Check className="size-3.5" />
					Settle
				</RowButton>
			) : null}
		</>
	);
}

/** A button of a row, which does what it says without opening the thread. */
function RowButton(props: { readonly label: string; readonly onClick: () => void; readonly children: ReactNode }): ReactNode {
	return (
		<button
			type="button"
			aria-label={props.label}
			title={props.label}
			className="flex h-5 cursor-pointer items-center gap-1 rounded-sm px-1 text-xs text-muted-foreground hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none"
			onClick={(event: MouseEvent) => {
				event.stopPropagation();
				props.onClick();
			}}
		>
			{props.children}
		</button>
	);
}

/** The button that snoozes a thread till a time, as the menu it opens offers. */
function SnoozeButton(props: { readonly row: Listed; readonly now: number }): ReactNode {
	const change = useChange(props.row);
	return (
		<Menu>
			<MenuTrigger
				aria-label="Snooze the thread"
				title="Snooze the thread"
				className="flex size-5 cursor-pointer items-center justify-center rounded-sm text-muted-foreground hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none"
				onClick={(event: MouseEvent) => event.stopPropagation()}
			>
				<AlarmClock className="size-3.5" />
			</MenuTrigger>
			<MenuPopup align="end" className="w-48">
				<SnoozeItems now={props.now} onSnooze={(until) => change({ snoozed_until: until })} />
			</MenuPopup>
		</Menu>
	);
}

/** The times a thread may be snoozed till, each with when it would wake. */
function SnoozeItems(props: { readonly now: number; readonly onSnooze: (until: number) => void }): ReactNode {
	return snoozeTimes(props.now).map((time) => (
		<MenuItem key={time.label} onClick={() => props.onSnooze(time.until)}>
			<MenuItemLabel>{time.label}</MenuItemLabel>
			<span className="ms-auto text-xs text-muted-foreground tabular-nums">{wakeLabel(time.until, props.now)}</span>
		</MenuItem>
	));
}

/** The pin of a pinned thread, which unpins it. */
function PinMark(props: { readonly row: Listed }): ReactNode {
	const change = useChange(props.row);
	return (
		<button
			type="button"
			aria-label="Unpin the thread"
			title="Unpin the thread"
			className="group/pin flex shrink-0 cursor-pointer items-center text-faint-foreground hover:text-foreground"
			onClick={(event) => {
				event.stopPropagation();
				change({ pinned: false });
			}}
		>
			<Pin className="size-3 group-hover/pin:hidden" />
			<PinOff className="hidden size-3 group-hover/pin:block" />
		</button>
	);
}

/** A thread's title: in full weight while what it brought is unread, quieter once seen. */
function Title(props: { readonly row: Listed; readonly standing: ThreadStanding }): ReactNode {
	const unread = isUnread(props.row, props.standing);
	return (
		<span className={cn("min-w-0 flex-1 truncate text-ui", unread ? "font-medium text-foreground" : "text-muted-foreground")}>{threadTitle(props.row)}</span>
	);
}

/** How many sub-threads a thread delegated to; nothing where it delegated to none. */
function SubThreads(props: { readonly count: number }): ReactNode {
	if (props.count === 0) return null;
	return (
		<span title={`${String(props.count)} sub-threads`} className="flex shrink-0 items-center gap-0.5 text-muted-foreground tabular-nums">
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
			className="-my-0.5 h-6 w-full min-w-0 flex-1 rounded-sm border border-primary bg-background px-1 text-ui outline-none"
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
			<span className="flex shrink-0 items-center gap-1 text-muted-foreground tabular-nums">
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
					Waiting for you
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
			return <span className="shrink-0 text-muted-foreground tabular-nums">{shortAgo(now - standing.since)}</span>;
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

/**
 * A thread's menu: mark it unread, pin it, snooze it, settle it or bring it back, rename it, show its project's threads
 * alone, copy its id, archive it or delete it.
 */
function RowMenu(props: RowProps & { readonly onRename: () => void; readonly onDelete: () => void }): ReactNode {
	const { row, standing, now } = props;
	const change = useChange(row);
	const project = projectOf(row);
	const pinned = isPinned(row);
	const settled = isSettled(row, standing, now);
	const resting = standing.status !== "asks" && standing.status !== "working";
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
						<SnoozeItems now={now} onSnooze={(until) => change({ snoozed_until: until })} />
					</MenuPopup>
				</MenuSub>
			)}
			{settled ? (
				<MenuItem onClick={() => change({ unsettled_at: Date.now() })}>
					<Undo2 />
					<MenuItemLabel>Bring back</MenuItemLabel>
				</MenuItem>
			) : resting ? (
				<MenuItem onClick={() => change({ settled_at: Date.now() })}>
					<Check />
					<MenuItemLabel>Settle thread</MenuItemLabel>
				</MenuItem>
			) : null}
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
