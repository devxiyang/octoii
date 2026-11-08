/** A folder of the machine's as the files tree reads it, hidden names too, a page of names at a time. */
import type { FolderEntry } from "@octoii-works/octoii-client";
import { usePages } from "./pages.ts";

/**
 * A folder as read so far: its path, whole and clean, as the node found it; its names, what reads more where more
 * follow, and why the last read of them failed, where it did; or why the folder could not be read.
 */
export type Folder =
	| { readonly path: string; readonly entries: readonly FolderEntry[]; readonly readMore: (() => void) | undefined; readonly failure?: string }
	| { readonly failure: string };

/** The folder at `path`, as read so far; none till its first page is answered. */
export function useFolder(path: string): Folder | undefined {
	const read = usePages("files.list", { path, hidden: true }, (last) => {
		const name = last.entries.at(-1)?.name;
		return last.more && name !== undefined ? { path, after: name, hidden: true } : undefined;
	});
	if (read === undefined || !("pages" in read)) return read;
	return {
		path: read.pages[0].path,
		entries: read.pages.flatMap((page) => page.entries),
		readMore: read.readMore,
		...(read.failure === undefined ? {} : { failure: read.failure }),
	};
}
