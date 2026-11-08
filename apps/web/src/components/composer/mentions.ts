/**
 * The file mentioned at the composer's caret, and what it may be: the files and folders under the thread's folder whose
 * paths hold what is typed after `@`, best first, searched once the person pauses; which of them is highlighted, moved
 * by the arrow keys; and whether the person dismissed the menu with Escape, till they begin another mention.
 */
import { useState } from "react";
import type { FoundPath } from "@octoii-works/octoii-client";
import { type Mention, mentionAt } from "../../core/mentions.ts";
import { useDebounced } from "../effects/debounced.ts";
import { useOutcome } from "../effects/read.ts";

/** The most paths a mention's menu offers. */
const MENTION_CHOICES = 20;

/** A key the menu took: whether it did, and the path chosen where it was Enter or Tab. */
export type MentionKey = { readonly handled: boolean; readonly chosen?: FoundPath };

/** The mention being written and its menu: the paths found, none while they are searched; the one highlighted; and what a key does. */
export type Mentions = {
	readonly mention: Mention | undefined;
	readonly found: readonly FoundPath[] | undefined;
	readonly highlighted: number;
	readonly highlight: (index: number) => void;
	readonly key: (key: string) => MentionKey;
};

/** The mention the caret ends in `text`, where the composer mentions the files of `folder`. */
export function useMentions(folder: string | undefined, text: string, caret: number): Mentions {
	const written = folder === undefined ? undefined : mentionAt(text, caret);
	const [dismissed, setDismissed] = useState<number | undefined>(undefined);
	const mention = written?.start === dismissed ? undefined : written;
	const query = useDebounced(mention?.query ?? "", 80);
	const outcome = useOutcome("files.search", mention === undefined || folder === undefined ? undefined : { path: folder, query, limit: MENTION_CHOICES });
	const found = outcome === undefined ? undefined : "result" in outcome ? outcome.result.entries : [];
	const [highlight, setHighlight] = useState({ query: "", index: 0 });
	const count = found?.length ?? 0;
	const highlighted = highlight.query === query ? Math.min(highlight.index, Math.max(count - 1, 0)) : 0;
	const key = (pressed: string): MentionKey => {
		if (mention === undefined) return { handled: false };
		if (pressed === "Escape") {
			setDismissed(mention.start);
			return { handled: true };
		}
		const chosen = found?.[highlighted];
		if (chosen === undefined) return { handled: false };
		if (pressed === "ArrowDown" || pressed === "ArrowUp") {
			setHighlight({ query, index: (highlighted + (pressed === "ArrowDown" ? 1 : count - 1)) % count });
			return { handled: true };
		}
		return pressed === "Enter" || pressed === "Tab" ? { handled: true, chosen } : { handled: false };
	};
	return { mention, found, highlighted, highlight: (index) => setHighlight({ query, index }), key };
}
