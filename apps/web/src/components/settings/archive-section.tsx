/**
 * The archive, a section of the threads' settings: the threads the person archived, out of the sidebar, newest first —
 * each by its title, its project and when it was last active, opened from its title, taken back into the sidebar, or
 * deleted.
 */
import { type ReactNode, useState } from "react";
import type { Listed } from "@octoii-works/octoii-client";
import { useClient, useThreads } from "@octoii-works/octoii-client/react";
import { ArchiveRestore, Trash2 } from "lucide-react";
import { activeAt, isArchived, projectOf, threadTitle } from "../../core/threads.ts";
import { shortAgo } from "../../core/time.ts";
import { useNow } from "../effects/now.ts";
import { go } from "../state/navigation.ts";
import { DeleteDialog } from "../sidebar/delete-dialog.tsx";
import { Button } from "../ui/button.tsx";
import { Row, Section } from "./layout.tsx";
import { failed } from "../state/notices.ts";

/** The section: nothing until the node listed the threads. */
export function ArchiveSection(): ReactNode {
	const client = useClient();
	const rows = useThreads();
	const now = useNow(60_000);
	if (rows === undefined) return null;
	const archived = rows.filter(isArchived);
	return (
		<Section title="Archive" description="Threads you put away, out of the sidebar." anchor="setting-archive">
			{archived.length === 0 ? (
				<Row title="Nothing archived" description="A thread you archive from the sidebar waits here." />
			) : (
				archived.map((row) => (
					<div key={row.id} className="flex items-center gap-2 px-3.5 py-2.5">
						<button
							type="button"
							className="flex min-w-0 flex-1 cursor-pointer flex-col items-start text-left"
							onClick={() => go({ place: "thread", thread: row.id })}
						>
							<span className="w-full truncate text-ui font-medium hover:underline">{threadTitle(row)}</span>
							<span className="text-xs text-muted-foreground">
								{projectOf(row)?.name ?? "No project"} · {shortAgo(now - activeAt(row))}
							</span>
						</button>
						<Button
							variant="outline"
							size="xs"
							onClick={() =>
								void client.configure(row.id, { archived: false }).catch((error: unknown) => failed("The thread could not be taken out of the archive", error))
							}
						>
							<ArchiveRestore />
							Unarchive
						</Button>
						<DeleteButton row={row} />
					</div>
				))
			)}
		</Section>
	);
}

/** The button that deletes an archived thread, once the person says so again. */
function DeleteButton(props: { readonly row: Listed }): ReactNode {
	const [asking, setAsking] = useState(false);
	return (
		<>
			<Button variant="ghost-destructive" size="xs" aria-label={`Delete ${threadTitle(props.row)}`} onClick={() => setAsking(true)}>
				<Trash2 />
				Delete
			</Button>
			<DeleteDialog row={props.row} open={asking} onOpenChange={setAsking} />
		</>
	);
}
