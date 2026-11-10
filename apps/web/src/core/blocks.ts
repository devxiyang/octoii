/**
 * Markdown's blocks, as a reply is drawn a block at a time: its paragraphs, lists, code blocks and tables, each set
 * apart from the next by a blank line — but within a fenced code block, and where what follows is indented, which goes
 * on with the block before it, as a list item's paragraphs do; whether a block's code fence is still open, its code
 * still being written; and what of a block being written can be shown as it will stand.
 */

/** A block of markdown: where it begins in its text, which it is known by as the text grows, and its words. */
export type Block = { readonly start: number; readonly text: string };

/** The blocks of `text`, in order. */
export function blocksOf(text: string): readonly Block[] {
	const blocks: Block[] = [];
	let fence: string | undefined;
	let start = 0;
	let offset = 0;
	let blank = false;
	for (const line of text.split("\n")) {
		const marker = /^ {0,3}(`{3,}|~{3,})/.exec(line)?.[1];
		if (fence === undefined && blank && line.trim() !== "" && !/^[ \t]/.test(line)) {
			push(blocks, text, start, offset);
			start = offset;
		}
		if (marker !== undefined && (fence === undefined || marker.startsWith(fence))) fence = fence === undefined ? marker.slice(0, 3) : undefined;
		blank = fence === undefined && line.trim() === "";
		offset += line.length + 1;
	}
	push(blocks, text, start, text.length);
	return blocks;
}

/** The block of `text` from `start` to `end`, its blank lines trimmed, onto `blocks`; nothing where it holds no words. */
function push(blocks: Block[], text: string, start: number, end: number): void {
	const words = text.slice(start, end).replace(/\n+$/, "");
	if (words.trim() !== "") blocks.push({ start, text: words });
}

/** Whether a block opens a code fence it does not close yet: its code still being written. */
export function fenceOpen(block: string): boolean {
	const lines = block.split("\n");
	const opener = /^ {0,3}(`{3,}|~{3,})/.exec(lines[0] ?? "")?.[1];
	if (opener === undefined) return false;
	const closer = new RegExp(`^ {0,3}${opener[0] === "`" ? "`" : "~"}{${String(opener.length)},}\\s*$`);
	return !lines.slice(1).some((line) => closer.test(line));
}

/** A table's delimiter row: the dashes under its header, between pipes, a colon at either end of each where a column is aligned. */
const DELIMITER = /^ {0,3}\|?(?:\s*:?-+:?\s*\|)+\s*(?::?-+:?\s*)?$/;

/**
 * Of a block still being written, what can be shown as it will stand: all of it, but a table's header till the row under
 * it that makes it a table is whole — words between pipes till then, which would show as a paragraph and then jump.
 */
export function showableOf(block: string): string {
	const lines = block.split("\n");
	if (!/^ {0,3}\|/.test(lines[0] ?? "")) return block;
	// The row under the header is whole once a line follows it.
	return lines.length > 2 && DELIMITER.test(lines[1] ?? "") ? block : "";
}
