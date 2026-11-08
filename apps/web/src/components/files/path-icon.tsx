/* oxlint-disable octoii/no-palette-colors -- a file's icon takes its language's hue, beyond what the tokens name */
/** The icon of a path of the machine's: a folder's, or a file's as its name says what it is, in its language's hue. */
import type { ReactNode } from "react";
import { File, FileCode, FileImage, FileJson, FileText, Folder } from "lucide-react";
import { type FileLook, lookOf } from "../../core/files.ts";
import { cn } from "../ui/cn.ts";

/** Each look's icon. */
const ICONS: Readonly<Record<FileLook, typeof File>> = { code: FileCode, data: FileJson, text: FileText, image: FileImage, other: File };

/** The hues of the languages files are written in, by their extensions, as editors tell them apart; the rest take the muted ink. */
const FAMILIES: readonly (readonly [hue: string, extensions: readonly string[]])[] = [
	["text-blue-600 dark:text-blue-400", ["ts", "tsx", "mts", "cts", "c", "h", "cpp", "hpp", "py"]],
	["text-yellow-600 dark:text-yellow-400", ["js", "jsx", "mjs", "cjs", "json", "jsonc"]],
	["text-orange-600 dark:text-orange-400", ["zig", "zon", "rs", "swift", "html"]],
	["text-violet-600 dark:text-violet-400", ["css", "scss", "svg", "png", "jpg", "jpeg", "gif", "webp"]],
	["text-sky-600 dark:text-sky-400", ["md", "mdx"]],
	["text-emerald-600 dark:text-emerald-400", ["sh", "bash", "zsh"]],
	["text-rose-600 dark:text-rose-400", ["yaml", "yml", "toml"]],
	["text-cyan-600 dark:text-cyan-400", ["go"]],
];
const HUES: ReadonlyMap<string, string> = new Map(FAMILIES.flatMap(([hue, extensions]) => extensions.map((extension) => [extension, hue] as const)));

/** The hue of `name`'s language, by its extension; none for a language the table does not know. */
function hueOf(name: string): string | undefined {
	const dot = name.lastIndexOf(".");
	return dot <= 0 ? undefined : HUES.get(name.slice(dot + 1).toLowerCase());
}

/** The icon of `path`, by what it names. */
export function PathIcon(props: { readonly path: string; readonly kind: "file" | "directory"; readonly className?: string }): ReactNode {
	if (props.kind === "directory") return <Folder {...(props.className === undefined ? {} : { className: props.className })} />;
	const Icon = ICONS[lookOf(props.path)];
	return <Icon className={cn(props.className, hueOf(props.path))} />;
}
