/*
 * Adapted from MIT-licensed code, MIT License, Copyright (c) 2026 T3 Tools Inc.; see THIRD_PARTY_NOTICES.
 * Our changes: read through the newest render-state ABI: a row's selection as one range, colours and cursor each in
 * one call, the frame cleaned once read; colours packed as numbers.
 */
import type { Ghostty, Struct } from "./ghostty.ts";

/** A colour, packed 0xRRGGBB. */
export type Rgb = number;

/** A cell's styles, as bits. */
export const CELL_STYLE = {
	bold: 1,
	italic: 2,
	underline: 4,
	strikethrough: 8,
	overline: 16,
	invisible: 32,
} as const;

/** A cell as it is drawn: its text, its colours resolved, its styles, and whether it is the second half of a wide one. */
export interface Cell {
	readonly text: string;
	readonly foreground: Rgb;
	/** Undefined when the cell shows the terminal's background. */
	readonly background: Rgb | undefined;
	readonly style: number;
	readonly spacer: boolean;
}

/** A row of the viewport: its cells, its text for finding links, and the columns selected in it. */
export interface Row {
	readonly cells: readonly Cell[];
	readonly text: string;
	readonly selection: { readonly start: number; readonly end: number } | undefined;
}

/** How the cursor is drawn. */
export type CursorShape = "bar" | "block" | "underline" | "hollow";

/** The cursor: where it is in the viewport, when it shows, its shape and colour. */
export interface Cursor {
	readonly x: number;
	readonly y: number;
	readonly visible: boolean;
	readonly blinking: boolean;
	readonly shape: CursorShape;
	readonly color: Rgb;
}

/** What a frame draws: the grid, its default colours, the cursor, the rows, and which rows changed since the last. */
export interface Frame {
	readonly cols: number;
	readonly rows: number;
	readonly foreground: Rgb;
	readonly background: Rgb;
	readonly cursor: Cursor;
	readonly rowData: readonly Row[];
	/** The rows to draw again; every row after a full change. */
	readonly dirty: ReadonlySet<number>;
}

const SHAPES: readonly CursorShape[] = ["bar", "block", "underline", "hollow"];

/** Reads a render state into frames, keeping each row until it changes. */
export class FrameReader {
	readonly #ghostty: Ghostty;
	readonly #state: number;
	readonly #rows: number;
	readonly #cells: number;
	readonly #colors: Struct;
	readonly #cursor: Struct;
	readonly #style: Struct;
	readonly #rowSelection: Struct;
	/** Where a cell's grapheme is asked to be written: the codepoints' buffer, its room and how many there are. */
	readonly #graphemes: Struct;
	readonly #scratch: number;
	readonly #query: number;
	#codepoints = { pointer: 0, capacity: 0 };
	#rowData: Row[] = [];
	readonly #data;
	readonly #rowKeys;
	readonly #cellKeys;
	readonly #dirtyValues;
	readonly #cellData;
	readonly #cellWide;
	readonly #colorTag;

	constructor(ghostty: Ghostty) {
		this.#ghostty = ghostty;
		this.#state = ghostty.handle("ghostty_render_state_new");
		this.#rows = ghostty.handle("ghostty_render_state_row_iterator_new");
		this.#cells = ghostty.handle("ghostty_render_state_row_cells_new");
		this.#colors = ghostty.struct("GhosttyRenderStateColors");
		this.#cursor = ghostty.struct("GhosttyRenderStateCursor");
		this.#style = ghostty.struct("GhosttyStyle");
		this.#rowSelection = ghostty.struct("GhosttyRenderStateRowSelection");
		this.#graphemes = ghostty.struct("GhosttyCodepointBuffer");
		this.#scratch = ghostty.alloc(16);
		this.#query = ghostty.alloc(QUERY.bytes);
		this.#data = ghostty.values("GhosttyRenderStateData", ["COLS", "ROWS", "DIRTY", "ROW_ITERATOR", "COLORS", "CURSOR"]);
		this.#rowKeys = ghostty.values("GhosttyRenderStateRowData", ["DIRTY", "CELLS", "SELECTION"]);
		this.#cellKeys = ghostty.values("GhosttyRenderStateRowCellsData", ["RAW", "STYLE", "GRAPHEMES_LEN", "GRAPHEMES_BUF", "BG_COLOR", "FG_COLOR"]);
		this.#dirtyValues = ghostty.values("GhosttyRenderStateDirty", ["FALSE", "FULL"]);
		this.#cellData = ghostty.values("GhosttyCellData", ["WIDE"]);
		this.#cellWide = ghostty.values("GhosttyCellWide", ["SPACER_TAIL"]);
		this.#colorTag = ghostty.values("GhosttyStyleColorTag", ["NONE"]);
		this.#prepareQuery();
	}

	/** Takes the terminal's current screen into the render state. */
	update(terminal: number): void {
		this.#ghostty.check("ghostty_render_state_update", this.#state, terminal);
	}

	/** Reads the render state as a frame, then marks it clean. */
	read(): Frame {
		const cols = this.#u16(this.#data.COLS);
		const rows = this.#u16(this.#data.ROWS);
		const colors = this.#readColors();
		const resized = this.#rowData.length !== rows || this.#rowData[0]?.cells.length !== cols;
		if (resized) this.#rowData = Array.from({ length: rows }, () => blankRow(cols, colors));
		const dirtyState = this.#u32(this.#data.DIRTY);
		const dirty = new Set<number>();
		if (dirtyState !== this.#dirtyValues.FALSE || resized) {
			this.#readRows(cols, rows, colors, dirtyState === this.#dirtyValues.FULL || resized, dirty);
			this.#ghostty.check("ghostty_render_state_clean", this.#state);
		}
		return { cols, rows, ...colors, cursor: this.#readCursor(colors.cursor), rowData: this.#rowData, dirty };
	}

	/** Frees the render state and its buffers. */
	dispose(): void {
		const ghostty = this.#ghostty;
		ghostty.call("ghostty_render_state_row_cells_free", this.#cells);
		ghostty.call("ghostty_render_state_row_iterator_free", this.#rows);
		ghostty.call("ghostty_render_state_free", this.#state);
		for (const struct of [this.#colors, this.#cursor, this.#style, this.#rowSelection, this.#graphemes]) struct.free();
		ghostty.free(this.#scratch, 16);
		ghostty.free(this.#query, QUERY.bytes);
		ghostty.free(this.#codepoints.pointer, this.#codepoints.capacity);
	}

	#readRows(cols: number, rows: number, colors: Colors, full: boolean, dirty: Set<number>): void {
		const ghostty = this.#ghostty;
		const slot = this.#scratch;
		ghostty.view().setUint32(slot, this.#rows, true);
		ghostty.check("ghostty_render_state_get", this.#state, this.#data.ROW_ITERATOR, slot);
		const next = ghostty.fn("ghostty_render_state_row_iterator_next");
		for (let y = 0; y < rows && next(this.#rows) !== 0; y += 1) {
			if (!full && !this.#rowBool(this.#rowKeys.DIRTY)) continue;
			this.#rowData[y] = this.#readRow(cols, colors);
			dirty.add(y);
		}
	}

	#readRow(cols: number, colors: Colors): Row {
		const ghostty = this.#ghostty;
		ghostty.view().setUint32(this.#scratch, this.#cells, true);
		ghostty.check("ghostty_render_state_row_get", this.#rows, this.#rowKeys.CELLS, this.#scratch);
		const next = ghostty.fn("ghostty_render_state_row_cells_next");
		const cells: Cell[] = [];
		while (cells.length < cols && next(this.#cells) !== 0) cells.push(this.#readCell(colors, cells.at(-1)));
		while (cells.length < cols) cells.push(blankCell(colors));
		return { cells, text: rowText(cells), selection: this.#readRowSelection() };
	}

	#readCell(colors: Colors, previous: Cell | undefined): Cell {
		const ghostty = this.#ghostty;
		this.#style.clear();
		const result = ghostty.call(
			"ghostty_render_state_row_cells_get_multi",
			this.#cells,
			QUERY.count,
			this.#query + QUERY.keys,
			this.#query + QUERY.values,
			this.#query + QUERY.written,
		);
		const view = ghostty.view();
		const written = view.getUint32(this.#query + QUERY.written, true);
		// The background is last: a cell without one stops the query there, which is no failure.
		if (written < QUERY.count - 1) throw new Error(`libghostty-vt read no cell: ${ghostty.resultName(result)}`);
		const length = view.getUint32(this.#query + QUERY.length, true);
		const text = length === 0 ? "" : this.#cellText(length);
		const ownForeground = this.#hasForeground() ? this.#cellColor(this.#cellKeys.FG_COLOR) : undefined;
		const ownBackground = written === QUERY.count ? readRgb(ghostty.view(), this.#query + QUERY.background) : undefined;
		// Only an empty cell after a glyph can be a wide glyph's second half: the raw cell is read for those alone.
		const spacer = text === "" && previous !== undefined && previous.text !== "" && this.#isSpacer();
		return styledCell(this.#style, { text, foreground: ownForeground, background: ownBackground, spacer }, colors);
	}

	#hasForeground(): boolean {
		const tag = this.#style.at("fg_color") + this.#ghostty.field("GhosttyStyleColor", "tag").offset;
		return this.#ghostty.view().getInt32(tag, true) !== this.#colorTag.NONE;
	}

	#isSpacer(): boolean {
		const ghostty = this.#ghostty;
		ghostty.check("ghostty_render_state_row_cells_get", this.#cells, this.#cellKeys.RAW, this.#scratch);
		const cell = ghostty.view().getBigUint64(this.#scratch, true);
		ghostty.view().setUint32(this.#scratch + 8, 0, true);
		ghostty.check("ghostty_cell_get", cell, this.#cellData.WIDE, this.#scratch + 8);
		return ghostty.view().getUint32(this.#scratch + 8, true) === this.#cellWide.SPACER_TAIL;
	}

	#cellText(length: number): string {
		const ghostty = this.#ghostty;
		const bytes = length * 4;
		if (bytes > this.#codepoints.capacity) {
			ghostty.free(this.#codepoints.pointer, this.#codepoints.capacity);
			this.#codepoints = { pointer: ghostty.alloc(bytes), capacity: bytes };
		}
		this.#graphemes.set("ptr", this.#codepoints.pointer).set("cap", length).set("len", 0);
		ghostty.check("ghostty_render_state_row_cells_get", this.#cells, this.#cellKeys.GRAPHEMES_BUF, this.#graphemes.pointer);
		const view = ghostty.view();
		const codepoints: number[] = [];
		// A cell's grapheme is a handful of codepoints; a flood of combining marks is cut to what a cell can show.
		for (let index = 0; index < Math.min(length, MAX_CELL_CODEPOINTS); index += 1) {
			codepoints.push(view.getUint32(this.#codepoints.pointer + index * 4, true));
		}
		return String.fromCodePoint(...codepoints);
	}

	#cellColor(key: number): Rgb | undefined {
		const result = this.#ghostty.call("ghostty_render_state_row_cells_get", this.#cells, key, this.#scratch);
		return result === 0 ? readRgb(this.#ghostty.view(), this.#scratch) : undefined;
	}

	#readRowSelection(): Row["selection"] {
		this.#rowSelection.clear();
		const result = this.#ghostty.call("ghostty_render_state_row_get", this.#rows, this.#rowKeys.SELECTION, this.#rowSelection.pointer);
		if (result !== 0) return undefined;
		return { start: this.#rowSelection.get("start_x"), end: this.#rowSelection.get("end_x") };
	}

	#readColors(): Colors {
		const colors = this.#colors.clear();
		this.#ghostty.check("ghostty_render_state_get", this.#state, this.#data.COLORS, colors.pointer);
		const view = this.#ghostty.view();
		const foreground = readRgb(view, colors.at("foreground"));
		return {
			foreground,
			background: readRgb(view, colors.at("background")),
			cursor: colors.get("cursor_has_value") !== 0 ? readRgb(view, colors.at("cursor")) : foreground,
		};
	}

	#readCursor(color: Rgb): Cursor {
		const cursor = this.#cursor.clear();
		this.#ghostty.check("ghostty_render_state_get", this.#state, this.#data.CURSOR, cursor.pointer);
		const inViewport = cursor.get("viewport_has_value") !== 0;
		return {
			x: inViewport ? cursor.get("viewport_x") : -1,
			y: inViewport ? cursor.get("viewport_y") : -1,
			visible: inViewport && cursor.get("visible") !== 0,
			blinking: cursor.get("blinking") !== 0,
			shape: SHAPES[cursor.get("visual_style")] ?? "block",
			color,
		};
	}

	#rowBool(key: number): boolean {
		this.#ghostty.bytes()[this.#scratch] = 0;
		const result = this.#ghostty.call("ghostty_render_state_row_get", this.#rows, key, this.#scratch);
		return result === 0 && this.#ghostty.bytes()[this.#scratch] !== 0;
	}

	#u16(key: number): number {
		this.#ghostty.view().setUint32(this.#scratch, 0, true);
		this.#ghostty.check("ghostty_render_state_get", this.#state, key, this.#scratch);
		return this.#ghostty.view().getUint16(this.#scratch, true);
	}

	#u32(key: number): number {
		this.#ghostty.view().setUint32(this.#scratch, 0, true);
		this.#ghostty.check("ghostty_render_state_get", this.#state, key, this.#scratch);
		return this.#ghostty.view().getUint32(this.#scratch, true);
	}

	/** One query reads a cell's grapheme length, style and background: keys, then where each value lands. */
	#prepareQuery(): void {
		const view = this.#ghostty.view();
		const keys = [this.#cellKeys.GRAPHEMES_LEN, this.#cellKeys.STYLE, this.#cellKeys.BG_COLOR];
		const values = [this.#query + QUERY.length, this.#style.pointer, this.#query + QUERY.background];
		keys.forEach((key, index) => {
			view.setUint32(this.#query + QUERY.keys + index * 4, key, true);
			view.setUint32(this.#query + QUERY.values + index * 4, values[index] ?? 0, true);
		});
	}
}

/** The cell query's layout in its buffer: three keys, three value pointers, the count written, and two values. */
const QUERY = { count: 3, keys: 0, values: 12, written: 24, length: 28, background: 32, bytes: 40 } as const;

/** The most codepoints a cell's text keeps. */
const MAX_CELL_CODEPOINTS = 32;

/** The terminal's default colours, which a cell without its own shows. */
interface Colors {
	readonly foreground: Rgb;
	readonly background: Rgb;
	readonly cursor: Rgb;
}

/** What a cell is read as before its style applies: its text and the colours it sets itself. */
interface RawCell {
	readonly text: string;
	readonly foreground: Rgb | undefined;
	readonly background: Rgb | undefined;
	readonly spacer: boolean;
}

/**
 * A style's flags, as libghostty-vt's `GhosttyStyleFlags` lays them out from 1.0, frozen: an attribute a bit, the
 * underline's kind in three bits above them, none of it underlined.
 */
const STYLE_FLAGS = {
	bold: 1 << 0,
	italic: 1 << 1,
	faint: 1 << 2,
	inverse: 1 << 4,
	invisible: 1 << 5,
	strikethrough: 1 << 6,
	overline: 1 << 7,
	underline: 0x7 << 8,
} as const;

/** A cell with its style applied: inverse swaps its colours, faint fades its text toward the background. */
function styledCell(style: Struct, cell: RawCell, colors: Colors): Cell {
	const flags = style.get("flags");
	const on = (name: keyof typeof STYLE_FLAGS) => (flags & STYLE_FLAGS[name]) !== 0;
	const bits =
		(on("bold") ? CELL_STYLE.bold : 0) |
		(on("italic") ? CELL_STYLE.italic : 0) |
		(on("underline") ? CELL_STYLE.underline : 0) |
		(on("strikethrough") ? CELL_STYLE.strikethrough : 0) |
		(on("overline") ? CELL_STYLE.overline : 0) |
		(on("invisible") ? CELL_STYLE.invisible : 0);
	const foreground = cell.foreground ?? colors.foreground;
	const { text, spacer } = cell;
	if (on("inverse")) return { text, foreground: cell.background ?? colors.background, background: foreground, style: bits, spacer };
	const shown = on("faint") ? mixed(foreground, cell.background ?? colors.background, FAINT_MIX) : foreground;
	return { text, foreground: shown, background: cell.background, style: bits, spacer };
}

/** How much of the text's colour faint text keeps, the rest the background's. */
const FAINT_MIX = 0.6;

/** A colour part one colour, the rest another. */
export function mixed(front: Rgb, back: Rgb, part: number): Rgb {
	const channel = (shift: number) => Math.round(((front >> shift) & 0xff) * part + ((back >> shift) & 0xff) * (1 - part));
	return (channel(16) << 16) | (channel(8) << 8) | channel(0);
}

function readRgb(view: DataView, pointer: number): Rgb {
	return (view.getUint8(pointer) << 16) | (view.getUint8(pointer + 1) << 8) | view.getUint8(pointer + 2);
}

function blankCell(colors: Colors): Cell {
	return { text: "", foreground: colors.foreground, background: undefined, style: 0, spacer: false };
}

function blankRow(cols: number, colors: Colors): Row {
	return { cells: Array.from({ length: cols }, () => blankCell(colors)), text: "", selection: undefined };
}

function rowText(cells: readonly Cell[]): string {
	let text = "";
	// A wide glyph's spacer adds nothing: the glyph stands for both its columns.
	for (const cell of cells) if (!cell.spacer) text += cell.text === "" ? " " : cell.text;
	return text.trimEnd();
}
