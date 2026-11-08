/**
 * Octoii's terminal in the browser: libghostty-vt in WebAssembly reads what the program writes, a canvas draws it,
 * and the page's keys, mouse and clipboard go back to the program.
 */
import { loadGhostty } from "./load.ts";
import { TerminalSurface, type TerminalOptions } from "./surface.ts";

export type { Rgb } from "./frame.ts";
export type { TerminalFont } from "./paint.ts";
export type { GridCells, TerminalSurface, TerminalOptions } from "./surface.ts";
export type { TerminalColors } from "./terminal.ts";

/** Draws a terminal in an element, which it fills; the element is positioned and sized by its page. */
export async function mountTerminal(element: HTMLElement, options: TerminalOptions): Promise<TerminalSurface> {
	return new TerminalSurface(element, await loadGhostty(), options);
}
