/** Whether a person's message runs long enough to be folded in its bubble. */
import { describe, expect, it } from "bun:test";
import { isLong } from "../src/core/messages.ts";

describe("a long message", () => {
	it("runs past a dozen lines, as the person broke them", () => {
		const lines = (count: number): string => Array.from({ length: count }, () => "a short line").join("\n");
		expect(isLong(lines(12))).toBe(false);
		expect(isLong(lines(13))).toBe(true);
	});

	it("counts the lines a long line wraps into, 72 columns to a line", () => {
		expect(isLong("x".repeat(72 * 12))).toBe(false);
		expect(isLong("x".repeat(72 * 12 + 1))).toBe(true);
	});

	it("counts a wide character, a Chinese one or a full-width form, as two columns", () => {
		expect(isLong("字".repeat(36 * 12))).toBe(false);
		expect(isLong("字".repeat(36 * 12 + 1))).toBe(true);
		expect(isLong("Ａ".repeat(36 * 12 + 1))).toBe(true);
	});
});
