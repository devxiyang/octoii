import { describe, expect, it } from "bun:test";
import { pressed, shortcutLabel, shortcutOf } from "../src/core/shortcuts.ts";

const press = (code: string, keys: { readonly meta?: boolean; readonly shift?: boolean; readonly alt?: boolean; readonly key?: string } = {}) => ({
	metaKey: keys.meta ?? true,
	ctrlKey: false,
	altKey: keys.alt ?? false,
	shiftKey: keys.shift ?? false,
	code,
	key: keys.key ?? "",
});

describe("a shortcut", () => {
	it("reads a letter, a digit and punctuation by where the key is, and the character it types", () => {
		expect(shortcutOf("mod+shift+d")).toEqual({ mod: true, shift: true, alt: false, code: "KeyD", key: "d" });
		expect(shortcutOf("mod+.")).toEqual({ mod: true, shift: false, alt: false, code: "Period", key: "." });
		expect(shortcutOf("mod+'")).toEqual({ mod: true, shift: false, alt: false, code: "Quote", key: "'" });
		expect(shortcutOf("mod+1")).toEqual({ mod: true, shift: false, alt: false, code: "Digit1", key: "1" });
		expect(shortcutOf("mod+alt+b")).toEqual({ mod: true, shift: false, alt: true, code: "KeyB", key: "b" });
		expect(shortcutOf("/")).toEqual({ mod: false, shift: false, alt: false, code: "Slash", key: "/" });
	});

	it("is pressed with Cmd or Ctrl, Shift and Alt as it says", () => {
		expect(pressed(shortcutOf("mod+."), press("Period"))).toBe(true);
		expect(pressed(shortcutOf("mod+."), press("Period", { shift: true }))).toBe(false);
		expect(pressed(shortcutOf("mod+shift+."), press("Period", { shift: true }))).toBe(true);
		expect(pressed(shortcutOf("mod+."), press("Period", { meta: false }))).toBe(false);
		expect(pressed(shortcutOf("mod+."), press("Period", { alt: true }))).toBe(false);
		expect(pressed(shortcutOf("mod+alt+b"), press("KeyB", { alt: true }))).toBe(true);
		expect(pressed(shortcutOf("mod+alt+b"), press("KeyB"))).toBe(false);
	});

	it("is pressed alone by the character it types, wherever the layout puts it", () => {
		expect(pressed(shortcutOf("/"), press("Slash", { meta: false, key: "/" }))).toBe(true);
		// A German layout types the slash with Shift on the key of 7.
		expect(pressed(shortcutOf("/"), press("Digit7", { meta: false, shift: true, key: "/" }))).toBe(true);
		expect(pressed(shortcutOf("/"), press("Slash", { key: "/" }))).toBe(false);
		expect(pressed(shortcutOf("1"), press("Digit1", { meta: false, alt: true, key: "¡" }))).toBe(false);
	});

	it("reads as its caps show it", () => {
		expect(shortcutLabel("mod+shift+d")).toBe("⌘⇧D");
		expect(shortcutLabel("mod+'")).toBe("⌘'");
		expect(shortcutLabel("mod+alt+b")).toBe("⌘⌥B");
	});
});
