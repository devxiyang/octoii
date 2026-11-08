/**
 * Asking before a thread is deleted, as it goes for good: its title, what goes with it, and the button that deletes it,
 * which waits on the node while it deletes; the place shown left for the home where it was the thread deleted.
 */
import { type ReactNode, useState, useTransition } from "react";
import type { Listed } from "@octoii-works/octoii-client";
import { useClient } from "@octoii-works/octoii-client/react";
import { threadTitle } from "../../core/threads.ts";
import { go, useRoute } from "../state/navigation.ts";
import { Button } from "../ui/button.tsx";
import { AlertDialog, DialogClose, DialogDescription, DialogPopup, DialogTitle } from "../ui/dialog.tsx";

/** What the question is given: the thread, and whether it is asked. */
export type DeleteDialogProps = { readonly row: Listed; readonly open: boolean; readonly onOpenChange: (open: boolean) => void };

/** The question. */
export function DeleteDialog(props: DeleteDialogProps): ReactNode {
	const client = useClient();
	const route = useRoute();
	const [failure, setFailure] = useState<string | undefined>(undefined);
	const [deleting, startDeleting] = useTransition();
	const remove = (): void =>
		startDeleting(async () => {
			try {
				await client.delete(props.row.id);
				props.onOpenChange(false);
				if (route.place === "thread" && route.thread === props.row.id) go({ place: "home" });
			} catch (error) {
				setFailure(error instanceof Error ? error.message : String(error));
			}
		});
	return (
		<AlertDialog open={props.open} onOpenChange={props.onOpenChange}>
			<DialogPopup className="w-[26rem] max-w-[calc(100vw-2rem)] p-5">
				<DialogTitle className="text-base font-semibold">Delete “{threadTitle(props.row)}”?</DialogTitle>
				<DialogDescription className="mt-2 text-sm text-muted-foreground">
					Its conversation goes for good, and its terminals and pages close. Archive it instead to keep it out of the way.
				</DialogDescription>
				{failure === undefined ? null : <p className="mt-2 text-sm text-error-foreground">{failure}</p>}
				<div className="mt-5 flex justify-end gap-2">
					<DialogClose render={<Button variant="outline" size="sm" />}>Cancel</DialogClose>
					<Button variant="destructive" size="sm" disabled={deleting} onClick={remove}>
						{deleting ? "Deleting…" : "Delete"}
					</Button>
				</div>
			</DialogPopup>
		</AlertDialog>
	);
}
