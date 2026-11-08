/**
 * A keyboard shortcut as the interface writes it — `mod+shift+d`, or a key alone, `/` — read into what a key press must
 * be. One held with Cmd or Ctrl is known by where its key is on the keyboard, so Shift's character on it does not
 * matter; a key alone is known by the character it types, wherever the layout puts it.
 */

/**
 * A shortcut, read: whether Cmd or Ctrl is held with it, Shift and Alt pressed or not, its key's code, and the
 * character its key types.
 */
export type Shortcut = { readonly mod: boolean; readonly shift: boolean; readonly alt: boolean; readonly code: string; readonly key: string };

/** The codes of the punctuation a shortcut names. */
const PUNCTUATION: Readonly<Record<string, string>> = {
	".": "Period",
	",": "Comma",
	"'": "Quote",
	"/": "Slash",
	";": "Semicolon",
	"[": "BracketLeft",
	"]": "BracketRight",
};

/** `spec`: `mod+` then `alt+` and `shift+` where it takes them, then a letter, a digit or a punctuation mark; or that key alone. */
export function shortcutOf(spec: string): Shortcut {
	const parts = spec.split("+");
	const key = parts.at(-1) ?? "";
	const code = /^[a-z]$/i.test(key) ? `Key${key.toUpperCase()}` : /^\d$/.test(key) ? `Digit${key}` : (PUNCTUATION[key] ?? key);
	return { mod: parts.includes("mod"), shift: parts.includes("shift"), alt: parts.includes("alt"), code, key };
}

/** What of a key press a shortcut is told by. */
export type KeyPress = {
	readonly metaKey: boolean;
	readonly ctrlKey: boolean;
	readonly altKey: boolean;
	readonly shiftKey: boolean;
	readonly code: string;
	readonly key: string;
};

/**
 * Whether a key press is `shortcut`: one held with Cmd or Ctrl, Alt and Shift as it says, on its key; a key alone, its
 * character typed with neither Cmd, Ctrl nor Alt — Shift as the layout needs it.
 */
export function pressed(shortcut: Shortcut, event: KeyPress): boolean {
	if (!shortcut.mod) return !(event.metaKey || event.ctrlKey || event.altKey) && event.key === shortcut.key;
	return (event.metaKey || event.ctrlKey) && event.altKey === shortcut.alt && event.shiftKey === shortcut.shift && event.code === shortcut.code;
}

/** The caps of the keys a shortcut holds down. */
const CAPS: Readonly<Record<string, string>> = { mod: "⌘", alt: "⌥", shift: "⇧" };

/** `spec` as a shortcut's caps show it: ⌘, ⌥, ⇧ and the key. */
export function shortcutLabel(spec: string): string {
	return spec
		.split("+")
		.map((part) => CAPS[part] ?? part.toUpperCase())
		.join("");
}
