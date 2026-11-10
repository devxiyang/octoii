/**
 * A code block of a message, in a well: on one line its language, by its name, and a button that copies the whole of
 * it; then its lines, coloured as the language reads by the highlighter the files' view draws with, a long line
 * scrolled within the well — a diff's lines green and red instead; and, where the block is long, its first lines
 * alone, with what shows the rest.
 */
import { type CSSProperties, type ReactNode, useState } from "react";
import { File } from "@pierre/diffs/react";
import { codeFoldOf, languageOf, writtenFoldOf } from "../../core/code.ts";
import { DiffLines } from "../diff/diff-lines.tsx";
import { CODE_THEMES, useDarkPage } from "../effects/theme.ts";
import { CopyButton } from "../ui/copy-button.tsx";

declare module "react" {
	interface CSSProperties {
		/** How many lines a message's code holds, which its well is as tall as before they are drawn. */
		"--code-lines"?: number;
	}
}

/** What the block is given: the language its fence names, as it was written, and its code. */
export type CodeBlockProps = { readonly language: string; readonly code: string };

/** The block. */
export function CodeBlock(props: CodeBlockProps): ReactNode {
	const [whole, setWhole] = useState(false);
	const language = languageOf(props.language);
	const fold = codeFoldOf(props.code);
	const shown = fold === undefined || whole ? props.code : fold.head;
	return (
		<div className="well my-3 overflow-hidden">
			<div className="flex h-control items-center justify-between ps-3 pe-1 text-xs text-muted-foreground">
				<span>{language?.name ?? props.language}</span>
				<CopyButton text={props.code} label="Copy code" />
			</div>
			{language?.id === "diff" ? <Diff text={shown} /> : <Lines language={language?.id ?? "text"} code={shown} />}
			{fold === undefined ? null : (
				<button
					type="button"
					aria-expanded={whole}
					onClick={() => setWhole(!whole)}
					className="flex h-control w-full items-center border-t border-border px-3 text-xs text-muted-foreground hover:text-foreground"
				>
					{whole ? "Show fewer lines" : `Show all ${String(fold.lines)} lines`}
				</button>
			)}
		</div>
	);
}

/**
 * A code block still being written: in the same well, its lines plain and as tall as they will be coloured, so nothing
 * moves as it is coloured once it is whole; past a long block's head, that head alone and how many lines it holds, where
 * the whole block's button stands — so it grows only as the whole block may, and never shrinks as it folds.
 */
export function CodeBeingWritten(props: CodeBlockProps): ReactNode {
	const language = languageOf(props.language);
	const fold = writtenFoldOf(props.code);
	const shown = fold === undefined ? props.code : fold.head;
	return (
		<div className="well my-3 overflow-hidden">
			<div className="flex h-control items-center ps-3 text-xs text-muted-foreground">{language?.name ?? props.language}</div>
			<div style={{ "--code-lines": shown.split("\n").length }} className="code-well">
				<pre className="overflow-x-auto py-(--diffs-gap-block) ps-[1ch] leading-(--diffs-line-height) [tab-size:var(--diffs-tab-size,2)]">{shown}</pre>
			</div>
			{fold === undefined ? null : (
				<div className="flex h-control w-full items-center border-t border-border px-3 text-xs text-muted-foreground tabular-nums">{fold.lines} lines</div>
			)}
		</div>
	);
}

/** Code's lines, coloured as `language` reads, plain at first where its grammar is not read yet; their room kept before they are drawn. */
function Lines(props: { readonly language: string; readonly code: string }): ReactNode {
	const dark = useDarkPage();
	const room: CSSProperties = { "--code-lines": props.code.split("\n").length };
	return (
		<div style={room} className="code-well">
			<File
				file={{ name: "", contents: props.code, lang: props.language }}
				disableWorkerPool
				options={{ theme: CODE_THEMES, themeType: dark ? "dark" : "light", overflow: "scroll", disableFileHeader: true, disableLineNumbers: true }}
			/>
		</div>
	);
}

/** A diff's lines, as text. */
function Diff(props: { readonly text: string }): ReactNode {
	return (
		<pre className="overflow-x-auto px-3 py-2 font-mono text-ui">
			<code>
				<DiffLines text={props.text} />
			</code>
		</pre>
	);
}
