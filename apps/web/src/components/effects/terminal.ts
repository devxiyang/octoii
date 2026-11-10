/**
 * A terminal drawn in an element: libghostty-vt's surface mounted once the element is there, the terminal followed in a
 * view the size of the surface's room once the room holds a grid — as it mounts, or as its room is first told — its
 * screen drawn anew at the size the node sizes it to, then what it writes; the person's keys and the room's size, as it
 * settles, sent to it; its colours the page's own, taken again as the theme changes.
 */
import { useCallback } from "react";
import type { TerminalView } from "@octoii-works/octoii-client";
import { useClient } from "@octoii-works/octoii-client/react";
import { type GridCells, mountTerminal, type TerminalColors, type TerminalSurface } from "@octoii-works/octoii-terminal";
import { ANSI_DARK, ANSI_LIGHT, TERMINAL_FONT_SIZE } from "../../core/terminal.ts";
import { failed } from "../state/notices.ts";

/** The ref that mounts the terminal `terminal` in the element it is given, and takes it out as the element goes. */
export function useTerminalView(terminal: string): (element: HTMLDivElement | null) => (() => void) | undefined {
	const client = useClient();
	return useCallback(
		(element: HTMLDivElement | null) => {
			if (element === null) return undefined;
			let surface: TerminalSurface | undefined;
			let view: TerminalView | undefined;
			let stopTheme: (() => void) | undefined;
			let gone = false;
			const follow = (mounted: TerminalSurface, size: GridCells): void => {
				view = client.terminal(terminal, size, {
					screen: (drawn, grid) => {
						mounted.setGrid(grid);
						mounted.replay(drawn);
					},
					output: (bytes) => mounted.write(bytes),
				});
			};
			mountTerminal(element, {
				font: { family: monoFamily(), size: TERMINAL_FONT_SIZE },
				colors: pageColors(element),
				selection: selectionColor(),
				onInput: (data) => view?.write(data),
				onResize: (size) => {
					if (view !== undefined) view.resize(size);
					else if (surface !== undefined) follow(surface, size);
				},
				onLink: (url) => void window.open(url, "_blank", "noopener,noreferrer"),
			}).then(
				(mounted) => {
					if (gone) return mounted.dispose();
					surface = mounted;
					stopTheme = followTheme(() => mounted.setColors(pageColors(element), selectionColor()));
					if (mounted.size.rows > 0 && mounted.size.cols > 0) follow(mounted, mounted.size);
					mounted.focus();
				},
				(error: unknown) => failed("The terminal could not be drawn", error),
			);
			return () => {
				gone = true;
				view?.stop();
				stopTheme?.();
				surface?.dispose();
			};
		},
		[client, terminal],
	);
}

/** The page's monospace font, as its stylesheet names it. */
function monoFamily(): string {
	return getComputedStyle(document.documentElement).getPropertyValue("--font-mono").trim() || "monospace";
}

/** The terminal's colours: the element's background and text, the page's ANSI set for its scheme. */
function pageColors(element: HTMLElement): TerminalColors {
	const style = getComputedStyle(element);
	const foreground = rgbOf(style.color);
	return {
		foreground,
		background: rgbOf(style.backgroundColor),
		cursor: foreground,
		palette: document.documentElement.classList.contains("dark") ? ANSI_DARK : ANSI_LIGHT,
	};
}

/** The selection's colour: the page's primary colour, see-through. */
function selectionColor(): string {
	const primary = getComputedStyle(document.documentElement).getPropertyValue("--primary").trim();
	const rgb = rgbOf(primary || "#3b82f6");
	return `rgb(${String((rgb >> 16) & 0xff)} ${String((rgb >> 8) & 0xff)} ${String(rgb & 0xff)} / 0.3)`;
}

/** Calls back as the page's scheme or palette changes: the root's class or variables. */
function followTheme(changed: () => void): () => void {
	const observer = new MutationObserver(changed);
	observer.observe(document.documentElement, { attributes: true, attributeFilter: ["class", "style"] });
	return () => observer.disconnect();
}

let probe: CanvasRenderingContext2D | null | undefined;

/** A CSS colour of any space, as 0xRRGGBB: a pixel painted with it is read back. */
function rgbOf(color: string): number {
	probe ??= document.createElement("canvas").getContext("2d", { willReadFrequently: true });
	if (probe === null) return 0;
	probe.clearRect(0, 0, 1, 1);
	probe.fillStyle = color;
	probe.fillRect(0, 0, 1, 1);
	const [red = 0, green = 0, blue = 0] = probe.getImageData(0, 0, 1, 1).data;
	return (red << 16) | (green << 8) | blue;
}
