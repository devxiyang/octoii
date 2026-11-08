/**
 * The terminal as the interface shows it: the sixteen colours programs pick by number, one set for a light page and one
 * for a dark, its font's size, and how a terminal is named on its tab.
 */
import type { TerminalListed } from "@octoii-works/octoii-client";

/** The sixteen ANSI colours on a light page: black, red, green, yellow, blue, magenta, cyan, white, then their bright forms. */
export const ANSI_LIGHT: readonly number[] = [
	0x24292f, 0xc4362e, 0x2a7f3a, 0x8f6400, 0x2f5fc4, 0x8a3fb4, 0x137a83, 0x8c959f, 0x57606a, 0xdc4a40, 0x36994a, 0xae7c00, 0x3d78e6, 0xa452d4, 0x1894a0,
	0xb4bcc6,
];

/** The sixteen ANSI colours on a dark page. */
export const ANSI_DARK: readonly number[] = [
	0x3a3f47, 0xf0767a, 0x8bd08a, 0xf2c56b, 0x78a6f5, 0xc595ea, 0x6acdd4, 0xc9ced6, 0x5f6773, 0xff8d90, 0xa6e3a2, 0xffd88a, 0x9bc0ff, 0xdbb0ff, 0x8de3e8,
	0xf3f5f7,
];

/** The terminal's font size, in CSS pixels. */
export const TERMINAL_FONT_SIZE = 12;

/** A terminal's name on its tab: the title its program set, or its number in the thread. */
export function terminalName(terminal: TerminalListed): string {
	const title = terminal.title?.trim() ?? "";
	return title === "" ? `Terminal ${String(terminal.number)}` : title;
}
