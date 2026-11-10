/**
 * The sidebar: the brand, and on its right the frame's button that hides it; search, a project filter and a new thread,
 * the project filtered on named under them where one is; the threads of every project in one list, each card naming its
 * project — those pinned atop, then the active, what asks the person first — and at its foot the shelves, each folding
 * under its heading and its count: those that work, those snoozed, and the settled, a line each, a page of them at a
 * time — a folded shelf still showing the thread that is shown — those archived not at all; a sub-thread on its
 * parent's card, by their count and how they stand; and settings at its foot.
 */
import { type ReactNode, useRef, useState } from "react";
import type { Listed } from "@octoii-works/octoii-client";
import { useThreads } from "@octoii-works/octoii-client/react";
import { ChevronDown, FolderOpen, ListFilter, Search, Settings, SquarePen, X } from "lucide-react";
import type { Overlay, Route } from "../../core/route.ts";
import { lineOf, matchingRows, type Project, projectOf, projectsOf, rowsBySection, standingsOf, subThreadsBy } from "../../core/threads.ts";
import { vendorOfReference } from "../../core/vendors.ts";
import { useDirectory } from "../composer/directory.ts";
import { useArrived } from "../effects/arrived.ts";
import { useGlide } from "../effects/glide.ts";
import { useNow } from "../effects/now.ts";
import { HideSidebar } from "../frame/frame.tsx";
import { go } from "../state/navigation.ts";
import { IconButton } from "../ui/button.tsx";
import { FoldChevron } from "../ui/collapsible.tsx";
import { Input } from "../ui/input.tsx";
import { Menu, MenuItemLabel, MenuPopup, MenuRadioGroup, MenuRadioItem, MenuSeparator, MenuTrigger } from "../ui/menu.tsx";
import { ProjectMark } from "../files/project-mark.tsx";
import { ThreadCard, ThreadLine } from "./thread-row.tsx";

/** What the sidebar is given: the place shown, and how it opens settings over the page. */
export type SidebarProps = {
	readonly route: Route;
	readonly onOverlay: (over: Overlay) => void;
};

/** The sidebar, as the frame stands it: beside the page, or in a drawer over it. */
export function Sidebar(props: SidebarProps): ReactNode {
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
				<span className="min-w-0 flex-1 ps-2 text-ui font-semibold tracking-tight">Octoii</span>
				<HideSidebar />
			</div>
			<div className="flex items-center gap-1 px-2 pb-2">
				<label className="group flex h-control min-w-0 flex-1 items-center gap-2 rounded-md px-2 focus-within:ring-1 focus-within:ring-ring hover:bg-accent">
					<Search className="size-4 shrink-0 text-muted-foreground" />
					<Input
						type="search"
						variant="bare"
						aria-label="Search threads"
						placeholder="Search"
						value={query}
						onValueChange={setQuery}
						className="font-medium placeholder:text-muted-foreground"
					/>
					{query === "" ? null : (
						<button type="button" aria-label="Clear the search" className="text-muted-foreground hover:text-foreground" onClick={() => setQuery("")}>
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
					<p className="py-6 text-center text-xs text-faint-foreground">{query === "" ? "No threads yet" : "No threads found"}</p>
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
			<span className="flex h-control-sm items-center gap-1.5 rounded-md bg-selected ps-2 pe-1 text-xs">
				<ProjectMark project={props.project} />
				<span className="min-w-0 flex-1 truncate font-medium">{props.project.name}</span>
				<IconButton label="Show every project" size="icon-micro" onClick={props.onClear}>
					<X />
				</IconButton>
			</span>
		</div>
	);
}

/** How many settled threads the list shows at first, and how many more each time the person asks for more. */
const SETTLED_FIRST = 10;
const SETTLED_PAGE = 25;

/**
 * The threads pinned, then the active, with no heading; and at the foot the shelves of those that work, those snoozed
 * — folded at first — and the settled.
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
	const directory = useDirectory();
	const { pinned, active, working, snoozed, settled } = rowsBySection(props.rows, props.now, standingOf);
	const sections = { pinned, active, working, snoozed, settled };
	const [settledShown, setSettledShown] = useState(SETTLED_FIRST);
	// A thread that comes into the list after it was first drawn — made, or back from the archive — fades in; one that
	// moves, to another section as it goes on to work or within its own, glides there from where it stood.
	const arrived = useArrived(props.rows.map((row) => row.id));
	const list = useRef<HTMLDivElement>(null);
	useGlide(
		list,
		Object.entries(sections)
			.flatMap(([section, rows]) => rows.map((row) => `${section}:${row.id}`))
			.join(" "),
	);
	const rowProps = (row: Listed) => ({
		row,
		standing: standingOf(row),
		subThreads: delegated.get(row.id)?.length ?? 0,
		vendor: row.manifest.model === undefined ? undefined : vendorOfReference(directory, row.manifest.model),
		current: props.current.includes(row.id),
		now: props.now,
		onFilter: props.onFilter,
		fades: arrived(row.id),
	});
	const isCurrent = (row: Listed): boolean => props.current.includes(row.id);
	const card = (row: Listed): ReactNode => <ThreadCard key={row.id} {...rowProps(row)} />;
	const line = (row: Listed): ReactNode => <ThreadLine key={row.id} {...rowProps(row)} />;
	const more = settled.length - settledShown;
	return (
		<div ref={list} className="relative flex min-h-full flex-col">
			<ul className="flex flex-col">
				{pinned.map(card)}
				{active.map(card)}
			</ul>
			<div className="mt-auto flex flex-col pt-3">
				<Shelf title="Working" rows={working} isCurrent={isCurrent} draw={card} />
				<Shelf title="Snoozed" rows={snoozed} isCurrent={isCurrent} draw={card} folded />
				<Shelf
					title="Settled"
					rows={settled.slice(0, settledShown)}
					count={settled.length}
					isCurrent={isCurrent}
					draw={line}
					more={more > 0 ? <ShowMore count={Math.min(more, SETTLED_PAGE)} onMore={() => setSettledShown(settledShown + SETTLED_PAGE)} /> : null}
				/>
			</div>
		</div>
	);
}

/**
 * A shelf: its heading, the count of its rows and a chevron that folds it, folded at first where `folded` says; folded,
 * still the row of the thread shown, where it is one of them; nothing where it holds no rows.
 */
function Shelf(props: {
	readonly title: string;
	readonly rows: readonly Listed[];
	/** How many rows it holds in all, where it shows a page of them. */
	readonly count?: number;
	readonly isCurrent: (row: Listed) => boolean;
	readonly draw: (row: Listed) => ReactNode;
	readonly folded?: boolean;
	readonly more?: ReactNode;
}): ReactNode {
	const [open, setOpen] = useState(props.folded !== true);
	const count = props.count ?? props.rows.length;
	if (count === 0) return null;
	return (
		<section className="pb-1">
			<button
				type="button"
				aria-expanded={open}
				data-panel-open={open ? "" : undefined}
				onClick={() => setOpen(!open)}
				className="group/fold flex h-control w-full cursor-default items-center gap-2 rounded-md px-2.5 text-ui text-muted-foreground hover:text-foreground"
			>
				<span className="truncate">{props.title}</span>
				<span className="flex-1" />
				<span className="tabular-nums">{count}</span>
				<FoldChevron />
			</button>
			<ul className="flex flex-col">
				{(open ? props.rows : props.rows.filter(props.isCurrent)).map(props.draw)}
				{open ? props.more : null}
			</ul>
		</section>
	);
}

/** What shows more of a shelf's rows: how many more. */
function ShowMore(props: { readonly count: number; readonly onMore: () => void }): ReactNode {
	return (
		<li>
			<button
				type="button"
				onClick={props.onMore}
				className="flex h-control w-full cursor-pointer items-center gap-2 rounded-md px-2.5 text-ui text-muted-foreground hover:bg-accent hover:text-foreground"
			>
				<ChevronDown className="size-4 shrink-0" />
				{`Show ${String(props.count)} more`}
			</button>
		</li>
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
