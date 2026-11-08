/*
 * Adapted from MIT-licensed code, MIT License, Copyright (c) 2026 T3 Tools Inc.; see THIRD_PARTY_NOTICES.
 * Our changes: the surface split from its input and its pointer; one render loop that paints what changed; a hold of
 * the screen released after a second; the scrollbar a thumb over the canvas; the grid the node sizes the terminal to
 * drawn within the room the surface has, which it tells once it settles.
 */
import type { Frame } from "./frame.ts";
import type { Ghostty } from "./ghostty.ts";
import { TerminalInput } from "./input.ts";
import { gridOf, Painter, type CellRange, type TerminalFont } from "./paint.ts";
import { TerminalPointer } from "./pointer.ts";
import { VtTerminal, type PointerAt, type SurfaceGeometry, type TerminalColors } from "./terminal.ts";

/** A grid's size, in cells. */
export interface GridCells {
	readonly cols: number;
	readonly rows: number;
}

/** What a terminal shows and whom it tells: its font and colours, the program's input, the room it has, and its links. */
export interface TerminalOptions {
	readonly font: TerminalFont;
	readonly colors: TerminalColors;
	/** The selection's colour, a CSS colour drawn over the cells. */
	readonly selection: string;
	/** Input for the program: typed keys, pastes, mouse reports and focus. */
	readonly onInput: (data: string) => void;
	/** The grid the surface's room holds, told once it settles. */
	readonly onResize: (size: GridCells) => void;
	readonly onLink: (url: string) => void;
}

/** The space around the grid, in CSS pixels. */
const PADDING = 6;

/** How long the cursor shows, then hides, while it blinks. */
const BLINK_MS = 600;

/** How long a program may hold the screen before it updates anyway. */
const HOLD_MAX_MS = 1000;

/**
 * How long the room must keep its size before it is told: a program told of every step of a drag redraws at each,
 * which reads as jitter.
 */
const RESIZE_SETTLE_MS = 150;

/** The scrollbar's thumb: its width and its shortest length. */
const THUMB_WIDTH_PX = 6;
const THUMB_MIN_PX = 24;
const THUMB_SHOWN_MS = 1000;

/** A terminal drawn in an element: the canvas, the textarea that takes the keys, and the scrollbar's thumb. */
export class TerminalSurface {
	readonly #root: HTMLDivElement;
	readonly #canvas: HTMLCanvasElement;
	readonly #textarea: HTMLTextAreaElement;
	readonly #thumb: HTMLDivElement;
	readonly #terminal: VtTerminal;
	readonly #painter: Painter;
	readonly #input: TerminalInput;
	readonly #pointer: TerminalPointer;
	readonly #options: TerminalOptions;
	readonly #resize: ResizeObserver;
	readonly #reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
	/** The grid drawn: the node's, within the room. */
	#grid: GridCells = { cols: 0, rows: 0 };
	/** The grid the room holds. */
	#room: GridCells = { cols: 0, rows: 0 };
	/** The grid the node sizes the terminal to, once it said. */
	#shared: GridCells | undefined;
	#resized: ReturnType<typeof setTimeout> | undefined;
	#frame: Frame | undefined;
	#link: CellRange | undefined;
	#full = true;
	#focused = false;
	#cursorOn = true;
	#animation = 0;
	#blink: ReturnType<typeof setTimeout> | undefined;
	#hold: ReturnType<typeof setTimeout> | undefined;
	#thumbFade: ReturnType<typeof setTimeout> | undefined;
	#pixelRatio: MediaQueryList | undefined;
	#disposed = false;

	constructor(element: HTMLElement, ghostty: Ghostty, options: TerminalOptions) {
		this.#options = options;
		this.#root = element.ownerDocument.createElement("div");
		this.#canvas = element.ownerDocument.createElement("canvas");
		this.#textarea = element.ownerDocument.createElement("textarea");
		this.#thumb = element.ownerDocument.createElement("div");
		this.#build(element);
		const context = this.#canvas.getContext("2d", { alpha: false });
		if (context === null) throw new Error("the canvas gives no 2D context");
		this.#painter = new Painter(context, options.font, PADDING, options.selection);
		const metrics = this.#painter.metrics;
		this.#terminal = new VtTerminal(
			ghostty,
			{ cols: 80, rows: 24, cellWidth: metrics.width, cellHeight: metrics.height },
			{ holdChanged: (held) => this.#holdChanged(held) },
		);
		this.#terminal.setColors(options.colors);
		this.#input = new TerminalInput(this.#textarea, {
			terminal: this.#terminal,
			type: (data) => this.#type(data),
			scrollPages: (pages) => this.#scroll(pages * Math.max(1, this.#grid.rows - 1)),
			scrollToEdge: (edge) => this.#scrollToEdge(edge),
			render: () => this.#render(),
		});
		this.#pointer = new TerminalPointer(this.#canvas, {
			terminal: this.#terminal,
			send: (data) => options.onInput(data),
			scroll: (rows) => this.#scroll(rows),
			render: () => this.#render(),
			at: (x, y) => this.#at(x, y),
			geometry: () => this.#geometry(),
			frame: () => this.#frame,
			setLink: (link) => this.#setLink(link),
			openLink: (url) => options.onLink(url),
			focus: () => this.focus(),
		});
		this.#textarea.addEventListener("focus", () => this.#focusChanged("GAINED"));
		this.#textarea.addEventListener("blur", () => this.#focusChanged("LOST"));
		this.#resize = new ResizeObserver(() => this.#fit());
		this.#resize.observe(this.#root);
		this.#watchPixelRatio();
		// Its room known as it mounts, where its element is laid out.
		this.#fit();
	}

	/** The grid the surface's room holds. */
	get size(): GridCells {
		return this.#room;
	}

	/**
	 * Draws the grid the node sizes the terminal to — the smallest of the rooms it is shown in — within this room, each
	 * side alone: the node's lags a room that just shrank.
	 */
	setGrid(grid: GridCells): void {
		this.#shared = grid;
		this.#layOut();
	}

	/** Shows what the program wrote. */
	write(data: Uint8Array): void {
		this.#terminal.write(data);
		this.#render();
	}

	/** Starts over with what the program wrote before, as when the terminal is attached again. */
	replay(data: Uint8Array): void {
		this.#terminal.replay(data);
		this.#full = true;
		this.#render();
	}

	/** Takes the keyboard. */
	focus(): void {
		this.#textarea.focus({ preventScroll: true });
	}

	/** Changes the colours, as when the theme changes. */
	setColors(colors: TerminalColors, selection: string): void {
		this.#terminal.setColors(colors);
		this.#painter.setSelection(selection);
		this.#full = true;
		this.#render();
	}

	/** Changes the font, which can change how many cells fit. */
	setFont(font: TerminalFont): void {
		this.#painter.setFont(font);
		this.#fit();
	}

	/** Takes the terminal out of the element and frees it. */
	dispose(): void {
		if (this.#disposed) return;
		this.#disposed = true;
		cancelAnimationFrame(this.#animation);
		clearTimeout(this.#blink);
		clearTimeout(this.#hold);
		clearTimeout(this.#resized);
		clearTimeout(this.#thumbFade);
		this.#pixelRatio?.removeEventListener("change", this.#pixelRatioChanged);
		this.#resize.disconnect();
		this.#input.dispose();
		this.#pointer.dispose();
		this.#terminal.dispose();
		this.#root.remove();
	}

	#build(element: HTMLElement): void {
		Object.assign(this.#root.style, { position: "absolute", inset: "0", overflow: "hidden" });
		Object.assign(this.#canvas.style, { position: "absolute", inset: "0", width: "100%", height: "100%", cursor: "text" });
		this.#textarea.setAttribute("aria-label", "Terminal input");
		this.#textarea.autocapitalize = "off";
		this.#textarea.spellcheck = false;
		this.#textarea.setAttribute("autocorrect", "off");
		this.#textarea.setAttribute("autocomplete", "off");
		Object.assign(this.#textarea.style, {
			position: "absolute",
			width: "1em",
			opacity: "0",
			padding: "0",
			border: "0",
			outline: "none",
			resize: "none",
			overflow: "hidden",
			whiteSpace: "nowrap",
			caretColor: "transparent",
			pointerEvents: "none",
		});
		Object.assign(this.#thumb.style, {
			position: "absolute",
			right: "2px",
			width: `${THUMB_WIDTH_PX}px`,
			borderRadius: `${THUMB_WIDTH_PX / 2}px`,
			opacity: "0",
			transition: "opacity 0.3s",
			pointerEvents: "none",
		});
		this.#root.append(this.#canvas, this.#textarea, this.#thumb);
		element.append(this.#root);
	}

	#fit(): void {
		const width = this.#root.clientWidth;
		const height = this.#root.clientHeight;
		if (width === 0 || height === 0) return;
		const ratio = window.devicePixelRatio || 1;
		this.#canvas.width = Math.round(width * ratio);
		this.#canvas.height = Math.round(height * ratio);
		this.#canvas.getContext("2d")?.setTransform(ratio, 0, 0, ratio, 0, 0);
		const room = gridOf(width, height, this.#painter.metrics, PADDING);
		if (room.cols !== this.#room.cols || room.rows !== this.#room.rows) {
			this.#room = room;
			clearTimeout(this.#resized);
			this.#resized = setTimeout(() => this.#options.onResize(this.#room), RESIZE_SETTLE_MS);
		}
		this.#layOut();
	}

	/** Lays the terminal out at the grid drawn: the node's within the room, the room's until the node says. */
	#layOut(): void {
		const shared = this.#shared ?? this.#room;
		const grid = { cols: Math.min(shared.cols, this.#room.cols), rows: Math.min(shared.rows, this.#room.rows) };
		if (grid.cols === 0 || grid.rows === 0) return;
		const metrics = this.#painter.metrics;
		this.#terminal.resize({ ...grid, cellWidth: metrics.width, cellHeight: metrics.height });
		this.#terminal.setGeometry(this.#geometry());
		this.#grid = grid;
		this.#full = true;
		this.#paint();
	}

	#render(): void {
		if (this.#animation !== 0 || this.#disposed) return;
		this.#animation = requestAnimationFrame(() => {
			this.#animation = 0;
			this.#paint();
		});
	}

	#paint(): void {
		if (this.#disposed || this.#grid.cols === 0) return;
		const frame = this.#terminal.frame();
		this.#frame = frame;
		this.#painter.paint(frame, { full: this.#full, cursorOn: this.#cursorOn, focused: this.#focused, link: this.#link });
		this.#full = false;
		this.#placeTextarea(frame);
		this.#placeThumb();
		this.#scheduleBlink(frame);
	}

	#type(data: string): void {
		if (!this.#terminal.isAtBottom()) this.#terminal.scrollToBottom();
		this.#cursorOn = true;
		this.#options.onInput(data);
		this.#render();
	}

	#scroll(rows: number): void {
		this.#terminal.scroll(rows);
		this.#showThumb();
		this.#render();
	}

	#scrollToEdge(edge: "top" | "bottom"): void {
		if (edge === "bottom") this.#terminal.scrollToBottom();
		else this.#terminal.scroll(-this.#terminal.scrollbar().total);
		this.#showThumb();
		this.#render();
	}

	#focusChanged(focus: "GAINED" | "LOST"): void {
		this.#focused = focus === "GAINED";
		this.#cursorOn = true;
		const report = this.#terminal.encodeFocus(focus);
		if (report !== "") this.#options.onInput(report);
		this.#render();
	}

	#holdChanged(held: boolean): void {
		clearTimeout(this.#hold);
		this.#hold = undefined;
		if (held) {
			this.#hold = setTimeout(() => {
				this.#terminal.releaseHold();
				this.#render();
			}, HOLD_MAX_MS);
		} else this.#render();
	}

	#setLink(link: CellRange | undefined): void {
		this.#link = link;
		this.#render();
	}

	#scheduleBlink(frame: Frame): void {
		clearTimeout(this.#blink);
		this.#blink = undefined;
		if (!this.#focused || !frame.cursor.visible || !frame.cursor.blinking || this.#reducedMotion.matches) {
			this.#cursorOn = true;
			return;
		}
		this.#blink = setTimeout(() => {
			this.#cursorOn = !this.#cursorOn;
			this.#render();
		}, BLINK_MS);
	}

	/** Keeps the textarea on the cursor, where the input method shows what it composes. */
	#placeTextarea(frame: Frame): void {
		if (!frame.cursor.visible) return;
		const metrics = this.#painter.metrics;
		this.#textarea.style.left = `${PADDING + frame.cursor.x * metrics.width}px`;
		this.#textarea.style.top = `${PADDING + frame.cursor.y * metrics.height}px`;
		this.#textarea.style.height = `${metrics.height}px`;
		this.#textarea.style.font = `${this.#options.font.size}px ${this.#options.font.family}`;
	}

	#placeThumb(): void {
		const bar = this.#terminal.scrollbar();
		const height = this.#root.clientHeight;
		if (bar.total <= bar.length || height === 0) {
			this.#thumb.style.display = "none";
			return;
		}
		const length = Math.max(THUMB_MIN_PX, (bar.length / bar.total) * height);
		const top = (bar.offset / Math.max(1, bar.total - bar.length)) * (height - length);
		Object.assign(this.#thumb.style, {
			display: "block",
			height: `${length}px`,
			top: `${top}px`,
			background: translucent(this.#frame?.foreground ?? 0x808080, 0.35),
		});
	}

	/** Shows the thumb while the view scrolls, fading it a moment after. */
	#showThumb(): void {
		this.#thumb.style.opacity = "1";
		clearTimeout(this.#thumbFade);
		this.#thumbFade = setTimeout(() => (this.#thumb.style.opacity = "0"), THUMB_SHOWN_MS);
	}

	#at(clientX: number, clientY: number): PointerAt {
		const bounds = this.#canvas.getBoundingClientRect();
		const metrics = this.#painter.metrics;
		const x = clientX - bounds.left;
		const y = clientY - bounds.top;
		return {
			col: clamp(Math.floor((x - PADDING) / metrics.width), 0, this.#grid.cols - 1),
			row: clamp(Math.floor((y - PADDING) / metrics.height), 0, this.#grid.rows - 1),
			x,
			y,
		};
	}

	#geometry(): SurfaceGeometry {
		const metrics = this.#painter.metrics;
		return { width: this.#root.clientWidth, height: this.#root.clientHeight, cellWidth: metrics.width, cellHeight: metrics.height, padding: PADDING };
	}

	#watchPixelRatio(): void {
		this.#pixelRatio?.removeEventListener("change", this.#pixelRatioChanged);
		// A resolution query matches one ratio: it is set again after each change.
		this.#pixelRatio = matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`);
		this.#pixelRatio.addEventListener("change", this.#pixelRatioChanged);
	}

	readonly #pixelRatioChanged = (): void => {
		this.#watchPixelRatio();
		this.#fit();
	};
}

function clamp(value: number, low: number, high: number): number {
	return Math.max(low, Math.min(high, value));
}

function translucent(color: number, alpha: number): string {
	return `rgb(${(color >> 16) & 0xff} ${(color >> 8) & 0xff} ${color & 0xff} / ${alpha})`;
}
