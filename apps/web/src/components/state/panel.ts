/**
 * The panel, one for the app: where it stands — hidden, beside the page's column, or filling the column's place, as
 * the frame lays it out — and for each thread what it shows: the views of the thread's open in it, in order, and the
 * tab shown; the file its Files view reads, and the folders open in its tree; the changes its Diff view shows — so a
 * thread finds its own as the person comes back to it. Its terminals and its pages in the browser are the node's, a
 * tab each after the views, never kept here. Anything that names a path opens it there: a file chosen in the tree or
 * named in a message is read, a folder a search finds or a message names is opened in the tree. A store of the page's,
 * outside any component, as the window's place is.
 */
import { useSyncExternalStore } from "react";
import type { ChangesScope } from "@octoii-works/octoii-client";
import { childPath, crumbsOf, isWholePath } from "../../core/files.ts";

/** A view of a thread's the panel opens: its files, or the changes in its repository. */
export type View = "files" | "diff";

/** What a tab of the panel shows, by its key: a view; one of the thread's terminals, `terminal:` and its id; or one of its pages, `page:` and its id. */
export type SurfaceKey = View | `terminal:${string}` | `page:${string}`;

/**
 * What a thread's panel shows: its views open, in order, and the tab shown; the file read, and the folders open; the
 * changes the Diff view shows, its repository's own choice where none was made.
 */
export type ThreadPanel = {
	readonly views: readonly View[];
	readonly shown: SurfaceKey | undefined;
	readonly file?: string;
	readonly folders: ReadonlySet<string>;
	readonly scope: ChangesScope | undefined;
};

/** Where the panel stands: hidden, beside the page's column, or filling the column's place. */
export type PanelPlace = "hidden" | "beside" | "full";

/** The panel: where it stands, and each thread's. */
type Panel = { readonly place: PanelPlace; readonly threads: ReadonlyMap<string, ThreadPanel> };

/** Where a thread's panel begins: its files open, no file read, no folder open. */
const FRESH: ThreadPanel = { views: ["files"], shown: undefined, folders: new Set(), scope: undefined };

let panel: Panel = { place: "hidden", threads: new Map() };
const listeners = new Set<() => void>();

function change(next: Panel): void {
	panel = next;
	for (const listener of [...listeners]) listener();
}

function subscribe(listener: () => void): () => void {
	listeners.add(listener);
	return () => listeners.delete(listener);
}

/** The panel standing at `place`, with `thread`'s changed by `changed`. */
function changeThread(thread: string, place: PanelPlace, changed: (shows: ThreadPanel) => ThreadPanel): void {
	change({ place, threads: new Map(panel.threads).set(thread, changed(panel.threads.get(thread) ?? FRESH)) });
}

/** Where the panel stands once it shows something: where it stood, beside the page's column where it was hidden. */
function shownPlace(): PanelPlace {
	return panel.place === "hidden" ? "beside" : panel.place;
}

/** The key of the tab of the terminal `id`. */
export function terminalKey(id: string): SurfaceKey {
	return `terminal:${id}`;
}

/** The key of the tab of the page `id`. */
export function pageKey(id: string): SurfaceKey {
	return `page:${id}`;
}

/** Whether `key` is a view's, not a terminal's nor a page's. */
function isView(key: SurfaceKey): key is View {
	return key === "files" || key === "diff";
}

/** `place` with the tab of `key` shown: a view opened, where it was not. */
function withShown(place: ThreadPanel, key: SurfaceKey): ThreadPanel {
	if (!isView(key) || place.views.includes(key)) return { ...place, shown: key };
	return { ...place, views: [...place.views, key], shown: key };
}

/** Where the panel stands, read again as it changes. */
export function usePanelPlace(): PanelPlace {
	return useSyncExternalStore(subscribe, () => panel.place);
}

/** What `thread`'s panel shows, read again as it changes. */
export function useThreadPanel(thread: string): ThreadPanel {
	return useSyncExternalStore(subscribe, () => panel.threads.get(thread) ?? FRESH);
}

/** Stands the panel at `place`: hidden, beside the page's column, or filling its place. */
export function placePanel(place: PanelPlace): void {
	change({ ...panel, place });
}

/** Shows the panel with the tab of `key` shown in it for `thread`: a view opened, where it was not. */
export function showSurface(thread: string, key: SurfaceKey): void {
	changeThread(thread, shownPlace(), (place) => withShown(place, key));
}

/**
 * Closes the tab of `key` in `thread`'s panel — a view taken out; a terminal's or a page's, the node's to take — and shows `next`,
 * the tab beside it, where it was the one shown.
 */
export function closeSurface(thread: string, key: SurfaceKey, next: SurfaceKey | undefined): void {
	changeThread(thread, panel.place, (place) => ({
		...place,
		views: place.views.filter((view) => view !== key),
		shown: place.shown === key ? next : place.shown,
	}));
}

/** Shows the panel with the file at `path` read in it, for `thread`. */
export function openFile(thread: string, path: string): void {
	changeThread(thread, shownPlace(), (place) => ({ ...withShown(place, "files"), file: path }));
}

/** Puts away the file read in `thread`'s Files view, its tree shown in its place. */
export function closeFile(thread: string): void {
	changeThread(thread, panel.place, (place) => {
		const { file: _closed, ...rest } = place;
		return rest;
	});
}

/** Shows the changes `scope` asks for in `thread`'s Diff view. */
export function showChanges(thread: string, scope: ChangesScope): void {
	changeThread(thread, panel.place, (place) => ({ ...place, scope }));
}

/** Opens the folder at `path` in `thread`'s tree, or closes it. */
export function toggleFolder(thread: string, path: string): void {
	changeThread(thread, panel.place, (place) => {
		const folders = new Set(place.folders);
		if (!folders.delete(path)) folders.add(path);
		return { ...place, folders };
	});
}

/**
 * Opens a path a message of `thread`'s names, from the thread's folder `root` or whole: a folder — its path ending in a
 * slash, as a mention writes one — opened in the tree, a file read.
 */
export function openPath(thread: string, root: string, named: string): void {
	const bare = named.replace(/\/$/, "");
	const path = isWholePath(bare) ? bare : childPath(root, bare);
	if (named.endsWith("/")) revealFolder(thread, root, path);
	else openFile(thread, path);
}

/** Shows the panel with the folder at `path` open in `thread`'s tree, and every folder on the way to it from `root`. */
export function revealFolder(thread: string, root: string, path: string): void {
	const way = crumbsOf(root, path).map((crumb) => crumb.path);
	changeThread(thread, shownPlace(), (place) => ({ ...withShown(place, "files"), folders: new Set([...place.folders, ...way]) }));
}
