/**
 * What waits on the person, as the timeline marks it while it waits — answered in the composer's place, where it docks,
 * and said in words on the turn's last line and the page's header: a call's line ends in the mark, and what no call
 * asks, as trust in what a folder runs, stands as a line of its own, what it asks and the mark.
 */
import type { ReactNode } from "react";
import type { Ask } from "@octoii-works/octoii-client";
import { ShieldQuestion } from "lucide-react";
import { askTitle } from "../../core/asks.ts";
import { Mark } from "./marks.tsx";

/** The end of a line whose call or request waits on the person: its mark, its words the tip. */
export function Waiting(): ReactNode {
	return (
		<span role="img" aria-label="Waiting for you" title="Waiting for you" className="flex shrink-0 text-warning-foreground">
			<ShieldQuestion className="size-3.5" />
		</span>
	);
}

/** What no call asks, as a line of the work while it waits: what it asks, and the mark that it waits. */
export function AskLine(props: { readonly ask: Ask }): ReactNode {
	return (
		<p className="work-line">
			<Mark>
				<ShieldQuestion />
			</Mark>
			<span className="min-w-0 truncate">{askTitle(props.ask)}</span>
			<span className="flex-1" />
			<Waiting />
		</p>
	);
}
