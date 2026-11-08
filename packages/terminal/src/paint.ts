/*
 * Adapted from MIT-licensed code, MIT License, Copyright (c) 2026 T3 Tools Inc.; see THIRD_PARTY_NOTICES.
 * Our changes: a painter that remembers the cursor's last row and caches colours; a row's selection drawn as one
 * range; the cursor's shapes from the render state's own style names.
 */
import { CELL_STYLE, type Cell, type Frame, type Rgb, type Row } from "./frame.ts";

/** A cell's size in CSS pixels, and where text sits on its baseline. */
export interface CellMetrics {
	readonly width: number;
	readonly height: number;
	readonly baseline: number;
}

/** The terminal's font. */
export interface TerminalFont {
	readonly family: string;
	readonly size: number;
}

/** A range of cells, inclusive, from a start cell to an end cell in reading order. */
export interface CellRange {
	readonly start: { readonly col: number; readonly row: number };
	readonly end: { readonly col: number; readonly row: number };
}

/** How the next paint looks beyond the frame: all of it or only what changed, the cursor's blink, focus, a link under the pointer. */
export interface PaintState {
	readonly full: boolean;
	readonly cursorOn: boolean;
	readonly focused: boolean;
	readonly link: CellRange | undefined;
}

/** The space between lines, as a share of the font's size. */
const LINE_HEIGHT = 1.3;

/** Powerline's solid separators, drawn as triangles from the cell's edges: a font's glyph leaves a seam. */
const POWERLINE_RIGHT = "";
const POWERLINE_LEFT = "";

/** Measures a cell of a monospace font. */
export function measureCell(context: CanvasRenderingContext2D, font: TerminalFont): CellMetrics {
	context.font = fontOf(font, 0);
	const wide = context.measureText("M");
	const tall = context.measureText("Mg");
	const ascent = tall.actualBoundingBoxAscent || font.size;
	const glyph = ascent + tall.actualBoundingBoxDescent;
	const height = Math.max(1, Math.round(font.size * LINE_HEIGHT), Math.ceil(glyph));
	return { width: Math.max(1, wide.width), height, baseline: Math.round((height - glyph) / 2 + ascent) };
}

/** How many columns and rows fit in a size, inside its padding. */
export function gridOf(width: number, height: number, metrics: CellMetrics, padding: number): { cols: number; rows: number } {
	return {
		cols: Math.max(2, Math.floor((width - padding * 2) / metrics.width)),
		rows: Math.max(1, Math.floor((height - padding * 2) / metrics.height)),
	};
}

/** Paints frames on a canvas's 2D context, redrawing only the rows that changed. */
export class Painter {
	readonly #context: CanvasRenderingContext2D;
	readonly #colors = new Map<Rgb, string>();
	#metrics: CellMetrics;
	#font: TerminalFont;
	#padding: number;
	#selection: string;
	#cursorRow: number | undefined;
	#linkRows: readonly number[] = [];

	constructor(context: CanvasRenderingContext2D, font: TerminalFont, padding: number, selection: string) {
		this.#context = context;
		this.#font = font;
		this.#padding = padding;
		this.#selection = selection;
		this.#metrics = measureCell(context, font);
	}

	/** The cell's size in the current font. */
	get metrics(): CellMetrics {
		return this.#metrics;
	}

	/** Changes the font, which the next full paint uses. */
	setFont(font: TerminalFont): CellMetrics {
		this.#font = font;
		this.#metrics = measureCell(this.#context, font);
		return this.#metrics;
	}

	/** Changes the selection's colour, a CSS colour drawn over the cells. */
	setSelection(color: string): void {
		this.#selection = color;
	}

	/** Paints a frame: every row, or the changed ones and those the cursor or a link left. */
	paint(frame: Frame, state: PaintState): void {
		const context = this.#context;
		const rows = new Set(state.full ? frame.rowData.keys() : frame.dirty);
		if (this.#cursorRow !== undefined) rows.add(this.#cursorRow);
		if (frame.cursor.visible) rows.add(frame.cursor.y);
		const linkRows = state.link === undefined ? [] : rangeRows(state.link);
		for (const row of [...this.#linkRows, ...linkRows]) rows.add(row);
		this.#linkRows = linkRows;
		if (state.full) {
			context.save();
			context.resetTransform();
			context.fillStyle = this.#css(frame.background);
			context.fillRect(0, 0, context.canvas.width, context.canvas.height);
			context.restore();
		}
		context.textBaseline = "alphabetic";
		for (const y of rows) {
			const row = frame.rowData[y];
			if (row !== undefined) this.#paintRow(frame, row, y, state.link);
		}
		const showCursor = state.cursorOn && frame.cursor.visible;
		this.#cursorRow = showCursor ? frame.cursor.y : undefined;
		if (showCursor) this.#paintCursor(frame, state.focused);
	}

	#paintRow(frame: Frame, row: Row, y: number, link: CellRange | undefined): void {
		const context = this.#context;
		const { width, height } = this.#metrics;
		const top = this.#padding + y * height;
		context.fillStyle = this.#css(frame.background);
		context.fillRect(this.#padding, top, frame.cols * width, height);
		this.#paintBackgrounds(row, top);
		if (row.selection !== undefined) {
			context.fillStyle = this.#selection;
			context.fillRect(this.#left(row.selection.start), top, (row.selection.end - row.selection.start + 1) * width, height);
		}
		this.#paintText(row, top);
		this.#paintLines(row, y, top, link);
	}

	#paintBackgrounds(row: Row, top: number): void {
		const context = this.#context;
		let start = 0;
		while (start < row.cells.length) {
			const background = row.cells[start]?.background;
			let end = start + 1;
			while (end < row.cells.length && row.cells[end]?.background === background) end += 1;
			if (background !== undefined) {
				context.fillStyle = this.#css(background);
				context.fillRect(this.#left(start), top, (end - start) * this.#metrics.width, this.#metrics.height);
			}
			start = end;
		}
	}

	#paintText(row: Row, top: number): void {
		const context = this.#context;
		const { width, height, baseline } = this.#metrics;
		let start = 0;
		while (start < row.cells.length) {
			const first = row.cells[start];
			if (first === undefined) break;
			if (first.text === "" || (first.style & CELL_STYLE.invisible) !== 0) {
				start += 1;
				continue;
			}
			if (isPowerline(first.text)) {
				context.fillStyle = this.#css(first.foreground);
				this.#paintPowerline(first.text, this.#left(start), top);
				start += 1;
				continue;
			}
			const end = runEnd(row.cells, start, first);
			const text = row.cells
				.slice(start, end)
				.map((cell) => cell.text)
				.join("");
			if (text.trim() !== "") {
				context.save();
				context.beginPath();
				context.rect(this.#left(start), top, (end - start) * width, height);
				context.clip();
				context.font = fontOf(this.#font, first.style);
				context.fillStyle = this.#css(first.foreground);
				context.fillText(text, this.#left(start), top + baseline, (end - start) * width);
				context.restore();
			}
			start = end;
		}
	}

	#paintLines(row: Row, y: number, top: number, link: CellRange | undefined): void {
		const context = this.#context;
		const { width, height } = this.#metrics;
		row.cells.forEach((cell, x) => {
			const linked = link !== undefined && inRange(link, x, y);
			if (!linked && (cell.style & (CELL_STYLE.underline | CELL_STYLE.strikethrough | CELL_STYLE.overline)) === 0) return;
			context.fillStyle = this.#css(cell.foreground);
			const left = this.#left(x);
			if (linked || (cell.style & CELL_STYLE.underline) !== 0) context.fillRect(left, top + height - 2, width, 1);
			if ((cell.style & CELL_STYLE.strikethrough) !== 0) context.fillRect(left, top + Math.floor(height * 0.55), width, 1);
			if ((cell.style & CELL_STYLE.overline) !== 0) context.fillRect(left, top + 1, width, 1);
		});
	}

	#paintCursor(frame: Frame, focused: boolean): void {
		const context = this.#context;
		const { cursor } = frame;
		const { width, height, baseline } = this.#metrics;
		const left = this.#left(cursor.x);
		const top = this.#padding + cursor.y * height;
		context.fillStyle = this.#css(cursor.color);
		context.strokeStyle = this.#css(cursor.color);
		const shape = focused ? cursor.shape : "hollow";
		if (shape === "bar") context.fillRect(left, top, 2, height);
		else if (shape === "underline") context.fillRect(left, top + height - 2, width, 2);
		else if (shape === "hollow") context.strokeRect(left + 0.5, top + 0.5, width - 1, height - 1);
		else {
			context.fillRect(left, top, width, height);
			const cell = frame.rowData[cursor.y]?.cells[cursor.x];
			if (cell === undefined || cell.text === "") return;
			context.fillStyle = this.#css(frame.background);
			if (isPowerline(cell.text)) this.#paintPowerline(cell.text, left, top);
			else {
				context.font = fontOf(this.#font, cell.style);
				context.fillText(cell.text, left, top + baseline, width);
			}
		}
	}

	#paintPowerline(text: string, left: number, top: number): void {
		const context = this.#context;
		const { width, height } = this.#metrics;
		const [base, point] = text === POWERLINE_RIGHT ? [left, left + width] : [left + width, left];
		context.beginPath();
		context.moveTo(base, top);
		context.lineTo(point, top + height / 2);
		context.lineTo(base, top + height);
		context.closePath();
		context.fill();
	}

	#left(col: number): number {
		return this.#padding + col * this.#metrics.width;
	}

	#css(color: Rgb): string {
		let css = this.#colors.get(color);
		if (css === undefined) {
			css = `#${color.toString(16).padStart(6, "0")}`;
			this.#colors.set(color, css);
		}
		return css;
	}
}

/** The end of a run of cells drawn as one text: the same colour and font, a wide glyph's spacer carried along. */
function runEnd(cells: readonly Cell[], start: number, first: Cell): number {
	let end = start + 1;
	while (end < cells.length) {
		const next = cells[end];
		if (next === undefined) break;
		if (!next.spacer && (next.text === "" || isPowerline(next.text) || !sameText(next, first))) break;
		end += 1;
	}
	return end;
}

function sameText(a: Cell, b: Cell): boolean {
	const font = CELL_STYLE.bold | CELL_STYLE.italic | CELL_STYLE.invisible;
	return a.foreground === b.foreground && (a.style & font) === (b.style & font);
}

function isPowerline(text: string): boolean {
	return text === POWERLINE_RIGHT || text === POWERLINE_LEFT;
}

function fontOf(font: TerminalFont, style: number): string {
	const slant = (style & CELL_STYLE.italic) !== 0 ? "italic" : "normal";
	const weight = (style & CELL_STYLE.bold) !== 0 ? "700" : "400";
	return `${slant} ${weight} ${font.size}px ${font.family}`;
}

function inRange(range: CellRange, col: number, row: number): boolean {
	if (row < range.start.row || row > range.end.row) return false;
	return (row > range.start.row || col >= range.start.col) && (row < range.end.row || col <= range.end.col);
}

function rangeRows(range: CellRange): number[] {
	return Array.from({ length: range.end.row - range.start.row + 1 }, (_, index) => range.start.row + index);
}
