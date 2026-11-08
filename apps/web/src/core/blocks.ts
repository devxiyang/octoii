/**
 * Markdown's blocks, as a reply is shown a block at a time: its paragraphs, lists, code blocks and tables, each set
 * apart from the next by a blank line — but within a fenced code block, and where what follows is indented, which goes
 * on with the block before it, as a list item's paragraphs do; and of words still being written, those whose blocks
 * are whole, the block being written left out.
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

/** Of words still being written, those whose blocks are whole: up to the start of the last, which may grow yet. */
export function settledOf(words: string): string {
	const last = blocksOf(words).at(-1);
	return last === undefined ? "" : words.slice(0, last.start).replace(/\n+$/, "");
}
