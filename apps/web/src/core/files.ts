/**
 * The machine's files as the interface shows them: whether a path is whole, as the node takes one; a folder's names as
 * the tree shows them, folders first, `.git` left out as an editor's explorer leaves it; a path in a folder, and the
 * names on the way to it from the folder the tree shows; a file's length as a person reads it;
 * what a file's name says of it, for its icon; and, as a folder is chosen, the way to it and the folders in it.
 */
import type { FolderEntry } from "@octoii-works/octoii-client";

/** Whether `path` is whole, as the node takes a path of the machine's: from the root, a drive's, or `~`, the home folder. */
export function isWholePath(path: string): boolean {
	return /^(\/|~(\/|$)|[A-Za-z]:[\\/])/.test(path.trim());
}

/** The names the tree never shows. */
const UNSHOWN: ReadonlySet<string> = new Set([".git"]);

/** A folder's names as the tree shows them: its folders, then the rest, each in the order the node gives them. */
export function shownEntries(entries: readonly FolderEntry[]): readonly FolderEntry[] {
	const shown = entries.filter((entry) => !UNSHOWN.has(entry.name));
	return [...shown.filter((entry) => entry.kind === "directory"), ...shown.filter((entry) => entry.kind !== "directory")];
}

/** The path of `name` in the folder `folder`. */
export function childPath(folder: string, name: string): string {
	return folder.endsWith("/") ? `${folder}${name}` : `${folder}/${name}`;
}

/** The last name of `path`. */
export function nameOf(path: string): string {
	return path.split("/").findLast((name) => name !== "") ?? path;
}

/** The folder `path` is in, as it is written: none where it is a name alone. */
export function folderOf(path: string): string {
	const slash = path.lastIndexOf("/");
	return slash < 0 ? "" : path.slice(0, slash);
}

/** A name on the way to a path, and the path up to it. */
export type Crumb = { readonly name: string; readonly path: string };

/** The names on the way from the folder `root` to `path` under it, `root`'s own first, each with the path up to it. */
export function crumbsOf(root: string, path: string): readonly Crumb[] {
	const prefix = root.endsWith("/") ? root : `${root}/`;
	const below = path.startsWith(prefix)
		? path
				.slice(prefix.length)
				.split("/")
				.filter((name) => name !== "")
		: [];
	const crumbs: Crumb[] = [{ name: nameOf(root), path: root }];
	for (const name of below) crumbs.push({ name, path: childPath(crumbs.at(-1)?.path ?? root, name) });
	return crumbs;
}

/** A length in bytes as a person reads it: bytes, then KB, MB and GB by 1024s, one place after the point. */
export function bytesText(bytes: number): string {
	const units = ["KB", "MB", "GB"];
	let size = bytes;
	let unit = "bytes";
	for (const next of units) {
		if (size < 1024) break;
		size /= 1024;
		unit = next;
	}
	return unit === "bytes" ? `${String(bytes)} bytes` : `${size.toFixed(1).replace(/\.0$/, "")} ${unit}`;
}

/** What a file's name says of it, for its icon. */
export type FileLook = "code" | "data" | "text" | "image" | "other";

const LOOKS: Readonly<Record<string, FileLook>> = {
	ts: "code",
	tsx: "code",
	js: "code",
	jsx: "code",
	mjs: "code",
	cjs: "code",
	zig: "code",
	c: "code",
	h: "code",
	py: "code",
	rs: "code",
	go: "code",
	swift: "code",
	css: "code",
	html: "code",
	sh: "code",
	json: "data",
	jsonc: "data",
	yaml: "data",
	yml: "data",
	toml: "data",
	zon: "data",
	md: "text",
	txt: "text",
	png: "image",
	jpg: "image",
	jpeg: "image",
	gif: "image",
	svg: "image",
	webp: "image",
};

/** What `name` says of its file, by its extension. */
export function lookOf(name: string): FileLook {
	const dot = name.lastIndexOf(".");
	return dot <= 0 ? "other" : (LOOKS[name.slice(dot + 1).toLowerCase()] ?? "other");
}

/** The way to the folder `path`, a step a name: from the home folder `home`, named `~`, where it is under it; else from the root. */
export function wayTo(path: string, home: string | undefined): readonly Crumb[] {
	if (home !== undefined && (path === home || path.startsWith(`${home}/`))) return [{ name: "~", path: home }, ...crumbsOf(home, path).slice(1)];
	return crumbsOf("/", path);
}

/** The names among `entries` a folder may be chosen from: the folders, and the links, which may be folders; hidden ones — named from a dot — where `hidden` says. */
export function foldersAmong(entries: readonly FolderEntry[], hidden: boolean): readonly FolderEntry[] {
	return entries.filter((entry) => entry.kind !== "file" && (hidden || !entry.name.startsWith(".")));
}
