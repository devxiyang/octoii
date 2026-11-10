/** A message's code block: the language its fence names, and the fold of a long one. */
import { describe, expect, it } from "bun:test";
import { codeFoldOf, languageOf, writtenFoldOf } from "../src/core/code.ts";

/** A block of `count` lines, each saying which it is. */
function block(count: number): string {
	return Array.from({ length: count }, (_, index) => `line ${String(index + 1)}`).join("\n");
}

describe("a code block's language", () => {
	it("is the highlighter's, by its id or any other name it answers to, however the fence wrote it", () => {
		expect(languageOf("typescript")).toEqual({ id: "typescript", name: "TypeScript" });
		expect(languageOf("ts")?.id).toBe("typescript");
		expect(languageOf("Python")?.id).toBe("python");
		expect(languageOf("sh")?.id).toBe("shellscript");
		expect(languageOf("diff")?.id).toBe("diff");
		expect(languageOf("nothing-it-knows")).toBeUndefined();
	});
});

describe("a code block's fold", () => {
	it("leaves a block whole while it runs a few lines past the head, and folds a longer one to its head", () => {
		expect(codeFoldOf(block(28))).toBeUndefined();
		const fold = codeFoldOf(block(29));
		expect(fold?.lines).toBe(29);
		expect(fold?.head.split("\n")).toEqual(block(20).split("\n"));
	});

	it("ends the head on a line that says something", () => {
		const lines = block(40).split("\n");
		lines[18] = "";
		lines[19] = "  ";
		const fold = codeFoldOf(lines.join("\n"));
		expect(fold?.head.split("\n").at(-1)).toBe("line 18");
		expect(fold?.lines).toBe(40);
	});

	it("folds code still being written to its head once it runs past it, so it never shows more than the whole block may", () => {
		expect(writtenFoldOf(block(20))).toBeUndefined();
		const fold = writtenFoldOf(block(21));
		expect(fold?.lines).toBe(21);
		expect(fold?.head).toBe(block(20));
	});
});
