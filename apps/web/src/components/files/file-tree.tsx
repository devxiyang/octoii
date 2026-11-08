/**
 * The tree of a folder of the machine's: its names, folders first, a page at a time, each folder opening below its row
 * as it is clicked; each by its icon, a file's in its language's hue; the file chosen shaded; the names its repository's
 * ignore files leave out faded, as the node marks them. A search over the folder's paths shows what it finds instead, best first.
 */
import type { ReactNode } from "react";
import type { FolderEntry } from "@octoii-works/octoii-client";
import { ChevronRight, Ellipsis } from "lucide-react";
import { childPath, folderOf, nameOf, shownEntries } from "../../core/files.ts";
import { useDebounced } from "../effects/debounced.ts";
import { useFolder } from "../effects/folder.ts";
import { useOutcome } from "../effects/read.ts";
import { type ThreadPanel, openFile, toggleFolder } from "../state/panel.ts";
import { PathIcon } from "./path-icon.tsx";

/** What every row of the tree is given: its thread, and what the thread's surface shows — its file and open folders. */
export type TreeProps = { readonly thread: string; readonly place: ThreadPanel };

/** The names in the folder `path`, `depth` deep in the tree. */
export function FolderRows(props: TreeProps & { readonly path: string; readonly depth: number }): ReactNode {
	const folder = useFolder(props.path);
	if (folder === undefined) return <TreeNote depth={props.depth}>Reading…</TreeNote>;
	if (!("entries" in folder)) return <TreeNote depth={props.depth}>{folder.failure}</TreeNote>;
	return (
		<>
			{shownEntries(folder.entries).map((entry) => (
				<EntryRows key={entry.name} {...props} entry={entry} />
			))}
			{folder.readMore === undefined ? null : <TreeRow depth={props.depth} icon={<Ellipsis />} name="Show more" onPress={folder.readMore} />}
			{folder.failure === undefined ? null : <TreeNote depth={props.depth}>{folder.failure}</TreeNote>}
		</>
	);
}

/** A name of the folder `path`: a file's row, or a folder's, its names below it while it is open. */
function EntryRows(props: TreeProps & { readonly path: string; readonly depth: number; readonly entry: FolderEntry }): ReactNode {
	const { entry, depth } = props;
	const path = childPath(props.path, entry.name);
	if (entry.kind !== "directory") {
		return (
			<TreeRow
				depth={depth}
				chosen={path === props.place.file}
				faded={entry.ignored}
				icon={<PathIcon path={entry.name} kind="file" />}
				name={entry.name}
				onPress={() => openFile(props.thread, path)}
			/>
		);
	}
	const open = props.place.folders.has(path);
	return (
		<>
			<TreeRow
				depth={depth}
				open={open}
				faded={entry.ignored}
				icon={<ChevronRight className="transition-transform duration-150 group-aria-expanded/tree-row:rotate-90 motion-reduce:transition-none" />}
				name={entry.name}
				onPress={() => toggleFolder(props.thread, path)}
			/>
			{open ? <FolderRows {...props} path={path} depth={depth + 1} /> : null}
		</>
	);
}

/** The files and folders under `root` whose paths hold `query`, best first: a file read as it is clicked, a folder shown in the tree. */
export function FoundRows(props: {
	readonly thread: string;
	readonly root: string;
	readonly query: string;
	readonly chosen: string | undefined;
	readonly onReveal: (path: string) => void;
}): ReactNode {
	const query = useDebounced(props.query, 120);
	const outcome = useOutcome("files.search", { path: props.root, query, limit: 100 });
	if (outcome === undefined) return <TreeNote depth={0}>Searching…</TreeNote>;
	if ("failure" in outcome) return <TreeNote depth={0}>{outcome.failure}</TreeNote>;
	if (outcome.result.entries.length === 0) return <TreeNote depth={0}>No files found</TreeNote>;
	return outcome.result.entries.map((found) => {
		const path = childPath(props.root, found.path);
		const isFile = found.kind === "file";
		return (
			<TreeRow
				key={found.path}
				depth={0}
				chosen={path === props.chosen}
				icon={<PathIcon path={found.path} kind={found.kind} />}
				name={nameOf(found.path)}
				folder={folderOf(found.path)}
				onPress={() => (isFile ? openFile(props.thread, path) : props.onReveal(path))}
			/>
		);
	});
}

/**
 * One row of the tree: its indent, icon and name, and the folder a found path is in after it; a folder's, open or not,
 * its chevron turning with it; shaded where it is the file read, faded where its repository leaves it out.
 */
function TreeRow(props: {
	readonly depth: number;
	readonly icon: ReactNode;
	readonly name: string;
	readonly onPress: () => void;
	readonly folder?: string;
	readonly open?: boolean;
	readonly chosen?: boolean;
	readonly faded?: boolean;
}): ReactNode {
	return (
		<button
			type="button"
			onClick={props.onPress}
			aria-expanded={props.open}
			aria-current={props.chosen === true ? "true" : undefined}
			data-faded={props.faded === true ? "" : undefined}
			style={{ paddingLeft: `${String(0.5 + props.depth * 0.75)}rem` }}
			className="group/tree-row flex h-control-xs w-full items-center gap-1.5 rounded pr-2 text-left hover:bg-accent/50 data-faded:text-muted-foreground/60 aria-[current=true]:bg-accent aria-[current=true]:text-foreground [&>svg]:size-3.5 [&>svg]:shrink-0 [&>svg:not([class*='text-'])]:text-muted-foreground"
		>
			{props.icon}
			<span className={props.folder === undefined ? "truncate" : "shrink-0"}>{props.name}</span>
			{props.folder === undefined || props.folder === "" ? null : <span className="min-w-0 truncate text-xs text-muted-foreground">{props.folder}</span>}
		</button>
	);
}

/** A line of the tree's own words, at a row's indent. */
function TreeNote(props: { readonly depth: number; readonly children: ReactNode }): ReactNode {
	return (
		<p style={{ paddingLeft: `${String(0.5 + props.depth * 0.75)}rem` }} className="py-1 pr-2 text-xs text-muted-foreground">
			{props.children}
		</p>
	);
}
