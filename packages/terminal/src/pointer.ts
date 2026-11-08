/*
 * Adapted from MIT-licensed code, MIT License, Copyright (c) 2026 T3 Tools Inc.; see THIRD_PARTY_NOTICES.
 * Our changes: selection by the module's gesture; mouse reports, the wheel and links in one listener on the canvas.
 */
import type { Frame, Row } from "./frame.ts";
import { IS_APPLE } from "./input.ts";
import { keyInput, modsOf } from "./keys.ts";
import type { CellRange } from "./paint.ts";
import { MODES, type MouseInput, type PointerAt, type SurfaceGeometry, type VtTerminal } from "./terminal.ts";

/** What the pointer reaches: the terminal, the program, and the surface's grid and frame. */
export interface PointerHost {
	readonly terminal: VtTerminal;
	/** Sends input to the program without moving the view. */
	readonly send: (data: string) => void;
	readonly scroll: (rows: number) => void;
	readonly render: () => void;
	readonly at: (clientX: number, clientY: number) => PointerAt;
	readonly geometry: () => SurfaceGeometry;
	readonly frame: () => Frame | undefined;
	readonly setLink: (link: CellRange | undefined) => void;
	readonly openLink: (url: string) => void;
	readonly focus: () => void;
}

/** Text that reads as a web address. */
const URL_PATTERN = /\bhttps?:\/\/[^\s<>"'`{}|\\^]+[^\s<>"'`{}|\\^.,;:!?)\]]/g;

/** How often a selection that is dragged past an edge scrolls, and how many rows at most each time. */
const AUTOSCROLL_MS = 50;
const AUTOSCROLL_MAX_ROWS = 8;
const AUTOSCROLL_RAMP_PX = 60;

/** The canvas's pointer: selecting, mouse reports for a program that asks, the wheel, and links. */
export class TerminalPointer {
	readonly #canvas: HTMLCanvasElement;
	readonly #host: PointerHost;
	readonly #abort = new AbortController();
	#mode: "idle" | "selecting" | "reporting" = "idle";
	#wheelRows = 0;
	#autoscroll: { timer: ReturnType<typeof setInterval>; clientX: number; clientY: number } | undefined;
	#link: { range: CellRange; url: string } | undefined;

	constructor(canvas: HTMLCanvasElement, host: PointerHost) {
		this.#canvas = canvas;
		this.#host = host;
		const options = { signal: this.#abort.signal };
		canvas.addEventListener("pointerdown", (event) => this.#down(event), options);
		canvas.addEventListener("pointermove", (event) => this.#move(event), options);
		canvas.addEventListener("pointerup", (event) => this.#up(event), options);
		canvas.addEventListener("pointercancel", (event) => this.#up(event), options);
		canvas.addEventListener("pointerleave", () => this.#showLink(undefined), options);
		canvas.addEventListener("wheel", (event) => this.#wheel(event), { ...options, passive: false });
	}

	/** Stops listening. */
	dispose(): void {
		this.#stopAutoscroll();
		this.#abort.abort();
	}

	#down(event: PointerEvent): void {
		// The press's own default would move the focus off the textarea, to the page.
		event.preventDefault();
		this.#host.focus();
		if (this.#link !== undefined && isLinkClick(event)) {
			this.#host.openLink(this.#link.url);
			return;
		}
		this.#canvas.setPointerCapture(event.pointerId);
		if (this.#reports(event)) {
			this.#mode = "reporting";
			this.#report(event, "PRESS");
			return;
		}
		if (event.button !== 0) return;
		this.#mode = "selecting";
		this.#host.terminal.selectPress(this.#host.at(event.clientX, event.clientY), BigInt(Math.round(event.timeStamp * 1e6)));
		this.#host.render();
	}

	#move(event: PointerEvent): void {
		if (this.#mode === "reporting") this.#report(event, "MOTION");
		else if (this.#mode === "selecting") this.#drag(event.clientX, event.clientY);
		else if (this.#reports(event) && this.#host.terminal.mode(MODES.anyMouse)) this.#report(event, "MOTION");
		this.#showLink(isLinkClick(event) ? event : undefined);
	}

	#up(event: PointerEvent): void {
		if (this.#canvas.hasPointerCapture(event.pointerId)) this.#canvas.releasePointerCapture(event.pointerId);
		if (this.#mode === "reporting") this.#report(event, "RELEASE");
		if (this.#mode === "selecting") {
			this.#stopAutoscroll();
			this.#host.terminal.selectRelease(this.#host.at(event.clientX, event.clientY));
			this.#host.render();
		}
		this.#mode = "idle";
	}

	#drag(clientX: number, clientY: number): void {
		const bounds = this.#canvas.getBoundingClientRect();
		const outside = clientY < bounds.top ? clientY - bounds.top : clientY > bounds.bottom ? clientY - bounds.bottom : 0;
		if (outside === 0) this.#stopAutoscroll();
		else this.#startAutoscroll(clientX, clientY);
		this.#host.terminal.selectDrag(this.#host.at(clientX, clientY), this.#host.geometry());
		this.#host.render();
	}

	#startAutoscroll(clientX: number, clientY: number): void {
		if (this.#autoscroll !== undefined) {
			this.#autoscroll.clientX = clientX;
			this.#autoscroll.clientY = clientY;
			return;
		}
		const timer = setInterval(() => {
			const pointer = this.#autoscroll;
			if (pointer === undefined) return;
			const bounds = this.#canvas.getBoundingClientRect();
			const past = pointer.clientY < bounds.top ? pointer.clientY - bounds.top : pointer.clientY - bounds.bottom;
			const ramp = Math.max(-1, Math.min(1, past / AUTOSCROLL_RAMP_PX));
			this.#host.scroll(Math.sign(ramp) * Math.max(1, Math.round(Math.abs(ramp) * AUTOSCROLL_MAX_ROWS)));
			this.#host.terminal.selectDrag(this.#host.at(pointer.clientX, pointer.clientY), this.#host.geometry());
			this.#host.render();
		}, AUTOSCROLL_MS);
		this.#autoscroll = { timer, clientX, clientY };
	}

	#stopAutoscroll(): void {
		if (this.#autoscroll === undefined) return;
		clearInterval(this.#autoscroll.timer);
		this.#autoscroll = undefined;
	}

	/** Whether the program hears this event: it asked for the mouse, and Shift, the way to select anyway, is up. */
	#reports(event: MouseEvent): boolean {
		return !event.shiftKey && this.#host.terminal.isMouseTracking();
	}

	#report(event: PointerEvent, action: MouseInput["action"]): void {
		const at = this.#host.at(event.clientX, event.clientY);
		const button = action === "MOTION" ? buttonOfButtons(event.buttons) : buttonOf(event.button);
		const data = this.#host.terminal.encodeMouse({ action, button, mods: modsOf(event), x: at.x, y: at.y, anyButtonPressed: event.buttons !== 0 });
		if (data !== "") this.#host.send(data);
	}

	#wheel(event: WheelEvent): void {
		event.preventDefault();
		const { terminal } = this.#host;
		const { cellHeight } = this.#host.geometry();
		const pixels =
			event.deltaMode === WheelEvent.DOM_DELTA_LINE
				? event.deltaY * cellHeight
				: event.deltaMode === WheelEvent.DOM_DELTA_PAGE
					? event.deltaY * cellHeight * 20
					: event.deltaY;
		this.#wheelRows += pixels / cellHeight;
		const rows = Math.trunc(this.#wheelRows);
		if (rows === 0) return;
		this.#wheelRows -= rows;
		if (this.#reports(event)) {
			const at = this.#host.at(event.clientX, event.clientY);
			const input = { action: "PRESS", button: rows < 0 ? "FOUR" : "FIVE", mods: modsOf(event), x: at.x, y: at.y, anyButtonPressed: false } as const;
			this.#host.send(terminal.encodeMouse(input).repeat(Math.abs(rows)));
		} else if (terminal.isAlternateScreen() && terminal.mode(MODES.altScroll)) {
			// A full-screen program without the mouse scrolls by the arrow keys, which it reads in its own way.
			const code = rows < 0 ? "ArrowUp" : "ArrowDown";
			const arrow = keyInput(
				{ code, key: code, shiftKey: false, ctrlKey: false, altKey: false, metaKey: false, repeat: false, isComposing: false, getModifierState: () => false },
				"press",
			);
			this.#host.send(terminal.encodeKey(arrow).repeat(Math.abs(rows)));
		} else this.#host.scroll(rows);
	}

	#showLink(event: PointerEvent | undefined): void {
		const link = event === undefined ? undefined : this.#linkAt(this.#host.at(event.clientX, event.clientY));
		if (link?.url === this.#link?.url && link?.range.start.row === this.#link?.range.start.row) return;
		this.#link = link;
		this.#canvas.style.cursor = link === undefined ? "" : "pointer";
		this.#host.setLink(link?.range);
	}

	#linkAt(at: PointerAt): { range: CellRange; url: string } | undefined {
		const hyperlink = this.#host.terminal.hyperlinkAt(at.col, at.row);
		if (hyperlink !== undefined) return { url: hyperlink, range: { start: { col: at.col, row: at.row }, end: { col: at.col, row: at.row } } };
		const row = this.#host.frame()?.rowData[at.row];
		return row === undefined ? undefined : urlAt(row, at.col, at.row);
	}
}

/** The web address under a column of a row, and the cells it spans. */
export function urlAt(row: Row, col: number, y: number): { range: CellRange; url: string } | undefined {
	const offset = offsetOf(row, col);
	for (const match of row.text.matchAll(URL_PATTERN)) {
		const start = match.index;
		const end = start + match[0].length;
		if (offset < start || offset >= end) continue;
		return { url: match[0], range: { start: { col: colOf(row, start), row: y }, end: { col: colOf(row, end - 1), row: y } } };
	}
	return undefined;
}

/** Where a column's text begins in its row's text: a wide glyph's spacer adds nothing, an empty cell a space. */
function offsetOf(row: Row, col: number): number {
	let offset = 0;
	for (let x = 0; x < col && x < row.cells.length; x += 1) {
		const cell = row.cells[x];
		if (cell !== undefined && !cell.spacer) offset += cell.text === "" ? 1 : cell.text.length;
	}
	return offset;
}

function colOf(row: Row, offset: number): number {
	let reached = 0;
	for (let x = 0; x < row.cells.length; x += 1) {
		const cell = row.cells[x];
		if (cell === undefined || cell.spacer) continue;
		reached += cell.text === "" ? 1 : cell.text.length;
		if (reached > offset) return x;
	}
	return row.cells.length - 1;
}

/** A link opens on a click with Command, or Control off Apple's systems, as a terminal's links do. */
function isLinkClick(event: MouseEvent): boolean {
	return IS_APPLE ? event.metaKey : event.ctrlKey;
}

function buttonOf(button: number): MouseInput["button"] {
	return button === 0 ? "LEFT" : button === 1 ? "MIDDLE" : button === 2 ? "RIGHT" : undefined;
}

function buttonOfButtons(buttons: number): MouseInput["button"] {
	return (buttons & 1) !== 0 ? "LEFT" : (buttons & 4) !== 0 ? "MIDDLE" : (buttons & 2) !== 0 ? "RIGHT" : undefined;
}
