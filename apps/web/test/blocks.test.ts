/** Markdown's blocks, as a reply is drawn a block at a time, whether a block's code fence is still open, and what of a block being written shows. */
import { describe, expect, it } from "bun:test";
import { blocksOf, fenceOpen, showableOf } from "../src/core/blocks.ts";

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

	it("tells a block whose code fence is not closed yet from one whose is, and from one with no fence", () => {
		expect(fenceOpen("```ts\nconst a = 1;")).toBe(true);
		expect(fenceOpen("```ts\nconst a = 1;\n```")).toBe(false);
		// A fence is closed by one at least as long, of its own character.
		expect(fenceOpen("````\na\n```")).toBe(true);
		expect(fenceOpen("~~~\na\n```")).toBe(true);
		expect(fenceOpen("~~~\na\n~~~~")).toBe(false);
		expect(fenceOpen("Words, and `code`.")).toBe(false);
	});

	it("holds back a table's header till the row under it that makes it a table is whole, and shows any other block as it is", () => {
		expect(showableOf("| Part | Cost")).toBe("");
		expect(showableOf("| Part | Cost |\n| --- | --")).toBe("");
		expect(showableOf("| Part | Cost |\n| --- | --- |\n")).toBe("| Part | Cost |\n| --- | --- |\n");
		expect(showableOf("| Part | Cost |\n| :-- | --: |\n| Reading")).toBe("| Part | Cost |\n| :-- | --: |\n| Reading");
		expect(showableOf("Words, and | a pipe")).toBe("Words, and | a pipe");
	});
});
