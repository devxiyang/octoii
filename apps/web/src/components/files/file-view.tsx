/**
 * A file of the machine's as the files surface shows it: the names on the way to it, from the folder the tree shows,
 * with what the surface puts beside them; its lines, numbered and coloured as its language reads, a page at a time, the
 * next read as the person asks for it, its long lines wrapped where the device says so; an image; a PDF, opened in the
 * browser's own viewer in a tab of its own; that it is binary; or the node's words where it could not be read.
 */
import type { ReactNode } from "react";
import type { FilePage } from "@octoii-works/octoii-client";
import { File } from "@pierre/diffs/react";
import { bytesText, crumbsOf, nameOf } from "../../core/files.ts";
import { usePages } from "../effects/pages.ts";
import { CODE_THEMES, useDarkPage } from "../effects/theme.ts";

/** What the view is given: the file at `path`, under the folder `root` the tree shows; whether its long lines wrap; what stands beside its names. */
export type FileViewProps = { readonly root: string; readonly path: string; readonly wrap: boolean; readonly actions: ReactNode };

/** The view. */
export function FileView(props: FileViewProps): ReactNode {
	const read = usePages("files.read", { path: props.path, offset: 1 }, (last) =>
		last.type === "text" && last.more ? { path: props.path, offset: last.from + last.lines.length } : undefined,
	);
	return (
		<>
			<div className="flex h-control-lg shrink-0 items-center gap-1 ps-3 pe-2">
				<Crumbs root={props.root} path={props.path} />
				<span className="flex-1" />
				{props.actions}
			</div>
			<div className="min-h-0 flex-1 overflow-auto">
				{read === undefined ? (
					<Note>Reading…</Note>
				) : "pages" in read ? (
					<Contents pages={read.pages} path={props.path} wrap={props.wrap} readMore={read.readMore} />
				) : null}
				{read?.failure === undefined ? null : <Note>{read.failure}</Note>}
			</div>
		</>
	);
}

/** The names on the way to the file, its own last. */
function Crumbs(props: { readonly root: string; readonly path: string }): ReactNode {
	const crumbs = crumbsOf(props.root, props.path);
	return (
		<div className="flex min-w-0 items-center gap-1 overflow-hidden text-xs text-muted-foreground">
			{crumbs.map((crumb) => (
				<span key={crumb.path} className="flex min-w-0 items-center gap-1 last:shrink-0">
					{crumb.path === props.root ? null : <span className="text-faint-foreground">›</span>}
					<span className={crumb.path === props.path ? "text-foreground" : "truncate"}>{crumb.name}</span>
				</span>
			))}
		</div>
	);
}

/** A line of words where a page shows nothing else. */
function Note(props: { readonly children: ReactNode }): ReactNode {
	return <p className="px-4 py-2 text-xs text-muted-foreground">{props.children}</p>;
}

/** What the file's pages hold: its lines, an image, a PDF, or that it is binary, as its first page says. */
function Contents(props: {
	readonly pages: readonly [FilePage, ...FilePage[]];
	readonly path: string;
	readonly wrap: boolean;
	readonly readMore: (() => void) | undefined;
}): ReactNode {
	const [first] = props.pages;
	switch (first.type) {
		case "text":
			return (
				<TextFile
					name={nameOf(props.path)}
					lines={props.pages.flatMap((page) => (page.type === "text" ? page.lines : []))}
					wrap={props.wrap}
					readMore={props.readMore}
				/>
			);
		case "image":
			return <img className="m-4 max-w-[calc(100%-2rem)]" alt={nameOf(first.path)} src={`data:${first.media_type};base64,${first.data}`} />;
		case "pdf":
			return <PdfNote size={first.size} data={first.data} />;
		case "binary":
			return <Note>A binary file, {bytesText(first.size)}.</Note>;
	}
}

/** The lines read of a file, numbered and coloured as its name says its language is; and where more follow, what reads them. */
function TextFile(props: {
	readonly name: string;
	readonly lines: readonly string[];
	readonly wrap: boolean;
	readonly readMore: (() => void) | undefined;
}): ReactNode {
	const dark = useDarkPage();
	if (props.lines.length === 0) return <Note>An empty file.</Note>;
	return (
		<>
			<div className="code-view">
				<File
					file={{ name: props.name, contents: props.lines.join("\n") }}
					disableWorkerPool
					options={{ theme: CODE_THEMES, themeType: dark ? "dark" : "light", overflow: props.wrap ? "wrap" : "scroll", disableFileHeader: true }}
				/>
			</div>
			{props.readMore === undefined ? null : (
				<button type="button" onClick={props.readMore} className="px-4 py-2 text-xs text-muted-foreground hover:text-foreground">
					Show more lines
				</button>
			)}
		</>
	);
}

/** How long the address a PDF opens at lasts: past the time its tab takes to read it. */
const OPENED_MS = 60_000;

/** A PDF: its length, and what opens it in the browser's own viewer, in a tab of its own. */
function PdfNote(props: { readonly size: number; readonly data: string }): ReactNode {
	const open = (): void => {
		const bytes = Uint8Array.from(atob(props.data), (char) => char.charCodeAt(0));
		const url = URL.createObjectURL(new Blob([bytes], { type: "application/pdf" }));
		window.open(url, "_blank", "noopener,noreferrer");
		setTimeout(() => URL.revokeObjectURL(url), OPENED_MS);
	};
	return (
		<p className="flex items-center gap-2 px-4 py-2 text-xs text-muted-foreground">
			A PDF, {bytesText(props.size)}.
			<button type="button" onClick={open} className="text-foreground hover:underline">
				Open in a new tab
			</button>
		</p>
	);
}
