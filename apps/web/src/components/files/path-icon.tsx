/** The icon of a path of the machine's: a folder's, or a file's as its name says what it is, in its language's hue. */
import type { ReactNode } from "react";
import { File, FileCode, FileImage, FileJson, FileText, Folder } from "lucide-react";
import { type FileLook, lookOf } from "../../core/files.ts";
import type { Hue } from "../../core/monogram.ts";
import { cn } from "../ui/cn.ts";
import { hueClassOf } from "../ui/monogram.tsx";

/** Each look's icon. */
const ICONS: Readonly<Record<FileLook, typeof File>> = { code: FileCode, data: FileJson, text: FileText, image: FileImage, other: File };

/** The hues of the languages files are written in, by their extensions, as editors tell them apart; the rest take the muted ink. */
const FAMILIES: readonly (readonly [hue: Hue, extensions: readonly string[]])[] = [
	["blue", ["ts", "tsx", "mts", "cts", "c", "h", "cpp", "hpp", "py"]],
	["amber", ["js", "jsx", "mjs", "cjs", "json", "jsonc"]],
	["orange", ["zig", "zon", "rs", "swift", "html"]],
	["violet", ["css", "scss", "svg", "png", "jpg", "jpeg", "gif", "webp"]],
	["indigo", ["md", "mdx"]],
	["emerald", ["sh", "bash", "zsh"]],
	["rose", ["yaml", "yml", "toml"]],
	["cyan", ["go"]],
];
const HUES: ReadonlyMap<string, Hue> = new Map(FAMILIES.flatMap(([hue, extensions]) => extensions.map((extension) => [extension, hue] as const)));

/** The hue of `name`'s language, by its extension; none for a language the table does not know. */
function hueOf(name: string): Hue | undefined {
	const dot = name.lastIndexOf(".");
	return dot <= 0 ? undefined : HUES.get(name.slice(dot + 1).toLowerCase());
}

/** The icon of `path`, by what it names. */
export function PathIcon(props: { readonly path: string; readonly kind: "file" | "directory"; readonly className?: string }): ReactNode {
	if (props.kind === "directory") return <Folder {...(props.className === undefined ? {} : { className: props.className })} />;
	const Icon = ICONS[lookOf(props.path)];
	const hue = hueOf(props.path);
	return <Icon className={cn(props.className, hue === undefined ? undefined : hueClassOf(hue))} />;
}
