/** A name's monogram: its letters, and its hue — the same for a name, or one of their own for names side by side. */
import { describe, expect, it } from "bun:test";
import { huesApart, MONOGRAM_HUES, monogramHue, monogramOf } from "../src/core/monogram.ts";

describe("a monogram", () => {
	it("shows a one-word name's first letter, else its first two words' first letters, a capital within a word parting words", () => {
		const names = ["octoii", "octoii-cloud", "LM Studio", "DeepSeek", "OpenAI", "z.ai", "my_app", "Claude · Work", ""];
		expect(names.map(monogramOf)).toEqual(["O", "OC", "LS", "DS", "OA", "ZA", "MA", "CW", ""]);
	});

	it("gives names side by side hues of their own, as far as there are hues, an earlier name keeping its own", () => {
		const names = ["octoii", "octoii-cloud", "beak", "quickts", "typebox", "picoquic", "picotls", "siphon"];
		const hues = huesApart(names);
		expect(new Set(hues).size).toBe(MONOGRAM_HUES.length);
		expect(hues[0]).toBe(monogramHue("octoii"));
		// A name that comes later never changes the hues of those before it.
		expect(huesApart([...names.slice(0, 3), "later"]).slice(0, 3)).toEqual(hues.slice(0, 3));
		// Past the hues there are, a name takes its own.
		expect(huesApart([...names, "ninth"])[8]).toBe(monogramHue("ninth"));
	});
});
