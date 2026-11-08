/**
 * A diff's lines as text, in a code well: each added one green, each removed one red, each across the well's width;
 * each head — a file's, a hunk's, a note — quiet.
 */
import type { ReactNode } from "react";
import { type DiffTone, diffTones } from "../../core/diff.ts";

/** Each tone's look. */
const TONES: Readonly<Record<DiffTone, string>> = {
	added: "bg-diff-add-surface text-diff-add",
	removed: "bg-diff-remove-surface text-diff-remove",
	kept: "",
	head: "text-muted-foreground",
};

/** The lines of the diff `text`, their tints reaching the well's edges past its padding of `px-3`. */
export function DiffLines(props: { readonly text: string }): ReactNode {
	const lines = props.text.split("\n");
	const tones = diffTones(lines);
	return lines.map((line, index) => (
		<span key={`${String(index)} ${line}`} className={`-mx-3 block px-3 ${TONES[tones[index] ?? "kept"]}`}>
			{line === "" ? " " : line}
		</span>
	));
}
