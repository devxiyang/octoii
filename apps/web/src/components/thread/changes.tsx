/**
 * What a turn changed in files: the lines an edit or a write added and took out, green and red, as the Diff view counts
 * them; and, after a turn's answer, outside its fold, the files its edits and writes changed — how many, all they added
 * and took out, each file opening as it is clicked — with a way into the Diff view.
 */
import { type ReactNode, useContext } from "react";
import { FileDiff } from "lucide-react";
import { shortCount } from "../../core/diff.ts";
import type { Changed } from "../../core/timeline.ts";
import { PathLink } from "../files/path-link.tsx";
import { showSurface } from "../state/panel.ts";
import { MessageThreadContext } from "./message-thread.ts";

/** The lines a change added and took out. */
export function ChangeCount(props: { readonly added: number; readonly removed: number }): ReactNode {
	return (
		<span className="shrink-0 font-mono text-xs tabular-nums">
			<span className="text-diff-add">+{shortCount(props.added)}</span> <span className="text-diff-remove">−{shortCount(props.removed)}</span>
		</span>
	);
}

/** The way into the Diff view of the thread whose messages are shown; nothing where they are no thread's. */
export function OpenDiff(props: { readonly children: ReactNode }): ReactNode {
	const shown = useContext(MessageThreadContext);
	if (shown === undefined) return null;
	return (
		<button
			type="button"
			onClick={() => showSurface(shown.thread, "diff")}
			className="shrink-0 cursor-pointer text-xs text-muted-foreground hover:text-foreground"
		>
			{props.children}
		</button>
	);
}

/** The files a turn changed, in a well after its answer; nothing where it changed none. */
export function TurnChanges(props: { readonly changes: readonly Changed[] }): ReactNode {
	const { changes } = props;
	if (changes.length === 0) return null;
	let added = 0;
	let removed = 0;
	for (const change of changes) {
		added += change.added;
		removed += change.removed;
	}
	return (
		<div className="well flex flex-col px-3 py-1.5">
			<div className="flex min-h-control-xs items-center gap-2 text-ui font-medium">
				<FileDiff className="size-3.5 shrink-0 text-muted-foreground" />
				<span>{changes.length === 1 ? "1 changed file" : `${String(changes.length)} changed files`}</span>
				<ChangeCount added={added} removed={removed} />
				<span className="flex-1" />
				<OpenDiff>Open diff</OpenDiff>
			</div>
			{changes.map((change) => (
				<div key={change.path} className="flex min-h-control-xs min-w-0 items-center gap-2 text-ui text-muted-foreground">
					<span className="min-w-0 truncate">
						<PathLink path={change.path}>{change.path}</PathLink>
					</span>
					<span className="flex-1" />
					<ChangeCount added={change.added} removed={change.removed} />
				</div>
			))}
		</div>
	);
}
