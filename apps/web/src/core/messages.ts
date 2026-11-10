/**
 * A person's message as the page sets it: whether its words run long, by how many lines a bubble would wrap them
 * into, about — a long message is shown by its first lines till the reader asks for the rest.
 */

/** How many columns a line of a bubble holds, about: a letter takes one, a wide character — a Chinese one, a full-width form — two. */
const LINE_COLUMNS = 72;

/** How many lines a message may run to and still be shown whole. */
const WHOLE_LINES = 12;

/** The characters that take two columns: the East Asian scripts' and the full-width forms. */
const WIDE = /[ᄀ-ᅟ⺀-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦]/g;

/** How many lines the words `text` run to, about: each line the person broke, and each a long one of them wraps into. */
function linesOf(text: string): number {
	let lines = 0;
	for (const line of text.split("\n")) {
		const columns = line.length + (line.match(WIDE)?.length ?? 0);
		lines += Math.max(1, Math.ceil(columns / LINE_COLUMNS));
	}
	return lines;
}

/** Whether the words `text` run long: to more lines than a bubble shows whole. */
export function isLong(text: string): boolean {
	return linesOf(text) > WHOLE_LINES;
}
