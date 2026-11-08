/**
 * A file the changes hold, as a row of the Diff view: what became of it, its path — its folder faint, the path it had
 * before it where it was renamed — and the lines it gained and lost; opened, its patch below it, drawn stacked or side
 * by side, its context widened by its two versions where the person asks for more.
 */
import type { ReactNode } from "react";
import type { Changed, ChangedFile, Comparison } from "@octoii-works/octoii-client";
import { useClient } from "@octoii-works/octoii-client/react";
import { PatchDiff } from "@pierre/diffs/react";
import type { FileDiffLoadedFiles, FileDiffMetadata } from "@pierre/diffs";
import { ArrowRight, SquareDot, SquareMinus, SquarePlus } from "lucide-react";
import { pathParts } from "../../core/diff.ts";
import { useOutcome } from "../effects/read.ts";
import { CODE_THEMES } from "../effects/theme.ts";
import { Collapsible, CollapsiblePanel, CollapsibleTrigger, FoldChevron } from "../ui/collapsible.tsx";

/** How a file's patch is laid out: stacked or side by side, its long lines wrapped or scrolled, light or dark. */
export type Layout = { readonly split: boolean; readonly wrap: boolean; readonly dark: boolean };

/** What a row is given: the repository's folder, the trees compared, the file, whether it is open, the layout, and the revision its patch is read at. */
export type FileChangeProps = {
	readonly folder: string;
	readonly comparison: Comparison;
	readonly file: Changed;
	readonly open: boolean;
	readonly onToggle: () => void;
	readonly layout: Layout;
	readonly revision: string;
};

/** The row, and the patch below it where it is open. */
export function FileChange(props: FileChangeProps): ReactNode {
	const { file } = props;
	const { folder, name } = pathParts(file.path);
	return (
		<Collapsible open={props.open} onOpenChange={props.onToggle} className="border-b border-border/60">
			<CollapsibleTrigger title={file.path} className="flex h-control-sm w-full cursor-pointer items-center gap-1.5 px-2 text-left text-xs hover:bg-accent/60">
				<FoldChevron className="text-muted-foreground" />
				<StatusIcon file={file} />
				{file.old_path === undefined ? null : (
					<>
						<span className="min-w-0 shrink truncate text-muted-foreground">{file.old_path}</span>
						<ArrowRight className="size-3 shrink-0 text-muted-foreground" />
					</>
				)}
				<span className="min-w-0 truncate">
					<span className="text-muted-foreground">{folder}</span>
					<span className="text-foreground">{name}</span>
				</span>
				<span className="ml-auto flex shrink-0 gap-1.5 pl-2 font-mono tabular-nums">
					<span className="text-diff-add">+{file.additions ?? 0}</span>
					<span className="text-diff-remove">−{file.deletions ?? 0}</span>
				</span>
			</CollapsibleTrigger>
			<CollapsiblePanel>
				<FilePatch {...props} />
			</CollapsiblePanel>
		</Collapsible>
	);
}

/** What became of a file, as a mark: gained, lost, or changed. */
function StatusIcon(props: { readonly file: Changed }): ReactNode {
	switch (props.file.status) {
		case "added":
		case "untracked":
		case "copied":
			return <SquarePlus className="size-3.5 shrink-0 text-diff-add" aria-label={props.file.status} />;
		case "deleted":
			return <SquareMinus className="size-3.5 shrink-0 text-diff-remove" aria-label="deleted" />;
		case "modified":
		case "renamed":
		case "type-changed":
			return <SquareDot className="size-3.5 shrink-0 text-diff-modified" aria-label={props.file.status} />;
	}
}

/** A file's patch, read as it opens and again at each revision. */
function FilePatch(props: FileChangeProps): ReactNode {
	const client = useClient();
	const { folder, comparison, file, layout } = props;
	const named: ChangedFile = { path: file.path, status: file.status, ...(file.old_path === undefined ? {} : { old_path: file.old_path }) };
	const outcome = useOutcome("git.patch", file.binary ? undefined : { path: folder, comparison, file: named }, props.revision);
	if (file.binary) return <Note>A binary file: its lines are not shown.</Note>;
	if (outcome === undefined) return <Note>Reading its changes…</Note>;
	if ("failure" in outcome) return <Note>{outcome.failure}</Note>;
	if (outcome.result.patch === "") return <Note>Its lines did not change.</Note>;
	const loadDiffFiles = async (diff: FileDiffMetadata): Promise<FileDiffLoadedFiles> => {
		const versions = await client.call("git.versions", { path: folder, comparison, file: named });
		const newFile = { name: diff.name, contents: versions.new ?? "" };
		return versions.old === undefined ? { oldFile: null, newFile } : { oldFile: { name: diff.prevName ?? diff.name, contents: versions.old }, newFile };
	};
	return (
		<div className="code-view">
			<PatchDiff
				patch={outcome.result.patch}
				disableWorkerPool
				options={{
					diffStyle: layout.split ? "split" : "unified",
					overflow: layout.wrap ? "wrap" : "scroll",
					theme: CODE_THEMES,
					themeType: layout.dark ? "dark" : "light",
					disableFileHeader: true,
					loadDiffFiles,
				}}
			/>
		</div>
	);
}

function Note(props: { readonly children: ReactNode }): ReactNode {
	return <p className="px-8 py-2 text-xs text-muted-foreground">{props.children}</p>;
}
