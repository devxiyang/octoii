/**
 * The browser as the interface shows it: what the address bar makes of what is typed — an address with its scheme, a
 * host given the scheme it is reached by, or else a search — how a page is named on its tab, the modifiers a key or a
 * click is told with, and the editing a shortcut stands for.
 */
import type { PageListed } from "@octoii-works/octoii-client";

/** What the address bar searches with, where what is typed is no address. */
const SEARCH = "https://duckduckgo.com/?q=";

/** The address what is typed in the address bar names: itself where it has a scheme; a host, reached over https — over http where it is this machine's or a bare IP — and else a search for it. */
export function addressOf(typed: string): string {
	const text = typed.trim();
	if (/^[a-z][a-z0-9+.-]*:/i.test(text) && !/^(localhost|[\d.]+):\d+/i.test(text)) return text;
	if (/\s/.test(text) || text === "") return `${SEARCH}${encodeURIComponent(text)}`;
	const host = text.split(/[/?#]/, 1)[0] ?? "";
	if (/^(localhost|127(\.\d+){3}|\[::1\]|(\d+\.){3}\d+)(:\d+)?$/i.test(host)) return `http://${text}`;
	if (host.includes(".")) return `https://${text}`;
	return `${SEARCH}${encodeURIComponent(text)}`;
}

/** A page's name on its tab: its title, else the host it is on, else New tab where it is blank. */
export function pageName(page: PageListed): string {
	const title = page.title.trim();
	if (title !== "" && title !== page.url) return title;
	if (page.url === "" || page.url === "about:blank") return "New tab";
	try {
		return new URL(page.url).host || page.url;
	} catch {
		return page.url;
	}
}

/** The address bar's words for a page's address: none for a blank page, so it waits for one. */
export function shownAddress(url: string): string {
	return url === "about:blank" ? "" : url;
}

/** The modifiers held, as the browser's protocol counts them: Alt 1, Ctrl 2, Meta 4, Shift 8. */
export function modifiersOf(event: { readonly altKey: boolean; readonly ctrlKey: boolean; readonly metaKey: boolean; readonly shiftKey: boolean }): number {
	return (event.altKey ? 1 : 0) | (event.ctrlKey ? 2 : 0) | (event.metaKey ? 4 : 0) | (event.shiftKey ? 8 : 0);
}

/** The text a key types: its character, a return's carriage return, nothing for a key that types none. */
export function typedBy(key: string): string | undefined {
	if (key === "Enter") return "\r";
	return [...key].length === 1 ? key : undefined;
}

/** The editing commands of the shortcuts Cmd or Ctrl holds, by the key and Shift: the browser on the node, headless, binds none of them. */
const EDITING: Readonly<Record<string, readonly string[]>> = { KeyA: ["selectAll"], KeyZ: ["undo"], "shift+KeyZ": ["redo"], KeyY: ["redo"] };

/** The editing commands a key pressed stands for in a page: those of a shortcut of Cmd or Ctrl, none for any other key. */
export function editingOf(event: {
	readonly altKey: boolean;
	readonly ctrlKey: boolean;
	readonly metaKey: boolean;
	readonly shiftKey: boolean;
	readonly code: string;
}): readonly string[] | undefined {
	if (!(event.metaKey || event.ctrlKey) || event.altKey) return undefined;
	return EDITING[`${event.shiftKey ? "shift+" : ""}${event.code}`];
}
