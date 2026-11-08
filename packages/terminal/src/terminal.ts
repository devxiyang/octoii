/*
 * Adapted from MIT-licensed code, MIT License, Copyright (c) 2026 T3 Tools Inc.; see THIRD_PARTY_NOTICES.
 * Our changes: written for the newest libghostty-vt ABI; synchronized output through the render hold; a view of a
 * terminal the node keeps, which answers its program's queries and keeps its title, so this one does neither; selection
 * by the module's own gesture, which counts clicks and picks words and lines.
 */
import { FrameReader, type Frame, type Rgb } from "./frame.ts";
import { GhosttyCallFailed, type Ghostty, type Struct } from "./ghostty.ts";
import type { KeyInput } from "./keys.ts";

/** A terminal's grid, and its cell's size in pixels for the programs that ask. */
export interface GridSize {
	readonly cols: number;
	readonly rows: number;
	readonly cellWidth: number;
	readonly cellHeight: number;
}

/** The colours a terminal shows by default: text, background, cursor, and the first sixteen of its palette. */
export interface TerminalColors {
	readonly foreground: Rgb;
	readonly background: Rgb;
	readonly cursor: Rgb;
	readonly palette: readonly Rgb[];
}

/** What a terminal tells its surface: a hold of the screen. */
export interface TerminalEvents {
	readonly holdChanged: (held: boolean) => void;
}

/** The scrollback's extent: rows in all, the viewport's first row among them, and its height. */
export interface Scrollbar {
	readonly total: number;
	readonly offset: number;
	readonly length: number;
}

/** A mouse event for the program, in the surface's pixels. */
export interface MouseInput {
	readonly action: "PRESS" | "RELEASE" | "MOTION";
	/** GhosttyMouseButton's name; undefined for motion with no button down. */
	readonly button: "LEFT" | "MIDDLE" | "RIGHT" | "FOUR" | "FIVE" | undefined;
	readonly mods: number;
	readonly x: number;
	readonly y: number;
	readonly anyButtonPressed: boolean;
}

/** Where the surface draws the grid, for mouse reports and selection drags. */
export interface SurfaceGeometry {
	readonly width: number;
	readonly height: number;
	readonly cellWidth: number;
	readonly cellHeight: number;
	readonly padding: number;
}

/** A point under the pointer: its cell in the viewport and its position in the surface's pixels. */
export interface PointerAt {
	readonly col: number;
	readonly row: number;
	readonly x: number;
	readonly y: number;
}

/** DEC private modes the surface reads (modes.h). */
export const MODES = { cursorKeys: 1, anyMouse: 1003, focusEvents: 1004, altScroll: 1007, bracketedPaste: 2004, syncOutput: 2026 } as const;

/** How many rows of history a terminal keeps. */
const SCROLLBACK_LINES = 10_000;

/** Clicks within this many pixels and nanoseconds of the last count as one more: a double click picks a word. */
const REPEAT_DISTANCE_PX = 6;
const REPEAT_INTERVAL_NS = 500_000_000n;

/** A terminal of libghostty-vt: what the program writes goes in, frames and encoded input come out. */
export class VtTerminal {
	readonly #ghostty: Ghostty;
	readonly #handle: number;
	readonly #route: number;
	readonly #frames: FrameReader;
	readonly #keys: { encoder: number; event: number };
	readonly #mouse: { encoder: number; event: number };
	readonly #gesture: Gesture;
	readonly #scratch: number;
	readonly #point: Struct;
	readonly #ref: Struct;
	readonly #selection: Struct;
	/** What writes the selection's text: plain, its soft-wrapped lines joined, its trailing spaces trimmed. */
	readonly #formatter: number;
	readonly #option;
	readonly #data;
	readonly #enums;
	#held = false;
	#disposed = false;

	constructor(ghostty: Ghostty, size: GridSize, events: TerminalEvents) {
		this.#ghostty = ghostty;
		this.#option = ghostty.values("GhosttyTerminalOption", [
			"USERDATA",
			"RENDER_HOLD",
			"COLOR_FOREGROUND",
			"COLOR_BACKGROUND",
			"COLOR_CURSOR",
			"COLOR_PALETTE",
			"SELECTION",
			"DEFAULT_CURSOR_BLINK",
			"SCROLLBACK_MAX_LINES",
			"MODE",
		]);
		this.#data = ghostty.values("GhosttyTerminalData", [
			"ACTIVE_SCREEN",
			"SCROLLBAR",
			"MOUSE_TRACKING",
			"VIEWPORT_ACTIVE",
			"MODE",
			"SELECTION",
			"COLOR_PALETTE_DEFAULT",
		]);
		this.#enums = enumsOf(ghostty);
		this.#handle = ghostty.handle("ghostty_terminal_new", clampCols(size.cols), clampRows(size.rows));
		this.#scratch = ghostty.alloc(16);
		this.#point = ghostty.struct("GhosttyPoint");
		this.#ref = ghostty.struct("GhosttyGridRef");
		this.#selection = ghostty.struct("GhosttySelection");
		this.#frames = new FrameReader(ghostty);
		this.#keys = { encoder: ghostty.handle("ghostty_key_encoder_new"), event: ghostty.handle("ghostty_key_event_new") };
		this.#mouse = { encoder: ghostty.handle("ghostty_mouse_encoder_new"), event: ghostty.handle("ghostty_mouse_event_new") };
		this.#gesture = this.#newGesture();
		this.#formatter = ghostty.handle("ghostty_formatter_terminal_new", this.#handle);
		ghostty.bytes()[this.#scratch] = 1;
		ghostty.check("ghostty_formatter_set", this.#formatter, this.#enums.formatterOption.UNWRAP, this.#scratch);
		this.#route = ghostty.route({ renderHold: (held) => this.#hold(held, events) });
		this.#configure(size);
	}

	/** Takes what the program wrote. */
	write(data: Uint8Array): void {
		if (data.length === 0) return;
		const ghostty = this.#ghostty;
		const pointer = ghostty.copyIn(data);
		try {
			ghostty.call("ghostty_terminal_vt_write", this.#handle, pointer, data.length);
		} finally {
			ghostty.free(pointer, data.length);
		}
	}

	/** Starts over with what draws the terminal again, keeping the size and colours. */
	replay(data: Uint8Array): void {
		this.#ghostty.call("ghostty_terminal_reset", this.#handle);
		this.#setBool(this.#option.DEFAULT_CURSOR_BLINK, true);
		this.write(data);
	}

	/** Lays the terminal out at a new size. */
	resize(size: GridSize): void {
		const cellWidth = Math.max(1, Math.round(size.cellWidth));
		const cellHeight = Math.max(1, Math.round(size.cellHeight));
		this.#ghostty.check("ghostty_terminal_resize", this.#handle, clampCols(size.cols), clampRows(size.rows), cellWidth, cellHeight);
	}

	/** Sets the default colours; colours a program set itself stay. */
	setColors(colors: TerminalColors): void {
		const ghostty = this.#ghostty;
		const rgb = ghostty.alloc(3);
		for (const [option, color] of [
			[this.#option.COLOR_FOREGROUND, colors.foreground],
			[this.#option.COLOR_BACKGROUND, colors.background],
			[this.#option.COLOR_CURSOR, colors.cursor],
		] as const) {
			writeRgb(ghostty.view(), rgb, color);
			ghostty.check("ghostty_terminal_set", this.#handle, option, rgb);
		}
		ghostty.free(rgb, 3);
		const palette = ghostty.alloc(PALETTE_BYTES);
		ghostty.check("ghostty_terminal_get", this.#handle, this.#data.COLOR_PALETTE_DEFAULT, palette);
		colors.palette.slice(0, 16).forEach((color, index) => writeRgb(ghostty.view(), palette + index * 3, color));
		ghostty.check("ghostty_terminal_set", this.#handle, this.#option.COLOR_PALETTE, palette);
		ghostty.free(palette, PALETTE_BYTES);
	}

	/** The screen as a frame; the frame captured when a hold began, while the program holds the screen. */
	frame(): Frame {
		if (!this.#held) this.#frames.update(this.#handle);
		return this.#frames.read();
	}

	/** Lets the screen update again when a program held it too long. */
	releaseHold(): void {
		this.#setMode(MODES.syncOutput, false);
		this.#held = false;
	}

	/** Whether a DEC private mode is set. */
	mode(mode: number): boolean {
		const config = this.#scratch;
		this.#ghostty.view().setUint16(config, mode, true);
		this.#ghostty.bytes()[config + 2] = 0;
		this.#ghostty.check("ghostty_terminal_get", this.#handle, this.#data.MODE, config);
		return this.#ghostty.bytes()[config + 2] !== 0;
	}

	/** Whether the program shows the alternate screen, as a full-screen program does. */
	isAlternateScreen(): boolean {
		return this.#u32(this.#data.ACTIVE_SCREEN) !== 0;
	}

	/** Whether the program asks for mouse events. */
	isMouseTracking(): boolean {
		return this.#bool(this.#data.MOUSE_TRACKING);
	}

	/** Whether the viewport shows the bottom, where new output appears. */
	isAtBottom(): boolean {
		return this.#bool(this.#data.VIEWPORT_ACTIVE);
	}

	/** Moves the viewport by rows, up when negative. */
	scroll(rows: number): void {
		this.#scrollViewport("DELTA", rows);
	}

	/** Moves the viewport to the bottom. */
	scrollToBottom(): void {
		this.#scrollViewport("BOTTOM", 0);
	}

	/** The scrollback's extent. */
	scrollbar(): Scrollbar {
		const bar = this.#ghostty.struct("GhosttyTerminalScrollbar");
		try {
			this.#ghostty.check("ghostty_terminal_get", this.#handle, this.#data.SCROLLBAR, bar.pointer);
			return { total: bar.get("total"), offset: bar.get("offset"), length: bar.get("len") };
		} finally {
			bar.free();
		}
	}

	/** A key as the program expects it, by the modes it set; "" when the key sends nothing. */
	encodeKey(input: KeyInput): string {
		const ghostty = this.#ghostty;
		const { encoder, event } = this.#keys;
		ghostty.check("ghostty_key_encoder_set_from_terminal", encoder, this.#handle);
		ghostty.call("ghostty_key_event_set_action", event, this.#enums.keyAction[input.action]);
		// A key the module does not name is UNIDENTIFIED, which still sends the text it typed.
		ghostty.call("ghostty_key_event_set_key", event, ghostty.enumValues("GhosttyKey")[input.key] ?? this.#enums.key.UNIDENTIFIED);
		ghostty.call("ghostty_key_event_set_mods", event, input.mods);
		ghostty.call("ghostty_key_event_set_consumed_mods", event, input.consumedMods);
		ghostty.call("ghostty_key_event_set_composing", event, input.composing ? 1 : 0);
		ghostty.call("ghostty_key_event_set_unshifted_codepoint", event, input.unshiftedCodepoint);
		const text = new TextEncoder().encode(input.text);
		const pointer = ghostty.copyIn(text);
		// The event's text is a GhosttyString, passed by its address in WebAssembly; the event keeps no copy, so the
		// bytes stay till its text is cleared.
		const utf8 = ghostty
			.struct("GhosttyString")
			.set("ptr", text.length === 0 ? 0 : pointer)
			.set("len", text.length);
		try {
			ghostty.check("ghostty_key_event_set_utf8", event, utf8.pointer);
			return (
				ghostty.output("ghostty_key_encoder_encode", (buffer, capacity, written) =>
					ghostty.call("ghostty_key_encoder_encode", encoder, event, buffer, capacity, written),
				) ?? ""
			);
		} finally {
			utf8.set("ptr", 0).set("len", 0);
			ghostty.call("ghostty_key_event_set_utf8", event, utf8.pointer);
			utf8.free();
			ghostty.free(pointer, Math.max(1, text.length));
		}
	}

	/** Pasted text as the program expects it: bracketed when it asks, unsafe control characters taken out. */
	encodePaste(text: string): string {
		const ghostty = this.#ghostty;
		const bytes = new TextEncoder().encode(text);
		if (bytes.length === 0) return "";
		const pointer = ghostty.copyIn(bytes);
		const bracketed = this.mode(MODES.bracketedPaste) ? 1 : 0;
		try {
			return (
				ghostty.output("ghostty_paste_encode", (buffer, capacity, written) =>
					ghostty.call("ghostty_paste_encode", pointer, bytes.length, bracketed, buffer, capacity, written),
				) ?? ""
			);
		} finally {
			ghostty.free(pointer, bytes.length);
		}
	}

	/** A focus change as the program asked to hear it, or "" when it did not ask. */
	encodeFocus(focused: "GAINED" | "LOST"): string {
		if (!this.mode(MODES.focusEvents)) return "";
		const ghostty = this.#ghostty;
		const event = this.#enums.focus[focused];
		return ghostty.output("ghostty_focus_encode", (buffer, capacity, written) => ghostty.call("ghostty_focus_encode", event, buffer, capacity, written)) ?? "";
	}

	/** Tells the mouse encoder where the grid is drawn. */
	setGeometry(geometry: SurfaceGeometry): void {
		const ghostty = this.#ghostty;
		const size = ghostty.struct("GhosttyMouseEncoderSize");
		size
			.set("screen_width", Math.round(geometry.width))
			.set("screen_height", Math.round(geometry.height))
			.set("cell_width", Math.max(1, Math.round(geometry.cellWidth)))
			.set("cell_height", Math.max(1, Math.round(geometry.cellHeight)))
			.set("padding_top", geometry.padding)
			.set("padding_bottom", geometry.padding)
			.set("padding_left", geometry.padding)
			.set("padding_right", geometry.padding);
		ghostty.check("ghostty_mouse_encoder_set", this.#mouse.encoder, this.#enums.mouseOption.SIZE, size.pointer);
		size.free();
	}

	/** A mouse event as the program asked to hear it, or "". */
	encodeMouse(input: MouseInput): string {
		const ghostty = this.#ghostty;
		const { encoder, event } = this.#mouse;
		ghostty.check("ghostty_mouse_encoder_set_from_terminal", encoder, this.#handle);
		ghostty.bytes()[this.#scratch] = input.anyButtonPressed ? 1 : 0;
		ghostty.check("ghostty_mouse_encoder_set", encoder, this.#enums.mouseOption.ANY_BUTTON_PRESSED, this.#scratch);
		// Motion within one cell sends nothing.
		ghostty.bytes()[this.#scratch] = 1;
		ghostty.check("ghostty_mouse_encoder_set", encoder, this.#enums.mouseOption.TRACK_LAST_CELL, this.#scratch);
		ghostty.call("ghostty_mouse_event_set_action", event, this.#enums.mouseAction[input.action]);
		if (input.button === undefined) ghostty.call("ghostty_mouse_event_clear_button", event);
		else ghostty.call("ghostty_mouse_event_set_button", event, this.#enums.mouseButton[input.button]);
		ghostty.call("ghostty_mouse_event_set_mods", event, input.mods);
		const position = ghostty.struct("GhosttyMousePosition").set("x", input.x).set("y", input.y);
		ghostty.call("ghostty_mouse_event_set_position", event, position.pointer);
		position.free();
		return (
			ghostty.output("ghostty_mouse_encoder_encode", (buffer, capacity, written) =>
				ghostty.call("ghostty_mouse_encoder_encode", encoder, event, buffer, capacity, written),
			) ?? ""
		);
	}

	/** A press of the selecting button: a single press anchors, a double picks a word, a triple a line. */
	selectPress(at: PointerAt, timeNs: bigint): void {
		const { gesture, press } = this.#gesture;
		this.#setGestureRef(press, at);
		this.#setGesturePosition(press, at);
		const time = this.#ghostty.alloc(8);
		this.#ghostty.view().setBigUint64(time, timeNs, true);
		this.#ghostty.check("ghostty_selection_gesture_event_set", press, this.#enums.gestureOption.TIME_NS, time);
		this.#ghostty.free(time, 8);
		this.#applyGesture(gesture, press);
	}

	/** A drag of the selecting button, which extends the selection to the pointer. */
	selectDrag(at: PointerAt, geometry: SurfaceGeometry): void {
		const ghostty = this.#ghostty;
		const { gesture, drag } = this.#gesture;
		this.#setGestureRef(drag, at);
		this.#setGesturePosition(drag, at);
		const frame = ghostty.struct("GhosttySelectionGestureGeometry");
		frame
			.set("columns", Math.max(1, Math.floor((geometry.width - geometry.padding * 2) / geometry.cellWidth)))
			.set("cell_width", Math.max(1, Math.round(geometry.cellWidth)))
			.set("padding_left", geometry.padding)
			.set("screen_height", Math.round(geometry.height));
		ghostty.check("ghostty_selection_gesture_event_set", drag, this.#enums.gestureOption.GEOMETRY, frame.pointer);
		frame.free();
		this.#applyGesture(gesture, drag);
	}

	/** The selecting button's release; whether the press became a selection. */
	selectRelease(at: PointerAt): boolean {
		const { gesture, release } = this.#gesture;
		this.#setGestureRef(release, at);
		this.#applyGesture(gesture, release);
		return this.hasSelection();
	}

	/** Selects everything, history too. */
	selectAll(): void {
		this.#selection.clear();
		if (this.#ghostty.call("ghostty_terminal_select_all", this.#handle, this.#selection.pointer) === 0) {
			this.#ghostty.check("ghostty_terminal_set", this.#handle, this.#option.SELECTION, this.#selection.pointer);
		}
	}

	/** Clears the selection. */
	clearSelection(): void {
		this.#ghostty.check("ghostty_terminal_set", this.#handle, this.#option.SELECTION, 0);
		this.#ghostty.call("ghostty_selection_gesture_reset", this.#gesture.gesture, this.#handle);
	}

	/** Whether there is a selection. */
	hasSelection(): boolean {
		this.#selection.clear();
		return this.#ghostty.call("ghostty_terminal_get", this.#handle, this.#data.SELECTION, this.#selection.pointer) === 0;
	}

	/** The selection's text, soft-wrapped lines joined and trailing spaces trimmed, as the formatter writes it; "" without a selection. */
	selectedText(): string {
		if (!this.hasSelection()) return "";
		const ghostty = this.#ghostty;
		ghostty.check("ghostty_formatter_set", this.#formatter, this.#enums.formatterOption.SELECTION, this.#selection.pointer);
		return (
			ghostty.output("ghostty_formatter_format_buf", (buffer, capacity, written) =>
				ghostty.call("ghostty_formatter_format_buf", this.#formatter, buffer, capacity, written),
			) ?? ""
		);
	}

	/** The link a program set on a cell (OSC 8), if any. */
	hyperlinkAt(col: number, row: number): string | undefined {
		if (!this.#refAt(col, row)) return undefined;
		const ghostty = this.#ghostty;
		return (
			ghostty.output("ghostty_grid_ref_hyperlink_uri", (buffer, capacity, written) =>
				ghostty.call("ghostty_grid_ref_hyperlink_uri", this.#ref.pointer, buffer, capacity, written),
			) || undefined
		);
	}

	/** Frees the terminal and all it holds. */
	dispose(): void {
		if (this.#disposed) return;
		this.#disposed = true;
		const ghostty = this.#ghostty;
		ghostty.unroute(this.#route);
		this.#frames.dispose();
		ghostty.call("ghostty_selection_gesture_event_free", this.#gesture.press);
		ghostty.call("ghostty_selection_gesture_event_free", this.#gesture.drag);
		ghostty.call("ghostty_selection_gesture_event_free", this.#gesture.release);
		ghostty.call("ghostty_selection_gesture_free", this.#gesture.gesture, this.#handle);
		ghostty.call("ghostty_mouse_event_free", this.#mouse.event);
		ghostty.call("ghostty_mouse_encoder_free", this.#mouse.encoder);
		ghostty.call("ghostty_key_event_free", this.#keys.event);
		ghostty.call("ghostty_key_encoder_free", this.#keys.encoder);
		ghostty.call("ghostty_formatter_free", this.#formatter);
		ghostty.call("ghostty_terminal_free", this.#handle);
		for (const struct of [this.#point, this.#ref, this.#selection]) struct.free();
		ghostty.free(this.#scratch, 16);
	}

	#configure(size: GridSize): void {
		const ghostty = this.#ghostty;
		const option = this.#option;
		ghostty.check("ghostty_terminal_set", this.#handle, option.USERDATA, this.#route);
		ghostty.check("ghostty_terminal_set", this.#handle, option.RENDER_HOLD, ghostty.callbacks.renderHold);
		ghostty.view().setUint32(this.#scratch, SCROLLBACK_LINES, true);
		ghostty.check("ghostty_terminal_set", this.#handle, option.SCROLLBACK_MAX_LINES, this.#scratch);
		this.#setBool(option.DEFAULT_CURSOR_BLINK, true);
		this.resize(size);
	}

	#hold(held: boolean, events: TerminalEvents): void {
		// A hold begins with exactly the frame the program wants left on screen: capture it before what follows.
		if (held) this.#frames.update(this.#handle);
		this.#held = held;
		events.holdChanged(held);
	}

	#newGesture(): Gesture {
		const ghostty = this.#ghostty;
		const type = ghostty.values("GhosttySelectionGestureEventType", ["PRESS", "DRAG", "RELEASE"]);
		const press = ghostty.handle("ghostty_selection_gesture_event_new", type.PRESS);
		const distance = ghostty.alloc(8);
		ghostty.view().setFloat64(distance, REPEAT_DISTANCE_PX, true);
		ghostty.check("ghostty_selection_gesture_event_set", press, this.#enums.gestureOption.REPEAT_DISTANCE, distance);
		ghostty.view().setBigUint64(distance, REPEAT_INTERVAL_NS, true);
		ghostty.check("ghostty_selection_gesture_event_set", press, this.#enums.gestureOption.REPEAT_INTERVAL_NS, distance);
		ghostty.free(distance, 8);
		return {
			gesture: ghostty.handle("ghostty_selection_gesture_new"),
			press,
			drag: ghostty.handle("ghostty_selection_gesture_event_new", type.DRAG),
			release: ghostty.handle("ghostty_selection_gesture_event_new", type.RELEASE),
		};
	}

	#applyGesture(gesture: number, event: number): void {
		const ghostty = this.#ghostty;
		this.#selection.clear();
		const result = ghostty.call("ghostty_selection_gesture_event", gesture, this.#handle, event, this.#selection.pointer);
		if (result === 0) ghostty.check("ghostty_terminal_set", this.#handle, this.#option.SELECTION, this.#selection.pointer);
		else if (ghostty.resultName(result) !== "NO_VALUE") throw new GhosttyCallFailed("ghostty_selection_gesture_event", ghostty.resultName(result));
	}

	#setGestureRef(event: number, at: PointerAt): void {
		const found = this.#refAt(at.col, at.row);
		this.#ghostty.check("ghostty_selection_gesture_event_set", event, this.#enums.gestureOption.REF, found ? this.#ref.pointer : 0);
	}

	#setGesturePosition(event: number, at: PointerAt): void {
		const position = this.#ghostty.struct("GhosttySurfacePosition").set("x", at.x).set("y", at.y);
		this.#ghostty.check("ghostty_selection_gesture_event_set", event, this.#enums.gestureOption.POSITION, position.pointer);
		position.free();
	}

	/** Points the grid reference at a viewport cell; whether the cell exists. */
	#refAt(col: number, row: number): boolean {
		const ghostty = this.#ghostty;
		const point = this.#point.clear();
		point.set("tag", this.#enums.pointTag.VIEWPORT);
		const coordinate = point.at("value");
		const view = ghostty.view();
		view.setUint16(coordinate + ghostty.field("GhosttyPointCoordinate", "x").offset, Math.max(0, col), true);
		view.setUint32(coordinate + ghostty.field("GhosttyPointCoordinate", "y").offset, Math.max(0, row), true);
		this.#ref.clear();
		return ghostty.call("ghostty_terminal_grid_ref", this.#handle, point.pointer, this.#ref.pointer) === 0;
	}

	#scrollViewport(tag: "DELTA" | "BOTTOM", rows: number): void {
		const ghostty = this.#ghostty;
		const scroll = ghostty.struct("GhosttyTerminalScrollViewport");
		scroll.set("tag", this.#enums.scrollTag[tag]);
		ghostty.view().setInt32(scroll.at("value"), rows, true);
		ghostty.call("ghostty_terminal_scroll_viewport", this.#handle, scroll.pointer);
		scroll.free();
	}

	#setMode(mode: number, value: boolean): void {
		const config = this.#scratch;
		this.#ghostty.view().setUint16(config, mode, true);
		this.#ghostty.bytes()[config + 2] = value ? 1 : 0;
		this.#ghostty.check("ghostty_terminal_set", this.#handle, this.#option.MODE, config);
	}

	#setBool(option: number, value: boolean): void {
		this.#ghostty.bytes()[this.#scratch] = value ? 1 : 0;
		this.#ghostty.check("ghostty_terminal_set", this.#handle, option, this.#scratch);
	}

	#bool(data: number): boolean {
		this.#ghostty.bytes()[this.#scratch] = 0;
		this.#ghostty.check("ghostty_terminal_get", this.#handle, data, this.#scratch);
		return this.#ghostty.bytes()[this.#scratch] !== 0;
	}

	#u32(data: number): number {
		this.#ghostty.view().setUint32(this.#scratch, 0, true);
		this.#ghostty.check("ghostty_terminal_get", this.#handle, data, this.#scratch);
		return this.#ghostty.view().getUint32(this.#scratch, true);
	}
}

/** A selection gesture and its three reusable events. */
interface Gesture {
	readonly gesture: number;
	readonly press: number;
	readonly drag: number;
	readonly release: number;
}

/** The enum values a terminal passes, looked up once. */
function enumsOf(ghostty: Ghostty) {
	return {
		key: ghostty.values("GhosttyKey", ["UNIDENTIFIED"]),
		keyAction: ghostty.values("GhosttyKeyAction", ["PRESS", "REPEAT", "RELEASE"]),
		focus: ghostty.values("GhosttyFocusEvent", ["GAINED", "LOST"]),
		mouseOption: ghostty.values("GhosttyMouseEncoderOption", ["SIZE", "ANY_BUTTON_PRESSED", "TRACK_LAST_CELL"]),
		mouseAction: ghostty.values("GhosttyMouseAction", ["PRESS", "RELEASE", "MOTION"]),
		mouseButton: ghostty.values("GhosttyMouseButton", ["LEFT", "MIDDLE", "RIGHT", "FOUR", "FIVE"]),
		gestureOption: ghostty.values("GhosttySelectionGestureEventOption", ["REF", "POSITION", "REPEAT_DISTANCE", "TIME_NS", "REPEAT_INTERVAL_NS", "GEOMETRY"]),
		formatterOption: ghostty.values("GhosttyFormatterOption", ["UNWRAP", "SELECTION"]),
		pointTag: ghostty.values("GhosttyPointTag", ["VIEWPORT"]),
		scrollTag: ghostty.values("GhosttyTerminalScrollViewportTag", ["DELTA", "BOTTOM"]),
	};
}

/** The palette's bytes: 256 colours of three bytes. */
const PALETTE_BYTES = 256 * 3;

function writeRgb(view: DataView, pointer: number, color: Rgb): void {
	view.setUint8(pointer, (color >> 16) & 0xff);
	view.setUint8(pointer + 1, (color >> 8) & 0xff);
	view.setUint8(pointer + 2, color & 0xff);
}

function clampCols(cols: number): number {
	return Math.max(1, Math.min(1000, Math.floor(cols)));
}

function clampRows(rows: number): number {
	return Math.max(1, Math.min(500, Math.floor(rows)));
}
