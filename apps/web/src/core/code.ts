/**
 * A code block of a message: the language its fence names, as the highlighter knows it — by its id or by any other
 * name it answers to — and, of a long block, the lines that stand for it till the reader asks for the rest.
 */
import { bundledLanguagesInfo } from "shiki/langs";

/** A language the highlighter knows: the id it is asked for by, and its name as it is written. */
export type Language = { readonly id: string; readonly name: string };

/** Each name a fence may give a language, and the language it names. */
const LANGUAGES: ReadonlyMap<string, Language> = new Map(
	bundledLanguagesInfo.flatMap((info) => {
		const language: Language = { id: info.id, name: info.name };
		return [info.id, ...(info.aliases ?? [])].map((name) => [name, language] as const);
	}),
);

/** The language a fence names as `written`; none where the highlighter knows none by it, whose block is plain text. */
export function languageOf(written: string): Language | undefined {
	return LANGUAGES.get(written.toLowerCase());
}

/** How many lines of a long block stand for it. */
const HEAD_LINES = 20;

/** How many lines a block may hold and still be shown whole: a few past its head, which are not worth a fold. */
const WHOLE_LINES = 28;

/** A long block's fold: the lines that stand for it, and how many it holds in all. */
export type CodeFold = { readonly head: string; readonly lines: number };

/** The fold of `code`; none where it is short enough to be shown whole. Its head ends on a line that says something, not on a blank one. */
export function codeFoldOf(code: string): CodeFold | undefined {
	const lines = code.split("\n");
	if (lines.length <= WHOLE_LINES) return undefined;
	return headOf(lines);
}

/**
 * The fold of code still being written: its head as a long block's fold has it, once it holds more — so what is shown
 * never holds more lines than the block may once whole, and nothing shrinks as it is folded.
 */
export function writtenFoldOf(code: string): CodeFold | undefined {
	const lines = code.split("\n");
	return lines.length <= HEAD_LINES ? undefined : headOf(lines);
}

/** The head of code's `lines`, ending on a line that says something, and how many lines it stands for. */
function headOf(lines: readonly string[]): CodeFold {
	return { head: lines.slice(0, HEAD_LINES).join("\n").trimEnd(), lines: lines.length };
}
