/**
 * The panel's tabs, in the place the frame gives the panel: a bar of them, which the arrow keys walk — the thread's
 * views open, its files and its changes, then each of its terminals, named by the title its program set,
 * then each of its pages in the browser, named by its title — each as wide as its name, narrower where the bar runs
 * out of room; `+` to open a terminal, a page or a view, by its letter while the menu is open; the tab chosen shown
 * below, each other kept as it was while it is hidden, its terminal or page no longer followed; and the frame's own
 * buttons — at the bar's left the one that shows the sidebar, where the panel stands at the page's left edge, at its
 * right those that have the panel fill the page's column and that hide it. A view's tab is named by what it
 * shows, the Files view's by its file and that file's icon. A tab closes from its cross: a view's is taken out, a
 * terminal's closes the terminal, a page's the page.
 */
import { Activity, type KeyboardEvent, type ReactNode, useState } from "react";
import { Tabs } from "@base-ui/react/tabs";
import type { PageListed, TerminalListed } from "@octoii-works/octoii-client";
import { useClient } from "@octoii-works/octoii-client/react";
import { FileDiff, Files, Globe, Plus, SquareTerminal, X } from "lucide-react";
import { pageName } from "../../core/browser.ts";
import { nameOf } from "../../core/files.ts";
import { terminalName } from "../../core/terminal.ts";
import { closeSurface, pageKey, type SurfaceKey, showSurface, terminalKey, type ThreadPanel, useThreadPanel, type View } from "../state/panel.ts";
import { PathIcon } from "../files/path-icon.tsx";
import { FillPanel, HidePanel, ShowSidebarFromPanel } from "../frame/frame.tsx";
import { Button, IconButton } from "../ui/button.tsx";
import { Menu, MenuItem, MenuItemLabel, MenuPopup, MenuShortcut, MenuTrigger } from "../ui/menu.tsx";
import { BrowserPane } from "../browser/browser-pane.tsx";
import { DiffSurface } from "../diff/diff-surface.tsx";
import { FilesSurface } from "../files/files-surface.tsx";
import { TerminalPane } from "../terminal/terminal-pane.tsx";
import { failed } from "../state/notices.ts";

/** The size a terminal opens at, before the view that opens it sizes it to its room. */
const OPENED_SIZE = { rows: 24, cols: 80 } as const;

/** The size a page opens at, before the view that opens it lays it out at its room. */
const OPENED_PAGE = { width: 1280, height: 800, scale: 1 } as const;

/** What the panel is given: its thread, the folder it works in — none where it works in none — its terminals and its pages. */
export type RightPanelProps = {
	readonly thread: string;
	readonly folder: string | undefined;
	readonly terminals: readonly TerminalListed[];
	readonly pages: readonly PageListed[];
	/** Where the thread's turns stand, which its changes are read again at. */
	readonly revision: string;
};

/** What a tab shows: a view of the thread's, one of its terminals, or one of its pages. */
type Shows = { readonly view: View } | { readonly terminal: string } | { readonly page: PageListed };

/** A tab: what it shows, and its key, its icon and its name. */
type Tab = { readonly key: SurfaceKey; readonly icon: ReactNode; readonly label: string; readonly shows: Shows };

/** What `+` opens: its name, icon and letter, and how. */
type Opening = { readonly label: string; readonly icon: typeof Files; readonly letter: string; readonly open: () => void };

/** The panel. */
export function RightPanel(props: RightPanelProps): ReactNode {
	const client = useClient();
	const place = useThreadPanel(props.thread);
	const tabs: readonly Tab[] = [
		...place.views.map((view) => viewTab(view, place)),
		...props.terminals.map((terminal): Tab => ({
			key: terminalKey(terminal.id),
			icon: <SquareTerminal />,
			label: terminalName(terminal),
			shows: { terminal: terminal.id },
		})),
		...props.pages.map((page): Tab => ({ key: pageKey(page.id), icon: <Globe />, label: pageName(page), shows: { page } })),
	];
	const shown = tabs.find((tab) => tab.key === place.shown) ?? tabs[0];
	const openings: readonly Opening[] = [
		{
			label: "Terminal",
			icon: SquareTerminal,
			letter: "T",
			open: () => {
				client.openTerminal(props.thread, OPENED_SIZE).then(
					(id) => showSurface(props.thread, terminalKey(id)),
					(error: unknown) => failed("A terminal could not be opened", error),
				);
			},
		},
		{
			label: "Browser",
			icon: Globe,
			letter: "B",
			open: () => {
				client.openPage(props.thread, undefined, OPENED_PAGE).then(
					(id) => showSurface(props.thread, pageKey(id)),
					(error: unknown) => failed("A page could not be opened", error),
				);
			},
		},
		{ label: "Files", icon: Files, letter: "F", open: () => showSurface(props.thread, "files") },
		{ label: "Diff", icon: FileDiff, letter: "D", open: () => showSurface(props.thread, "diff") },
	];
	const close = (tab: Tab, index: number): void => {
		closeSurface(props.thread, tab.key, (tabs[index - 1] ?? tabs[index + 1])?.key);
		if ("terminal" in tab.shows) client.closeTerminal(tab.shows.terminal).catch((error: unknown) => failed("The terminal could not be closed", error));
		if ("page" in tab.shows) client.closePage(tab.shows.page.id).catch((error: unknown) => failed("The page could not be closed", error));
	};
	return (
		<Tabs.Root value={shown?.key ?? null} onValueChange={(key: SurfaceKey) => showSurface(props.thread, key)} className="flex min-h-0 flex-1 flex-col">
			<div className="flex h-[var(--topbar-height)] shrink-0 items-center gap-1 px-2">
				<ShowSidebarFromPanel />
				{/* Positioned, as the list measures where a tab stands in it to keep the one chosen in view. */}
				<Tabs.List aria-label="The panel's tabs" className="relative flex min-w-0 items-center gap-1 overflow-x-auto scrollbar-none">
					{tabs.map((tab, index) => (
						<TabButton key={tab.key} tab={tab} onClose={() => close(tab, index)} />
					))}
				</Tabs.List>
				<OpenMenu openings={openings} />
				<span className="flex-1" />
				<FillPanel />
				<HidePanel />
			</div>
			{shown === undefined ? <Empty openings={openings} /> : null}
			{tabs.map((tab) => (
				<Tabs.Panel key={tab.key} value={tab.key} keepMounted className="flex min-h-0 flex-1 flex-col">
					<Activity mode={tab === shown ? "visible" : "hidden"}>
						<Shown shows={tab.shows} thread={props.thread} folder={props.folder} revision={props.revision} />
					</Activity>
				</Tabs.Panel>
			))}
		</Tabs.Root>
	);
}

/** The tab of a view of a thread's: its files, named by the file read; or its changes. */
function viewTab(view: View, place: ThreadPanel): Tab {
	switch (view) {
		case "files":
			return {
				key: view,
				icon: place.file === undefined ? <Files /> : <PathIcon path={place.file} kind="file" />,
				label: place.file === undefined ? "Files" : nameOf(place.file),
				shows: { view },
			};
		case "diff":
			return { key: view, icon: <FileDiff />, label: "Diff", shows: { view } };
	}
}

/** A tab's surface. */
function Shown(props: { readonly shows: Shows; readonly thread: string; readonly folder: string | undefined; readonly revision: string }): ReactNode {
	if ("terminal" in props.shows) return <TerminalPane terminal={props.shows.terminal} />;
	if ("page" in props.shows) return <BrowserPane page={props.shows.page} />;
	switch (props.shows.view) {
		case "files":
			return <FilesSurface thread={props.thread} folder={props.folder} />;
		case "diff":
			return <DiffSurface thread={props.thread} folder={props.folder} revision={props.revision} />;
	}
}

/**
 * A tab: its icon and name, shaded while it is the one chosen, as wide as its name and narrower, its name cut short,
 * where the bar runs out of room; its cross shown as it is pointed at or focused, and always, larger, where a finger
 * points.
 */
function TabButton(props: { readonly tab: Tab; readonly onClose: () => void }): ReactNode {
	const { icon, label } = props.tab;
	return (
		<span className="group/tab flex h-control-sm max-w-48 min-w-30 items-center rounded-md text-ui text-muted-foreground hover:bg-accent has-data-active:bg-accent has-data-active:text-foreground">
			<Tabs.Tab
				value={props.tab.key}
				title={label}
				className="flex h-full min-w-0 cursor-pointer items-center gap-1.5 rounded-md pr-1 pl-2 outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-inset [&>svg]:size-3.5 [&>svg]:shrink-0"
			>
				{icon}
				<span className="truncate">{label}</span>
			</Tabs.Tab>
			<button
				type="button"
				aria-label={`Close ${label}`}
				onClick={props.onClose}
				className="mr-1 flex size-control-2xs shrink-0 cursor-pointer items-center justify-center rounded-sm opacity-0 group-focus-within/tab:opacity-100 group-hover/tab:opacity-100 hover:bg-accent pointer-coarse:size-control-xs pointer-coarse:opacity-100"
			>
				<X className="size-3" />
			</button>
		</span>
	);
}

/** `+`: a menu of what opens, each also opened by its letter while the menu is open. */
function OpenMenu(props: { readonly openings: readonly Opening[] }): ReactNode {
	const [open, setOpen] = useState(false);
	const onKeyDown = (event: KeyboardEvent): void => {
		const opening = openingOf(props.openings, event);
		if (opening === undefined) return;
		event.preventDefault();
		event.stopPropagation();
		setOpen(false);
		opening.open();
	};
	return (
		<Menu open={open} onOpenChange={setOpen}>
			<MenuTrigger render={<IconButton label="New tab" />}>
				<Plus />
			</MenuTrigger>
			<MenuPopup className="w-48" onKeyDownCapture={onKeyDown}>
				{props.openings.map((opening) => (
					<MenuItem key={opening.label} onClick={opening.open} aria-keyshortcuts={opening.letter}>
						<opening.icon />
						<MenuItemLabel>{opening.label}</MenuItemLabel>
						<MenuShortcut>{opening.letter}</MenuShortcut>
					</MenuItem>
				))}
			</MenuPopup>
		</Menu>
	);
}

/** The opening a key pressed alone names by its letter, where one does. */
function openingOf(openings: readonly Opening[], event: KeyboardEvent): Opening | undefined {
	if (event.metaKey || event.ctrlKey || event.altKey || event.nativeEvent.isComposing) return undefined;
	return openings.find((opening) => opening.letter.toLowerCase() === event.key.toLowerCase());
}

/** A panel with no tab: what `+` opens, offered at once. */
function Empty(props: { readonly openings: readonly Opening[] }): ReactNode {
	return (
		<div className="flex flex-1 flex-col items-center justify-center gap-3 px-4 text-ui text-muted-foreground">
			Nothing is open.
			<div className="flex flex-wrap justify-center gap-2">
				{props.openings.map((opening) => (
					<Button key={opening.label} variant="outline" size="sm" onClick={opening.open}>
						<opening.icon />
						{opening.label}
					</Button>
				))}
			</div>
		</div>
	);
}
