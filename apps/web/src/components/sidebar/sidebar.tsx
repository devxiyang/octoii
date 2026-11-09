/**
 * The sidebar: the button that hides it and the brand; search, a project filter and a new thread; the threads, newest
 * first, each section under its heading — those pinned atop, those
 * that work under them, those at rest under those, or under their projects where the device groups them so, and those
 * snoozed folded at the foot, those archived not at all — a sub-thread on its parent's card, by their count and how
 * they stand; and settings at its foot. Its right edge drags it wider or narrower, the width kept for the device.
 */
import { type ReactNode, useState } from "react";
import type { Listed } from "@octoii-works/octoii-client";
import { useThreads } from "@octoii-works/octoii-client/react";
import { Activity, AlarmClock, FolderOpen, ListFilter, MessagesSquare, PanelLeft, Pin, Search, Settings, SquarePen, X } from "lucide-react";
import type { Directory } from "../../core/models.ts";
import type { Overlay, Route } from "../../core/route.ts";
import { lineOf, matchingRows, type Project, projectOf, projectsOf, rowsBySection, standingsOf, subThreadsBy } from "../../core/threads.ts";
import { useDirectory } from "../composer/directory.ts";
import { useNow } from "../effects/now.ts";
import { useDevice } from "../state/device.ts";
import { go } from "../state/navigation.ts";
import { IconButton } from "../ui/button.tsx";
import { Collapsible, CollapsiblePanel, CollapsibleTrigger, FoldChevron } from "../ui/collapsible.tsx";
import { Input } from "../ui/input.tsx";
import { Menu, MenuItemLabel, MenuPopup, MenuRadioGroup, MenuRadioItem, MenuSeparator, MenuTrigger } from "../ui/menu.tsx";
import { Monogram } from "../ui/monogram.tsx";
import { cn } from "../ui/cn.ts";
import { useDragSize } from "../ui/resize.tsx";
import { ThreadCard } from "./thread-row.tsx";

/**
 * What the sidebar is given: the place shown, how it groups threads, how it hides and opens settings over the chat, and
 * how it stands where the page is narrow — out of the way, or a drawer over the page.
 */
export type SidebarProps = {
	readonly route: Route;
	readonly grouping: "status" | "project";
	readonly onHide: () => void;
	readonly onOverlay: (over: Overlay) => void;
	readonly className?: string;
};

/** How narrow and how wide the sidebar may be dragged. */
const SIDEBAR_BOUNDS = { min: 200, max: 480, grows: "right" } as const;

/** The sidebar. */
export function Sidebar(props: SidebarProps): ReactNode {
	const [query, setQuery] = useState("");
	const [folder, setFolder] = useState<string | undefined>(undefined);
	const rows = useThreads();
	const projects = projectsOf(rows ?? []);
	const now = useNow(30_000);
	const directory = useDirectory();
	const shown = matchingRows(rows ?? [], query).filter((row) => folder === undefined || projectOf(row)?.folder === folder);
	// The thread shown is marked, or where a sub-thread is shown, the one whose card stands for it.
	const current = props.route.place === "thread" ? lineOf(rows ?? [], props.route.thread) : [];
	const { device, set } = useDevice();
	const { size: width, edge } = useDragSize(device.sidebar_width, SIDEBAR_BOUNDS, (width) => set({ sidebar_width: width }));
	return (
		<aside style={{ width }} className={cn("relative flex h-full shrink-0 flex-col bg-sidebar text-sidebar-foreground", props.className)}>
			{edge}
			<div className="flex h-[var(--topbar-height)] shrink-0 items-center gap-1.5 px-2">
				<IconButton label="Hide sidebar" shortcut="⌘B" onClick={props.onHide}>
					<PanelLeft className="size-4" />
				</IconButton>
				<span className="text-sm font-semibold tracking-tight">Octoii</span>
			</div>
			<div className="flex items-center gap-1 px-2 pb-2">
				<label className="group flex h-control min-w-0 flex-1 items-center gap-2 rounded-md px-2 focus-within:ring-1 focus-within:ring-ring/70 hover:bg-sidebar-row-hover">
					<Search className="size-4 shrink-0 text-sidebar-muted" />
					<Input
						type="search"
						variant="bare"
						aria-label="Search threads"
						placeholder="Search"
						value={query}
						onValueChange={setQuery}
						className="font-medium placeholder:text-sidebar-muted"
					/>
					{query === "" ? null : (
						<button type="button" aria-label="Clear the search" className="text-sidebar-muted hover:text-sidebar-foreground" onClick={() => setQuery("")}>
							<X className="size-3.5" />
						</button>
					)}
				</label>
				<ProjectFilter projects={projects} chosen={folder} onChoose={setFolder} />
				<IconButton label="New thread" shortcut="⌘N" onClick={() => go({ place: "new", ...(folder === undefined ? {} : { project: folder }) })}>
					<SquarePen className="size-4" />
				</IconButton>
			</div>
			<div className="min-h-0 flex-1 overflow-y-auto px-2 scrollbar-none">
				{rows === undefined ? null : shown.length === 0 ? (
					<p className="py-6 text-center text-xs text-muted-foreground/60">{query === "" ? "No threads yet" : "No threads found"}</p>
				) : (
					<ThreadList rows={shown} all={rows} current={current} now={now} directory={directory} grouping={props.grouping} onFilter={setFolder} />
				)}
			</div>
			<div className="flex items-center gap-1 px-2 pt-1 pb-2">
				<IconButton label="Settings" size="icon" onClick={() => props.onOverlay({ kind: "settings", section: "general" })}>
					<Settings className="size-4" />
				</IconButton>
			</div>
		</aside>
	);
}

/** The threads pinned, those that work, those at rest, by project where the device groups them so, and those snoozed at the foot. */
function ThreadList(props: {
	readonly rows: readonly Listed[];
	readonly all: readonly Listed[];
	readonly current: readonly string[];
	readonly now: number;
	readonly directory: Directory | undefined;
	readonly grouping: "status" | "project";
	readonly onFilter: (folder: string) => void;
}): ReactNode {
	// How a thread stands, and how many sub-threads it has, are read from every thread: a search that hides a sub-thread
	// hides nothing of how its parent stands.
	const standingOf = standingsOf(props.all);
	const delegated = subThreadsBy(props.all);
	const { pinned, active, working, snoozed } = rowsBySection(props.rows, props.now, standingOf);
	const card = (row: Listed): ReactNode => (
		<ThreadCard
			key={row.id}
			row={row}
			standing={standingOf(row)}
			subThreads={delegated.get(row.id)?.length ?? 0}
			current={props.current.includes(row.id)}
			now={props.now}
			directory={props.directory}
			onFilter={props.onFilter}
		/>
	);
	return (
		<div className="flex min-h-full flex-col">
			<Shelf title="Pinned" count={pinned.length} icon={<Pin className="size-3.5" />}>
				{pinned.map(card)}
			</Shelf>
			<Shelf title="Working" count={working.length} icon={<Activity className="size-3.5" />}>
				{working.map(card)}
			</Shelf>
			{props.grouping === "project" ? (
				<ByProject rows={active} card={card} />
			) : (
				<Shelf title="Threads" count={active.length} icon={<MessagesSquare className="size-3.5" />}>
					{active.map(card)}
				</Shelf>
			)}
			<div className="mt-auto pt-3">
				<Shelf title="Snoozed" count={snoozed.length} icon={<AlarmClock className="size-3.5" />} folded>
					{snoozed.map(card)}
				</Shelf>
			</div>
		</div>
	);
}

/** The threads under their projects' headings, the project its newest thread works in first; those of no project last. */
function ByProject(props: { readonly rows: readonly Listed[]; readonly card: (row: Listed) => ReactNode }): ReactNode {
	const groups = [...projectsOf(props.rows).map((project) => ({ title: project.name, folder: project.folder })), { title: "No project", folder: undefined }];
	return groups.map((group) => {
		const rows = props.rows.filter((row) => projectOf(row)?.folder === group.folder);
		return (
			<Shelf key={group.folder ?? ""} title={group.title} count={rows.length} icon={<Monogram name={group.title} />}>
				{rows.map(props.card)}
			</Shelf>
		);
	});
}

/** A section: its heading, its count and a chevron that folds it, folded at first where `folded` says; nothing where it holds no rows. */
function Shelf(props: {
	readonly title: string;
	readonly count: number;
	readonly icon?: ReactNode;
	readonly folded?: boolean;
	readonly children: ReactNode;
}): ReactNode {
	if (props.count === 0) return null;
	return (
		<Collapsible defaultOpen={props.folded !== true} render={<section className="pb-1" />}>
			<CollapsibleTrigger className="flex h-control w-full cursor-default items-center gap-2 rounded-md px-2.5 text-ui text-sidebar-muted hover:text-sidebar-foreground">
				{props.icon}
				<span className="truncate">{props.title}</span>
				<span className="flex-1" />
				<span className="tabular-nums">{props.count}</span>
				<FoldChevron />
			</CollapsibleTrigger>
			<CollapsiblePanel render={<ul className="flex flex-col" />}>{props.children}</CollapsiblePanel>
		</Collapsible>
	);
}

/** The value the project filter holds where it shows every project. */
const ALL_PROJECTS = "";

/** The project filter: all projects, or one. */
function ProjectFilter(props: {
	readonly projects: readonly Project[];
	readonly chosen: string | undefined;
	readonly onChoose: (folder: string | undefined) => void;
}): ReactNode {
	const chosen = props.projects.find((project) => project.folder === props.chosen);
	return (
		<Menu>
			<MenuTrigger render={<IconButton label="Filter by project" />}>
				{chosen === undefined ? <ListFilter /> : <Monogram name={chosen.name} size="md" />}
			</MenuTrigger>
			<MenuPopup align="end" className="w-60">
				<MenuRadioGroup value={props.chosen ?? ALL_PROJECTS} onValueChange={(folder: string) => props.onChoose(folder === ALL_PROJECTS ? undefined : folder)}>
					<MenuRadioItem value={ALL_PROJECTS}>
						<FolderOpen />
						<MenuItemLabel>All projects</MenuItemLabel>
					</MenuRadioItem>
					{props.projects.length === 0 ? null : <MenuSeparator />}
					{props.projects.map((project) => (
						<MenuRadioItem key={project.folder} value={project.folder}>
							<Monogram name={project.name} />
							<MenuItemLabel title={project.folder}>{project.name}</MenuItemLabel>
						</MenuRadioItem>
					))}
				</MenuRadioGroup>
			</MenuPopup>
		</Menu>
	);
}
