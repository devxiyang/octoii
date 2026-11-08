/**
 * Links in a message, as markdown writes them, the person's and the model's alike: what one points at — a path of the
 * machine, from the thread's folder or whole, a line after it let go, or a page of the web; the link a mention writes to
 * a path; and a line with each link by its words, as a title shows it.
 */
import { nameOf } from "./files.ts";

/** What a link points at: a path of the machine — a folder's ending in a slash — or a page, by its address. */
export type LinkTarget = { readonly path: string } | { readonly url: string };

/** A scheme, as `https:` begins an address: two letters at least, which a drive's, as `C:` begins a path, is not. */
const SCHEME = /^[a-z][a-z0-9+.-]+:/i;

/** A line named after a path, as `#L12`, `#L12-L20` or `:12:4`. */
const LINE = /(#L\d+(-L?\d+)?|:\d+(:\d+)?)$/;

/** What `href` points at. */
export function targetOf(href: string): LinkTarget {
	if (href.startsWith("file:")) return pathOfFileUrl(href);
	if (SCHEME.test(href) || href.startsWith("#")) return { url: href };
	return { path: decoded(href).replace(LINE, "") };
}

/** The path a `file:` address names; the address itself where it reads as none. */
function pathOfFileUrl(href: string): LinkTarget {
	try {
		return { path: decoded(new URL(href).pathname).replace(LINE, "") };
	} catch {
		return { url: href };
	}
}

/** `href` with its escaped characters as they are, where it holds any. */
function decoded(href: string): string {
	try {
		return decodeURI(href);
	} catch {
		return href;
	}
}

/**
 * The markdown link a mention writes to a path of the thread's folder: its last name, a folder's with its slash, and
 * its path, in angle brackets where a space or a bracket would end it.
 */
export function linkTo(path: string, kind: "file" | "directory"): string {
	const slash = kind === "directory" ? "/" : "";
	const words = `${nameOf(path)}${slash}`.replace(/[[\]\\]/g, "\\$&");
	const written = `${path}${slash}`;
	const destination = /[\s()<>]/.test(written) ? `<${written.replace(/[<>]/g, "\\$&")}>` : written;
	return `[${words}](${destination})`;
}

/** Each markdown link in a line: its words, escapes and all, then where it points. */
const LINKS = /\[((?:\\.|[^\]\\])*)\]\((?:<(?:\\.|[^>\\])*>|[^)\s]*)\)/g;

/** `text` with each link by its words, as a line that names the message shows it. */
export function linksAsWords(text: string): string {
	return text.replace(LINKS, (_link, words: string) => words.replace(/\\(.)/g, "$1"));
}
