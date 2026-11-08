/**
 * The Files surface: the thread's folder as a tree on the right — its folders opening as they are clicked — with a
 * search over its paths above it and a button that reads the folder again; and on the left the file chosen, under the
 * names on the way to it, beside them what wraps its long lines and what hides the tree, as the device keeps them, the
 * tree always shown while no file is. What it shows is the panel's, kept for the thread, so a file or folder opened
 * anywhere shows here; a folder a search finds is shown in the tree, every folder on the way to it opened.
 */
import { type ReactNode, useState } from "react";
import { ListTree, RefreshCw, Search, WrapText } from "lucide-react";
import { useDevice } from "../state/device.ts";
import { revealFolder, useThreadPanel } from "../state/panel.ts";
import { IconButton, ToggleButton } from "../ui/button.tsx";
import { cn } from "../ui/cn.ts";
import { Input } from "../ui/input.tsx";
import { FileView } from "./file-view.tsx";
import { FolderRows, FoundRows } from "./file-tree.tsx";

/** What the surface is given: its thread, and the folder the thread works in, none where it works in none. */
export type FilesSurfaceProps = { readonly thread: string; readonly folder: string | undefined };

/** The surface. */
export function FilesSurface(props: FilesSurfaceProps): ReactNode {
	if (props.folder === undefined) return <p className="px-6 py-10 text-center text-xs text-muted-foreground/70">This thread works in no folder.</p>;
	return <FolderSurface thread={props.thread} folder={props.folder} />;
}

/** The surface of `thread`, which works in `folder`: what it shows kept for the thread, its search and its reading again its own. */
function FolderSurface(props: { readonly thread: string; readonly folder: string }): ReactNode {
	const { thread, folder } = props;
	const place = useThreadPanel(thread);
	const [search, setSearch] = useState("");
	const [generation, setGeneration] = useState(0);
	const { device, set } = useDevice();
	const treeShown = device.files_tree || place.file === undefined;
	const reveal = (path: string): void => {
		revealFolder(thread, folder, path);
		setSearch("");
	};
	return (
		<div className="flex min-h-0 flex-1">
			<div className="flex min-w-0 flex-1 flex-col">
				{place.file === undefined ? (
					<p className="px-6 py-10 text-center text-xs text-muted-foreground/70">Choose a file in the tree to read it.</p>
				) : (
					<FileView
						key={`${place.file} ${String(generation)}`}
						root={folder}
						path={place.file}
						wrap={device.wrap_lines}
						actions={
							<>
								<ToggleButton label="Wrap long lines" pressed={device.wrap_lines} onPressedChange={(wrap_lines) => set({ wrap_lines })}>
									<WrapText className="size-3.5" />
								</ToggleButton>
								<ToggleButton label="Show the tree" pressed={device.files_tree} onPressedChange={(files_tree) => set({ files_tree })}>
									<ListTree className="size-3.5" />
								</ToggleButton>
							</>
						}
					/>
				)}
			</div>
			<div className={cn("flex w-64 shrink-0 flex-col border-l border-border/60", !treeShown && "hidden")}>
				<div className="m-2 flex items-center gap-1">
					<IconButton label="Read the folder again" onClick={() => setGeneration(generation + 1)}>
						<RefreshCw className="size-3.5" />
					</IconButton>
					<label className="flex h-control-sm min-w-0 flex-1 items-center gap-1.5 rounded-md border border-border px-2 focus-within:border-ring">
						<Search className="size-3.5 text-muted-foreground" />
						<Input
							type="search"
							variant="bare"
							aria-label="Search files"
							placeholder="Search files"
							value={search}
							onValueChange={setSearch}
							className="text-xs"
						/>
					</label>
				</div>
				<div key={generation} className="min-h-0 flex-1 overflow-y-auto px-1 pb-2 text-ui">
					{search.trim() === "" ? (
						<FolderRows thread={thread} place={place} path={folder} depth={0} />
					) : (
						<FoundRows thread={thread} root={folder} query={search.trim()} chosen={place.file} onReveal={reveal} />
					)}
				</div>
			</div>
		</div>
	);
}
