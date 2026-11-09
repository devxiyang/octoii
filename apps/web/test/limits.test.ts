/** A thread its model's quota limits: the window in words, and the other accounts it may go on with. */
import { describe, expect, it } from "bun:test";
import type { Model } from "@octoii-works/octoii-client";
import { onwardOf, windowWords } from "../src/core/limits.ts";
import type { Directory } from "../src/core/models.ts";

const model = (provider: string, id: string): Model => ({ id, name: id, octoii: { provider } });

const DIRECTORY: Directory = {
	models: [
		model("chatgpt", "gpt-6-luna"),
		model("work", "gpt-6-luna"),
		model("spent", "gpt-6-luna"),
		model("signed-out", "gpt-6-luna"),
		model("other", "gpt-6-terra"),
		model("claude", "claude-opus-5-5"),
	],
	providers: [
		{ id: "chatgpt", name: "ChatGPT", connects: "sign_in", credential: "oauth" },
		{ id: "work", name: "ChatGPT · Work", connects: "sign_in", credential: "oauth", account: { of: "chatgpt", name: "Work" } },
		{ id: "spent", name: "ChatGPT · Spent", connects: "sign_in", credential: "oauth", account: { of: "chatgpt", name: "Spent" }, used_up: { reset_at_ms: 9 } },
		{ id: "signed-out", name: "ChatGPT · Out", connects: "sign_in", account: { of: "chatgpt", name: "Out" } },
		{ id: "other", name: "ChatGPT · Other", connects: "sign_in", credential: "oauth", account: { of: "chatgpt", name: "Other" } },
		{ id: "claude", name: "Claude", connects: "server" },
	],
};

describe("a limited thread", () => {
	it("names the window its quota is counted over", () => {
		expect(windowWords(300)).toBe("5-hour");
		expect(windowWords(10_080)).toBe("weekly");
		expect(windowWords(90)).toBe("90-minute");
		expect(windowWords(undefined)).toBeUndefined();
	});

	it("goes on with the other accounts of its provider that are connected, have room and serve its model", () => {
		const onward = onwardOf(DIRECTORY, { provider: "chatgpt", reset_at_ms: 9 }, "chatgpt/gpt-6-luna");
		expect(onward.map((each) => each.reference)).toEqual(["work/gpt-6-luna"]);
		// From an added account, the host's own is another account of the same provider.
		expect(onwardOf(DIRECTORY, { provider: "work", reset_at_ms: 9 }, "work/gpt-6-luna").map((each) => each.reference)).toEqual(["chatgpt/gpt-6-luna"]);
		expect(onwardOf(DIRECTORY, { provider: "claude", reset_at_ms: 9 }, "claude/claude-opus-5-5")).toEqual([]);
	});
});
