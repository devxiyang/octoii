/**
 * The directives a message's Markdown may hold, as CommonMark's proposal for generic directives writes them, given their
 * meaning on the page: `::page{id="…"}`, on a line of its own, the page of the thread's browser it names, drawn as its
 * card. Any other directive — and every one within a line, `:name`, which ordinary words hold, as `Error:failed` or
 * `10:30` do — is given back as the words it was written in, so nothing written is lost.
 */
import type { Nodes, Root } from "mdast";

/** The element a page a message points at is drawn as, its page named by the property `page`. */
export const PAGE_ELEMENT = "thread-page";

/** Gives the directives of a message's tree their meaning, read against the Markdown it was parsed from. */
export function remarkDirectives(): (tree: Root, file: { readonly value: unknown }) => void {
	return (tree, file) => {
		meant(tree, String(file.value));
	};
}

/** `node` and what it holds, each directive given its meaning or its words. */
function meant(node: Nodes, source: string): void {
	if ("children" in node) for (const child of node.children) meant(child, source);
	if (node.type === "leafDirective" && node.name === "page") {
		const page = node.attributes?.["id"];
		if (typeof page === "string" && page !== "") {
			Object.assign(node, { data: { hName: PAGE_ELEMENT, hProperties: { page } } });
			return;
		}
	}
	if (node.type === "textDirective") Object.assign(node, { value: writtenOf(node, source) });
	if (node.type === "leafDirective" || node.type === "containerDirective") {
		Object.assign(node, { data: { hName: "p", hChildren: [{ type: "text", value: writtenOf(node, source) }] } });
	}
}

/**
 * The words `node` was written in, as `source` holds them — which, as what makes the page's elements of a tree reads a
 * node with a value, a directive within a line is given as, text; one of its own, as a paragraph of that text.
 */
function writtenOf(node: Nodes, source: string): string {
	const from = node.position?.start.offset;
	const to = node.position?.end.offset;
	return from === undefined || to === undefined ? "" : source.slice(from, to);
}
