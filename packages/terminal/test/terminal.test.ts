import { readFile } from "node:fs/promises";
import { describe, expect, it } from "bun:test";
import { CELL_STYLE } from "../src/frame.ts";
import { Ghostty } from "../src/ghostty.ts";
import { keyInput } from "../src/keys.ts";
import { VtTerminal, type TerminalEvents } from "../src/terminal.ts";

const vendor = new URL("../vendor/", import.meta.url);
const ghostty = await Ghostty.instantiate(await readFile(new URL("ghostty-vt.wasm", vendor)), await readFile(new URL("callbacks.wasm", vendor)));

const SIZE = { cols: 20, rows: 4, cellWidth: 8, cellHeight: 16 };

function heard() {
	const events = { holds: [] as boolean[] };
	const listener: TerminalEvents = { holdChanged: (held) => events.holds.push(held) };
	return { events, listener };
}

function written(terminal: VtTerminal, text: string): void {
	terminal.write(new TextEncoder().encode(text));
}

const key = (code: string, key: string, mods: Partial<KeyboardEvent> = {}) =>
	keyInput(
		{ code, key, shiftKey: false, ctrlKey: false, altKey: false, metaKey: false, repeat: false, isComposing: false, getModifierState: () => false, ...mods },
		"press",
	);

describe("a terminal", () => {
	it("draws what the program writes, with its colours and styles", () => {
		const terminal = new VtTerminal(ghostty, SIZE, heard().listener);
		terminal.setColors({ foreground: 0xe0e0e0, background: 0x101010, cursor: 0xffffff, palette: [0x000000, 0xff0000] });
		written(terminal, "hi \x1b[1;31mred\x1b[0m\r\n\x1b[38;2;1;2;3mrgb");
		const frame = terminal.frame();
		expect(frame.cols).toBe(20);
		expect(frame.rowData[0]?.text).toBe("hi red");
		expect(frame.rowData[0]?.cells[3]).toMatchObject({ text: "r", foreground: 0xff0000, style: CELL_STYLE.bold });
		expect(frame.rowData[1]?.cells[0]?.foreground).toBe(0x010203);
		expect(frame.background).toBe(0x101010);
		expect(frame.cursor).toMatchObject({ x: 3, y: 1, visible: true });
		expect(frame.dirty.size).toBe(4);
		expect(terminal.frame().dirty.size).toBe(0);
		terminal.dispose();
	});

	it("marks a wide glyph's second cell as its spacer", () => {
		const terminal = new VtTerminal(ghostty, SIZE, heard().listener);
		written(terminal, "a中b");
		const cells = terminal.frame().rowData[0]?.cells ?? [];
		expect(cells.slice(0, 4).map((cell) => [cell.text, cell.spacer])).toEqual([
			["a", false],
			["中", false],
			["", true],
			["b", false],
		]);
		terminal.dispose();
	});

	it("starts over with what draws it again, its queries the node's to answer", () => {
		const terminal = new VtTerminal(ghostty, SIZE, heard().listener);
		written(terminal, "junk");
		terminal.replay(new TextEncoder().encode("old\x1b[6n\x1b]2;a title\x07"));
		expect(terminal.frame().rowData[0]?.text).toBe("old");
		terminal.dispose();
	});

	it("keeps the frame a program holds until it lets go", () => {
		const { events, listener } = heard();
		const terminal = new VtTerminal(ghostty, SIZE, listener);
		written(terminal, "old\x1b[?2026h\r\x1b[2Knew");
		expect(events.holds).toEqual([true]);
		expect(terminal.frame().rowData[0]?.text).toBe("old");
		written(terminal, "\x1b[?2026l");
		expect(terminal.frame().rowData[0]?.text).toBe("new");
		written(terminal, "\x1b[?2026h!");
		terminal.releaseHold();
		expect(terminal.frame().rowData[0]?.text).toBe("new!");
		terminal.dispose();
	});

	it("encodes keys by the program's modes", () => {
		const terminal = new VtTerminal(ghostty, SIZE, heard().listener);
		expect(terminal.encodeKey(key("KeyA", "a"))).toBe("a");
		expect(terminal.encodeKey(key("KeyC", "c", { ctrlKey: true }))).toBe("\x03");
		expect(terminal.encodeKey(key("Enter", "Enter"))).toBe("\r");
		expect(terminal.encodeKey(key("ArrowUp", "ArrowUp"))).toBe("\x1b[A");
		written(terminal, "\x1b[?1h");
		expect(terminal.encodeKey(key("ArrowUp", "ArrowUp"))).toBe("\x1bOA");
		expect(terminal.encodeKey(key("ShiftLeft", "Shift", { shiftKey: true }))).toBe("");
		terminal.dispose();
	});

	it("brackets a paste when the program asks", () => {
		const terminal = new VtTerminal(ghostty, SIZE, heard().listener);
		expect(terminal.encodePaste("ls\n")).toBe("ls\r");
		written(terminal, "\x1b[?2004h");
		expect(terminal.encodePaste("ls")).toBe("\x1b[200~ls\x1b[201~");
		terminal.dispose();
	});

	it("selects a word on a double click and copies it", () => {
		const terminal = new VtTerminal(ghostty, SIZE, heard().listener);
		written(terminal, "hello world");
		const at = { col: 7, row: 0, x: 60, y: 8 };
		terminal.selectPress(at, 1_000_000n);
		terminal.selectRelease(at);
		terminal.selectPress(at, 2_000_000n);
		expect(terminal.selectRelease(at)).toBe(true);
		expect(terminal.selectedText()).toBe("world");
		expect(terminal.frame().rowData[0]?.selection).toEqual({ start: 6, end: 10 });
		terminal.clearSelection();
		expect(terminal.hasSelection()).toBe(false);
		terminal.dispose();
	});

	it("scrolls through its history", () => {
		const terminal = new VtTerminal(ghostty, SIZE, heard().listener);
		written(terminal, Array.from({ length: 10 }, (_, line) => `line ${line}`).join("\r\n"));
		expect(terminal.scrollbar()).toEqual({ total: 10, offset: 6, length: 4 });
		terminal.scroll(-2);
		expect(terminal.isAtBottom()).toBe(false);
		expect(terminal.frame().rowData[0]?.text).toBe("line 4");
		terminal.scrollToBottom();
		expect(terminal.isAtBottom()).toBe(true);
		terminal.dispose();
	});
});
