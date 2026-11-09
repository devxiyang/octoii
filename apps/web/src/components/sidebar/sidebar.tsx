/**
 * The sidebar: the brand, and on its right the button that hides it; search, a project filter and a new thread, the project filtered
 * on named under them where one is; the threads of every project in one list, each card naming its project — those
 * pinned atop, then those open to the person, what asks them first, then those that work under their heading, and at
 * the foot, folded, those snoozed and the earlier, a line each, those archived not at all — a sub-thread on its
 * parent's card, by their count and how they stand; and settings at its foot. Beside the chat, its right edge drags it
 * wider or narrower, the width kept for the device; where the page is narrow, it is a drawer over the page instead.
 */
import { type ReactNode, useState } from "react";
import type { Listed } from "@octoii-works/octoii-client";
import { useThreads } from "@octoii-works/octoii-client/react";
import { Activity, AlarmClock, FolderOpen, History, ListFilter, PanelLeft, Pin, Search, Settings, SquarePen, X } from "lucide-react";
import type { Overlay, Route } from "../../core/route.ts";
import { lineOf, matchingRows, type Project, projectOf, projectsOf, rowsBySection, standingsOf, subThreadsBy } from "../../core/threads.ts";
import { useArrived } from "../effects/arrived.ts";
import { useNow } from "../effects/now.ts";
import { useDevice } from "../state/device.ts";
import { go } from "../state/navigation.ts";
import { IconButton } from "../ui/button.tsx";
import { Collapsible, CollapsiblePanel, CollapsibleTrigger, FoldChevron } from "../ui/collapsible.tsx";
import { Input } from "../ui/input.tsx";
import { Menu, MenuItemLabel, MenuPopup, MenuRadioGroup, MenuRadioItem, MenuSeparator, MenuTrigger } from "../ui/menu.tsx";
import { ProjectMark } from "../files/project-mark.tsx";
import { cn } from "../ui/cn.ts";
import { Drawer, DrawerPopup, DrawerSwipeArea, DrawerTitle } from "../ui/drawer.tsx";
import { useDragSize } from "../ui/resize.tsx";
import { ThreadCard, ThreadLine } from "./thread-row.tsx";

/** What the sidebar is given: the place shown, and how it hides and opens settings over the chat. */
export type SidebarProps = {
	readonly route: Route;
	readonly onHide: () => void;
	readonly onOverlay: (over: Overlay) => void;
};

/** How narrow and how wide the sidebar may be dragged. */
const SIDEBAR_BOUNDS = { min: 200, max: 480, grows: "right" } as const;

/** The sidebar beside the chat, its right edge dragged to make it wider or narrower. */
export function Sidebar(props: SidebarProps): ReactNode {
	const { device, set } = useDevice();
	const { size: width, edge } = useDragSize(device.sidebar_width, SIDEBAR_BOUNDS, (width) => set({ sidebar_width: width }));
	return (
		<aside style={{ width }} className="relative flex h-full shrink-0 flex-col border-e border-sidebar-border bg-sidebar text-sidebar-foreground">
			{edge}
			<SidebarBody {...props} />
		</aside>
	);
}

/** The sidebar as a drawer over the page, swiped in from its left edge; open while `open` says, closed as `onHide` asks. */
export function SidebarDrawer(props: SidebarProps & { readonly open: boolean; readonly onOpenChange: (open: boolean) => void }): ReactNode {
	return (
		<Drawer open={props.open} onOpenChange={props.onOpenChange}>
			<DrawerSwipeArea />
			<DrawerPopup className="bg-sidebar text-sidebar-foreground">
				<DrawerTitle className="sr-only">Threads</DrawerTitle>
				<SidebarBody route={props.route} onHide={props.onHide} onOverlay={props.onOverlay} />
			</DrawerPopup>
		</Drawer>
	);
}

/** What the sidebar holds, beside the chat or in a drawer. */
function SidebarBody(props: SidebarProps): ReactNode {
	const [query, setQuery] = useState("");
	const [folder, setFolder] = useState<string | undefined>(undefined);
	const rows = useThreads();
	const projects = projectsOf(rows ?? []);
	const chosen = projects.find((project) => project.folder === folder);
	const now = useNow(30_000);
	const shown = matchingRows(rows ?? [], query).filter((row) => folder === undefined || projectOf(row)?.folder === folder);
	// The thread shown is marked, or where a sub-thread is shown, the one whose card stands for it.
	const current = props.route.place === "thread" ? lineOf(rows ?? [], props.route.thread) : [];
	return (
		<>
			<div className="flex h-[var(--topbar-height)] shrink-0 items-center gap-1.5 px-2">
				<span className="min-w-0 flex-1 ps-2 text-sm font-semibold tracking-tight">Octoii</span>
				<IconButton label="Hide sidebar" shortcut="⌘B" onClick={props.onHide}>
					<PanelLeft className="size-4" />
				</IconButton>
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
			{chosen === undefined ? null : <Filtered project={chosen} onClear={() => setFolder(undefined)} />}
			<div className="min-h-0 flex-1 overflow-y-auto px-2 scrollbar-none">
				{rows === undefined ? null : shown.length === 0 ? (
					<p className="py-6 text-center text-xs text-muted-foreground/60">{query === "" ? "No threads yet" : "No threads found"}</p>
				) : (
					<ThreadList rows={shown} all={rows} current={current} now={now} onFilter={setFolder} />
				)}
			</div>
			<div className="flex items-center gap-1 px-2 pt-1 pb-2">
				<IconButton label="Settings" size="icon" onClick={() => props.onOverlay({ kind: "settings", section: "general" })}>
					<Settings className="size-4" />
				</IconButton>
			</div>
		</>
	);
}

/** The project the list shows the threads of alone, by its monogram and name, and the button that shows every project's again. */
function Filtered(props: { readonly project: Project; readonly onClear: () => void }): ReactNode {
	return (
		<div className="px-2 pb-2">
			<span className="flex h-control-sm items-center gap-1.5 rounded-md bg-sidebar-row-active ps-2 pe-1 text-xs shadow-xs/5">
				<ProjectMark project={props.project} />
				<span className="min-w-0 flex-1 truncate font-medium">{props.project.name}</span>
				<IconButton label="Show every project" size="icon-micro" onClick={props.onClear}>
					<X />
				</IconButton>
			</span>
		</div>
	);
}

/**
 * The threads pinned, then those open to the person under a hairline where some are pinned, those that work under
 * their heading, and at the foot, folded, those snoozed and the earlier.
 */
function ThreadList(props: {
	readonly rows: readonly Listed[];
	readonly all: readonly Listed[];
	readonly current: readonly string[];
	readonly now: number;
	readonly onFilter: (folder: string) => void;
}): ReactNode {
	// How a thread stands, and how many sub-threads it has, are read from every thread: a search that hides a sub-thread
	// hides nothing of how its parent stands.
	const standingOf = standingsOf(props.all);
	const delegated = subThreadsBy(props.all);
	const { pinned, open, working, snoozed, earlier } = rowsBySection(props.rows, props.now, standingOf);
	// A thread that comes into a section after the list was first drawn — made, or gone on to work — fades in there.
	const sections = { pinned, open, working, snoozed, earlier };
	const arrived = useArrived(Object.entries(sections).flatMap(([section, rows]) => rows.map((row) => `${section}:${row.id}`)));
	const rowProps = (row: Listed, section: keyof typeof sections) => ({
		row,
		standing: standingOf(row),
		subThreads: delegated.get(row.id)?.length ?? 0,
		current: props.current.includes(row.id),
		now: props.now,
		onFilter: props.onFilter,
		fades: arrived(`${section}:${row.id}`),
	});
	const card =
		(section: keyof typeof sections) =>
		(row: Listed): ReactNode => <ThreadCard key={row.id} {...rowProps(row, section)} />;
	return (
		<div className="flex min-h-full flex-col">
			<Shelf title="Pinned" count={pinned.length} icon={<Pin className="size-3.5" />}>
				{pinned.map(card("pinned"))}
			</Shelf>
			{open.length === 0 ? null : (
				<ul className={cn("flex flex-col pb-1", pinned.length > 0 && "mt-1 border-t border-sidebar-border pt-1")}>{open.map(card("open"))}</ul>
			)}
			<Shelf title="Working" count={working.length} icon={<Activity className="size-3.5" />}>
				{working.map(card("working"))}
			</Shelf>
			<div className="mt-auto pt-3">
				<Shelf title="Snoozed" count={snoozed.length} icon={<AlarmClock className="size-3.5" />} folded>
					{snoozed.map(card("snoozed"))}
				</Shelf>
				<Shelf title="Earlier" count={earlier.length} icon={<History className="size-3.5" />} folded>
					{earlier.map((row) => (
						<ThreadLine key={row.id} {...rowProps(row, "earlier")} />
					))}
				</Shelf>
			</div>
		</div>
	);
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

/** The project filter: all projects, or one, which the list names over it where it is chosen. */
function ProjectFilter(props: {
	readonly projects: readonly Project[];
	readonly chosen: string | undefined;
	readonly onChoose: (folder: string | undefined) => void;
}): ReactNode {
	return (
		<Menu>
			<MenuTrigger render={<IconButton label="Filter by project" />}>
				<ListFilter />
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
							<ProjectMark project={project} />
							<MenuItemLabel title={project.folder}>{project.name}</MenuItemLabel>
						</MenuRadioItem>
					))}
				</MenuRadioGroup>
			</MenuPopup>
		</Menu>
	);
}
