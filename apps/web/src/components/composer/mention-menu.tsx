/**
 * The menu of the paths a mention may be, over the composer: each file or folder by its path, its name bold and the
 * folder it is in after it, the highlighted one shaded — the box naming it to assistive technology as the arrow keys
 * move it; the list scrolls, its last rows fading out where more follow.
 */
import type { ReactNode } from "react";
import type { FoundPath } from "@octoii-works/octoii-client";
import { folderOf, nameOf } from "../../core/files.ts";
import { PathIcon } from "../files/path-icon.tsx";
import type { Mentions } from "./mentions.ts";

/** The id of the menu `menu`'s option at `index`, which the box names as the one highlighted. */
export function optionId(menu: string, index: number): string {
	return `${menu}-${String(index)}`;
}

/** The menu `id` of `mentions`, `onChoose` told of a path clicked. */
export function MentionMenu(props: { readonly id: string; readonly mentions: Mentions; readonly onChoose: (found: FoundPath) => void }): ReactNode {
	const { found, highlighted } = props.mentions;
	return (
		<div
			id={props.id}
			role="listbox"
			aria-label="Files to mention"
			className="absolute inset-x-3 bottom-full z-30 mb-1 max-h-72 overflow-y-auto floating rounded-lg p-1.5 mask-b-from-85%"
		>
			{found === undefined ? <p className="px-2.5 py-1.5 text-ui text-muted-foreground">Searching…</p> : null}
			{found?.length === 0 ? <p className="px-2.5 py-1.5 text-ui text-muted-foreground">No files found</p> : null}
			{found?.map((each, index) => {
				const folder = folderOf(each.path);
				return (
					<div
						key={each.path}
						id={optionId(props.id, index)}
						role="option"
						aria-selected={index === highlighted}
						tabIndex={-1}
						// Chosen as it is pressed, before the box would lose its caret.
						onMouseDown={(event) => {
							event.preventDefault();
							props.onChoose(each);
						}}
						onMouseEnter={() => props.mentions.highlight(index)}
						className="flex h-control-sm cursor-default items-center gap-2 rounded-md px-2.5 text-ui aria-selected:bg-accent [&>svg]:size-3.5 [&>svg]:shrink-0 [&>svg]:text-muted-foreground"
					>
						<PathIcon path={each.path} kind={each.kind} />
						<span className="shrink-0 font-medium text-foreground">{nameOf(each.path)}</span>
						{folder === "" ? null : <span className="min-w-0 truncate text-muted-foreground">{folder}</span>}
					</div>
				);
			})}
		</div>
	);
}
