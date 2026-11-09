/** What a session is given of a conversation past the message it stands after. */
import { describe, expect, it } from "bun:test";
import type { Block, Message } from "../src/anthropic.ts";
import { toldAfter } from "../src/told.ts";

const image: Block = { type: "image", source: { type: "base64", media_type: "image/png", data: "iVBOR" } };
const conversation: Message[] = [
	{ role: "user", content: "Fix the build" },
	{
		role: "assistant",
		content: [
			{ type: "thinking", thinking: "look first", signature: "s" },
			{ type: "tool_use", id: "c1", name: "read", input: { path: "build.zig" } },
		],
	},
	{ role: "user", content: [{ type: "tool_result", tool_use_id: "c1", content: "const std = ..." }] },
	{ role: "assistant", content: [{ type: "tool_use", id: "c2", name: "shell", input: { command: "zig build" } }] },
	{ role: "user", content: [{ type: "tool_result", tool_use_id: "c2", content: "ok", is_error: false }, { type: "text", text: "and now the tests" }, image] },
];

const texts = (blocks: readonly Block[]): string[] => blocks.map((block) => (block.type === "text" ? block.text : `[${block.type}]`));

describe("what a session is given", () => {
	it("standing after the model's last message: the results of its calls, then the person's words", () => {
		const told = toldAfter(conversation, 3);
		expect(told.results.map((result) => result.tool_use_id)).toEqual(["c2"]);
		expect(texts(told.rest)).toEqual(["and now the tests", "[image]"]);
	});

	it("standing earlier: its results, then what it missed between checkpoint tags, then the person's words", () => {
		const told = toldAfter(conversation, 1);
		expect(told.results.map((result) => result.tool_use_id)).toEqual(["c1"]);
		expect(texts(told.rest)).toEqual([
			expect.stringMatching(/^<conversation-checkpoint>\n/),
			"<assistant>",
			`<tool-call>\n{"id":"c2","name":"shell","input":{"command":"zig build"}}\n</tool-call>`,
			"</assistant>",
			"<user>",
			`<tool-result>\n{"id":"c2","is_error":false,"content":"ok"}\n</tool-result>`,
			"</user>",
			"</conversation-checkpoint>",
			"and now the tests",
			"[image]",
		]);
	});

	it("standing nowhere: the whole conversation as history, thinking left out", () => {
		const told = toldAfter(conversation, -1);
		expect(told.results).toEqual([]);
		const words = texts(told.rest);
		expect(words.slice(0, 3)).toEqual([expect.stringMatching(/^<conversation-checkpoint>\n/), "<user>", "Fix the build"]);
		expect(words.join("\n")).not.toContain("look first");
		// A first request is the person's words alone.
		expect(texts(toldAfter([{ role: "user", content: "hello" }], -1).rest)).toEqual(["hello"]);
	});
});
