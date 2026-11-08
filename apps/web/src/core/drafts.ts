/** Where a draft belongs: a thread, by its id, or a new thread of a project's folder, or of none. */
export type DraftPlace = { readonly thread: string } | { readonly project: string | undefined };

/** A draft's key: its thread's id, or `new:` and its project's folder. */
export function draftKey(place: DraftPlace): string {
	return "thread" in place ? place.thread : `new:${place.project ?? ""}`;
}
