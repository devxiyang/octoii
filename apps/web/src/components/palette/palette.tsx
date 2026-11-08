/**
 * The command palette, ⌘K: one field that finds actions, projects and threads; with nothing typed, the actions, each
 * with its shortcut, and the recent threads, each over its project and beside how long ago it began. Arrows move,
 * Enter takes, Escape closes.
 */
import { type ReactNode, useState } from "react";
import { useThreads } from "@octoii-works/octoii-client/react";
import { Inbox, MessageSquare, Settings, SquarePen } from "lucide-react";
import type { Route } from "../../core/route.ts";
import { activeAt, projectOf, projectsOf, threadTitle } from "../../core/threads.ts";
import { shortAgo } from "../../core/time.ts";
import { useNow } from "../effects/now.ts";
import { Command, CommandDialog, CommandGroup, CommandHints, CommandItem, CommandList, CommandSearch } from "../ui/command.tsx";
import { Monogram } from "../ui/monogram.tsx";

/** One thing the palette finds: its id, its title, its project under it, what it says on the right, its icon, and where it goes. */
type Found = {
	readonly id: string;
	readonly title: string;
	readonly project?: string;
	readonly aside?: string;
	readonly icon: ReactNode;
	readonly to: Route;
};

/** The palette, open or closed, going where the person takes it. */
export function Palette(props: { readonly isOpen: boolean; readonly onClose: () => void; readonly onGo: (route: Route) => void }): ReactNode {
	const [query, setQuery] = useState("");
	const rows = useThreads() ?? [];
	const now = useNow(30_000);
	const actions: readonly Found[] = [
		{ id: "new", title: "New thread", aside: "⌘N", icon: <SquarePen />, to: { place: "new" } },
		{ id: "inbox", title: "Go to the inbox", icon: <Inbox />, to: { place: "home" } },
		{ id: "settings", title: "Open settings", icon: <Settings />, to: { place: "home", over: { kind: "settings", section: "general" } } },
	];
	const projectItems: readonly Found[] = projectsOf(rows).map((project) => ({
		id: `project:${project.folder}`,
		title: `New thread in ${project.name}`,
		icon: <Monogram name={project.name} />,
		to: { place: "new", project: project.folder },
	}));
	const threads: readonly Found[] = rows.slice(0, query === "" ? 12 : 50).map((row) => ({
		id: row.id,
		title: threadTitle(row),
		project: projectOf(row)?.name ?? "No project",
		aside: `${shortAgo(now - activeAt(row))} ago`,
		icon: <MessageSquare />,
		to: { place: "thread", thread: row.id },
	}));
	const take = (found: Found): void => {
		props.onClose();
		setQuery("");
		props.onGo(found.to);
	};
	const groups: readonly Group[] = [
		{ title: "Actions", items: actions },
		{ title: "Projects", items: query === "" ? [] : projectItems },
		{ title: query === "" ? "Recent threads" : "Threads", items: threads },
	].filter((group) => group.items.length > 0);
	return (
		<CommandDialog open={props.isOpen} onOpenChange={(open) => (open ? undefined : props.onClose())} title="Command palette">
			<Command items={groups} value={query} onValueChange={setQuery} itemToStringValue={(item: Found) => `${item.title} ${item.project ?? ""}`}>
				<CommandSearch aria-label="Search" placeholder="Search commands, projects, and threads..." />
				<CommandList empty="Nothing found">
					{(group: Group) => (
						<CommandGroup key={group.title} title={group.title} items={group.items}>
							{(item: Found) => <FoundRow key={item.id} item={item} onTake={take} />}
						</CommandGroup>
					)}
				</CommandList>
				<CommandHints hints={HINTS} />
			</Command>
		</CommandDialog>
	);
}

/** A group of what the palette finds: its title, and what it holds. */
type Group = { readonly title: string; readonly items: readonly Found[] };

/** The hints of the palette's keys. */
const HINTS = [
	{ keys: ["↑", "↓"], label: "Navigate" },
	{ keys: ["Enter"], label: "Select" },
	{ keys: ["Esc"], label: "Close" },
] as const;

/** One thing found: its icon, its title over its project, and what it says on the right. */
function FoundRow(props: { readonly item: Found; readonly onTake: (item: Found) => void }): ReactNode {
	const { item } = props;
	return (
		<CommandItem value={item} onClick={() => props.onTake(item)} className="items-start py-1.5">
			<span className="flex h-5 w-4 items-center text-muted-foreground [&>svg]:size-4">{item.icon}</span>
			<span className="min-w-0 flex-1">
				<span className="block truncate">{item.title}</span>
				{item.project === undefined ? null : (
					<span className="mt-0.5 flex items-center gap-1.5 text-xs text-muted-foreground">
						<Monogram name={item.project} />
						<span className="truncate">{item.project}</span>
					</span>
				)}
			</span>
			{item.aside === undefined ? null : <span className="shrink-0 pt-0.5 text-xs text-muted-foreground">{item.aside}</span>}
		</CommandItem>
	);
}
