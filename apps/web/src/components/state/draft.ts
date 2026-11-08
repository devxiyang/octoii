/**
 * Drafts: the next message of each place — a thread, or a new thread of a project — its words and the files it gives,
 * kept on the page while the person goes between places. The composer edits a place's draft.
 */
import { useSyncExternalStore } from "react";
import type { Attachment } from "../../core/attachments.ts";
import { type DraftPlace, draftKey } from "../../core/drafts.ts";

/** A place's draft, and how it changes. */
export type DraftHandle = {
	readonly text: string;
	readonly attachments: readonly Attachment[];
	readonly setText: (text: string) => void;
	/** Adds a file to the draft as it stands then, as files kept one by one arrive in any order. */
	readonly attach: (attachment: Attachment) => void;
	/** Takes the file `ref` away from the draft. */
	readonly detach: (ref: string) => void;
	/** Empties the draft, as its message was sent. */
	readonly clear: () => void;
};

/** A draft: its words and its files. */
type Draft = { readonly text: string; readonly attachments: readonly Attachment[] };

const EMPTY: Draft = { text: "", attachments: [] };

const drafts = new Map<string, Draft>();
const listeners = new Set<() => void>();

function changed(key: string, change: Partial<Draft>): void {
	const next = { ...(drafts.get(key) ?? EMPTY), ...change };
	if (next.text === "" && next.attachments.length === 0) drafts.delete(key);
	else drafts.set(key, next);
	for (const listener of listeners) listener();
}

function subscribe(listener: () => void): () => void {
	listeners.add(listener);
	return () => listeners.delete(listener);
}

/** A place's draft, followed as anything changes it. */
export function useDraft(place: DraftPlace): DraftHandle {
	const key = draftKey(place);
	const draft = useSyncExternalStore(subscribe, () => drafts.get(key) ?? EMPTY);
	return {
		text: draft.text,
		attachments: draft.attachments,
		setText: (text) => changed(key, { text }),
		attach: (attachment) => changed(key, { attachments: [...(drafts.get(key) ?? EMPTY).attachments, attachment] }),
		detach: (ref) => changed(key, { attachments: (drafts.get(key) ?? EMPTY).attachments.filter((each) => each.ref !== ref) }),
		clear: () => changed(key, EMPTY),
	};
}
