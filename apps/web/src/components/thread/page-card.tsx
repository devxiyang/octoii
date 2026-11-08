/**
 * A page of the thread's browser as a message points at it: a card of its title and its address, as the thread's pages
 * have them now, opening it in the panel beside the chat as it is clicked; where the thread has it open no more, a card
 * that says so.
 */
import { type ReactNode, useContext } from "react";
import { Globe } from "lucide-react";
import { pageKey, showSurface } from "../state/panel.ts";
import { IconTile } from "../ui/icon-tile.tsx";
import { MessageThreadContext } from "./message-thread.ts";

/** The card of the page `page`, by its id. */
export function PageCard(props: { readonly page: string }): ReactNode {
	const shown = useContext(MessageThreadContext);
	const listed = shown?.pages.find((page) => page.id === props.page);
	const words = listed === undefined ? "A page no longer open" : listed.title === "" ? listed.url : listed.title;
	return (
		<button
			type="button"
			disabled={listed === undefined}
			onClick={() => {
				if (shown !== undefined) showSurface(shown.thread, pageKey(props.page));
			}}
			className="card my-2 flex w-full max-w-md items-center gap-3 px-3 py-2.5 text-left outline-none hover:bg-accent/40 focus-visible:ring-2 focus-visible:ring-ring/70 disabled:pointer-events-none disabled:opacity-60"
		>
			<IconTile>
				<Globe className="size-4" />
			</IconTile>
			<span className="flex min-w-0 flex-col">
				<span className="truncate text-sm font-medium">{words}</span>
				{listed === undefined ? null : <span className="truncate text-xs text-muted-foreground">{listed.url}</span>}
			</span>
		</button>
	);
}
