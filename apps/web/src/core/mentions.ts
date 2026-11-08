/**
 * A file mentioned as the person writes: `@` at the start or after a space, and what follows it up to the caret, which
 * the files and folders under the thread's folder are searched for; and the text with the one chosen in its place, as a
 * markdown link to it — which the message shows by its name and the model reads by its path.
 */
import type { FoundPath } from "@octoii-works/octoii-client";
import { linkTo } from "./links.ts";

/** A mention being written: what is typed of it, and where its `@` stands in the text. */
export type Mention = { readonly query: string; readonly start: number };

/** The mention the caret ends, where there is one. */
export function mentionAt(text: string, caret: number): Mention | undefined {
	const found = /(?:^|\s)@([^\s@]*)$/.exec(text.slice(0, caret));
	if (found === null) return undefined;
	const query = found[1] ?? "";
	return { query, start: caret - query.length - 1 };
}

/**
 * The text with a link to `found` in the place of the mention the caret ends, and a space after it, a space already
 * there taken as that one; and where the caret goes, after it.
 */
export function withMention(text: string, mention: Mention, caret: number, found: FoundPath): { readonly text: string; readonly caret: number } {
	const inserted = `${linkTo(found.path, found.kind)} `;
	const after = text.slice(caret).replace(/^ /, "");
	return { text: `${text.slice(0, mention.start)}${inserted}${after}`, caret: mention.start + inserted.length };
}
