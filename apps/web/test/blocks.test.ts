/** Markdown's blocks, as a reply is shown a block at a time, and of words still being written those whose blocks are whole. */
import { describe, expect, it } from "bun:test";
import { blocksOf, settledOf } from "../src/core/blocks.ts";

describe("a reply's blocks", () => {
	it("sets blocks apart at blank lines, but within a fenced code block, and where what follows is indented", () => {
		const text = "# Plan\nFirst.\n\n1. Build\n\n   then test\n\n```ts\nconst a = 1;\n\nconst b = 2;\n```\n\nDone.";
		expect(blocksOf(text).map((block) => block.text)).toEqual([
			"# Plan\nFirst.",
			"1. Build\n\n   then test",
			"```ts\nconst a = 1;\n\nconst b = 2;\n```",
			"Done.",
		]);
		// Each block is known by where it begins, which stays as the text grows.
		expect(blocksOf(text).map((block) => block.start)).toEqual([0, 15, 39, 77]);
		expect(blocksOf("")).toEqual([]);
	});

	it("gives of words being written those whose blocks are whole, the block being written left out", () => {
		expect(settledOf("One.\n\nTwo is being wri")).toBe("One.");
		expect(settledOf("One is being wri")).toBe("");
		expect(settledOf("```\na\n\nb")).toBe("");
	});
});
