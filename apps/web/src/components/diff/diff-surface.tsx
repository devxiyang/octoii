/**
 * The Diff view: the changes in the repository a thread's folder is in, as git tells them — the branch's against the
 * branch its work was taken from, the working tree's own included; those not yet committed; or one commit's — under a
 * bar that picks which, tells the lines they gained and lost all told, reads them again, opens or closes every file,
 * lays the patches out stacked or side by side, and wraps their long lines or not, as the files view does; then a row
 * for each file, opened to its patch.
 * They are read again as the thread's turns run and end, and as the person asks.
 */
import { type ReactNode, useState } from "react";
import type { Changes, ChangesScope, Commit, Repository } from "@octoii-works/octoii-client";
import { ChevronDown, ChevronsDownUp, ChevronsUpDown, Columns2, RefreshCw, Rows2, WrapText } from "lucide-react";
import { defaultScope, scopeKey, scopeName, shortCount, totalsOf } from "../../core/diff.ts";
import { useOutcome } from "../effects/read.ts";
import { useDarkPage } from "../effects/theme.ts";
import { useDevice } from "../state/device.ts";
import { showChanges, useThreadPanel } from "../state/panel.ts";
import { IconButton, ToggleButton } from "../ui/button.tsx";
import { Menu, MenuItemLabel, MenuPopup, MenuRadioGroup, MenuRadioItem, MenuSeparator, MenuTrigger } from "../ui/menu.tsx";
import { Segmented } from "../ui/segmented.tsx";
import { FileChange, type Layout } from "./file-change.tsx";

/** What the view is given: its thread, the folder it works in — none where it works in none — and the revision its turns stand at. */
export type DiffSurfaceProps = { readonly thread: string; readonly folder: string | undefined; readonly revision: string };

/** The view. */
export function DiffSurface(props: DiffSurfaceProps): ReactNode {
	if (props.folder === undefined) return <Note>This thread works in no folder.</Note>;
	return <RepositoryDiff thread={props.thread} folder={props.folder} revision={props.revision} />;
}

/** The changes of the repository `folder` is in, read again at each revision of the thread's and each the person asks for. */
function RepositoryDiff(props: { readonly thread: string; readonly folder: string; readonly revision: string }): ReactNode {
	const [asked, setAsked] = useState(0);
	const revision = `${props.revision} ${String(asked)}`;
	const outcome = useOutcome("git.repository", { path: props.folder }, revision);
	if (outcome === undefined) return <Note>Reading the repository…</Note>;
	if ("failure" in outcome) return <Note>{outcome.failure}</Note>;
	const repository = outcome.result.repository;
	if (repository === undefined) return <Note>This folder is in no git repository.</Note>;
	return <ChangesView thread={props.thread} folder={props.folder} repository={repository} revision={revision} onRefresh={() => setAsked(asked + 1)} />;
}

/** The bar and the rows of the changes the thread's view asks for. */
function ChangesView(props: {
	readonly thread: string;
	readonly folder: string;
	readonly repository: Repository;
	readonly revision: string;
	readonly onRefresh: () => void;
}): ReactNode {
	const { device, set } = useDevice();
	const dark = useDarkPage();
	const scope = useThreadPanel(props.thread).scope ?? defaultScope(props.repository);
	const outcome = useOutcome("git.changes", { path: props.folder, scope }, props.revision);
	const [open, setOpen] = useState<ReadonlySet<string>>(new Set());
	const changes = outcome !== undefined && "result" in outcome ? outcome.result : undefined;
	const layout: Layout = { split: device.diff_layout === "split", wrap: device.wrap_lines, dark };
	const toggle = (path: string): void => {
		const next = new Set(open);
		if (!next.delete(path)) next.add(path);
		setOpen(next);
	};
	const everyOpen = changes !== undefined && changes.files.length > 0 && changes.files.every((file) => open.has(file.path));
	return (
		<div className="flex min-h-0 flex-1 flex-col">
			<div className="flex h-control-lg shrink-0 items-center gap-1 border-b border-border px-2 text-xs">
				<ScopeMenu thread={props.thread} folder={props.folder} repository={props.repository} scope={scope} />
				{scope.type === "branch" && changes?.base !== undefined ? <span className="truncate text-muted-foreground">vs {changes.base}</span> : null}
				{changes === undefined ? null : <Totals changes={changes} />}
				<span className="flex-1" />
				<IconButton label="Read the changes again" onClick={props.onRefresh}>
					<RefreshCw className="size-3.5" />
				</IconButton>
				<IconButton
					label={everyOpen ? "Close every file" : "Open every file"}
					onClick={() => setOpen(everyOpen || changes === undefined ? new Set() : new Set(changes.files.map((file) => file.path)))}
				>
					{everyOpen ? <ChevronsDownUp className="size-3.5" /> : <ChevronsUpDown className="size-3.5" />}
				</IconButton>
				<Segmented
					label="How the two sides are laid out"
					value={device.diff_layout}
					onValueChange={(diff_layout) => set({ diff_layout })}
					items={[
						{ value: "stacked", label: <SideLabel icon={<Rows2 />} words="Stacked" /> },
						{ value: "split", label: <SideLabel icon={<Columns2 />} words="Side by side" /> },
					]}
					className="mx-1 [&>*]:h-6 [&>*]:px-1.5"
				/>
				<ToggleButton label="Wrap long lines" pressed={layout.wrap} onPressedChange={(wrap_lines) => set({ wrap_lines })}>
					<WrapText className="size-3.5" />
				</ToggleButton>
			</div>
			<div className="min-h-0 flex-1 overflow-y-auto">
				{outcome === undefined ? (
					<Note>Reading the changes…</Note>
				) : "failure" in outcome ? (
					<Note>{outcome.failure}</Note>
				) : outcome.result.files.length === 0 ? (
					<Note>Nothing changed.</Note>
				) : (
					outcome.result.files.map((file) => (
						<FileChange
							key={file.path}
							folder={props.folder}
							comparison={outcome.result.comparison}
							file={file}
							open={open.has(file.path)}
							onToggle={() => toggle(file.path)}
							layout={layout}
							revision={props.revision}
						/>
					))
				)}
			</div>
		</div>
	);
}

/** A layout's segment: its icon, its words for those who hear them and for its tip. */
function SideLabel(props: { readonly icon: ReactNode; readonly words: string }): ReactNode {
	return (
		<span title={props.words} className="flex items-center [&>svg]:size-3.5">
			{props.icon}
			<span className="sr-only">{props.words}</span>
		</span>
	);
}

/** The lines the changes gained and lost, all told. */
function Totals(props: { readonly changes: Changes }): ReactNode {
	const { additions, deletions } = totalsOf(props.changes.files);
	return (
		<span className="flex shrink-0 gap-1.5 pl-1 font-mono tabular-nums">
			<span className="text-diff-add">+{shortCount(additions)}</span>
			<span className="text-diff-remove">−{shortCount(deletions)}</span>
		</span>
	);
}

/** Which changes the view shows: the branch's, where the repository has a base; those not yet committed; or a commit of the branch's, listed as the menu opens. */
function ScopeMenu(props: { readonly thread: string; readonly folder: string; readonly repository: Repository; readonly scope: ChangesScope }): ReactNode {
	const [menuOpen, setMenuOpen] = useState(false);
	const hasBase = props.repository.base !== undefined;
	const listed = useOutcome("git.commits", menuOpen && hasBase ? { path: props.folder } : undefined);
	const commits: readonly Commit[] = listed !== undefined && "result" in listed ? listed.result.commits : [];
	const choose = (scope: ChangesScope): void => showChanges(props.thread, scope);
	return (
		<Menu open={menuOpen} onOpenChange={setMenuOpen}>
			<MenuTrigger className="flex h-6 max-w-48 cursor-pointer items-center gap-1 rounded-md px-1.5 font-medium text-foreground hover:bg-accent">
				<span className="truncate">{scopeName(props.scope, commits)}</span>
				<ChevronDown className="size-3 shrink-0 text-muted-foreground" />
			</MenuTrigger>
			<MenuPopup className="w-72">
				<MenuRadioGroup value={scopeKey(props.scope)}>
					{hasBase ? <ScopeItem label="Changes" scope={{ type: "branch" }} onChoose={choose} /> : null}
					<ScopeItem label="Uncommitted" scope={{ type: "uncommitted" }} onChoose={choose} />
					{commits.length === 0 ? null : <MenuSeparator />}
					{commits.map((commit) => (
						<ScopeItem
							key={commit.commit}
							label={commit.subject}
							detail={commit.commit.slice(0, 7)}
							scope={{ type: "commit", commit: commit.commit }}
							onChoose={choose}
						/>
					))}
				</MenuRadioGroup>
			</MenuPopup>
		</Menu>
	);
}

/** A scope the menu offers, its check at its end while it is the one shown. */
function ScopeItem(props: {
	readonly label: string;
	readonly detail?: string;
	readonly scope: ChangesScope;
	readonly onChoose: (scope: ChangesScope) => void;
}): ReactNode {
	return (
		<MenuRadioItem value={scopeKey(props.scope)} onClick={() => props.onChoose(props.scope)}>
			<MenuItemLabel>{props.label}</MenuItemLabel>
			{props.detail === undefined ? null : <span className="font-mono text-xs text-muted-foreground">{props.detail}</span>}
		</MenuRadioItem>
	);
}

function Note(props: { readonly children: ReactNode }): ReactNode {
	return <p className="px-6 py-10 text-center text-xs text-faint-foreground">{props.children}</p>;
}
