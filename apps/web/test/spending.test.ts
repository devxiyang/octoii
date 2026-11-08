/** Where a thread's money and tokens went: its requests as its log tells them, and the waterfall they are laid as. */
import { describe, expect, it } from "bun:test";
import { conversationOf, type Entry, type ThreadView } from "@octoii-works/octoii-client";
import { barsOf, mostOf, spentOf } from "../src/core/spending.ts";

/** A JSON value, as the log holds what a model said. */
type Json = string | number | boolean | null | readonly Json[] | { readonly [key: string]: Json };

/** An id minted at `ms`, as a UUIDv7 holds its time in its first 48 bits. */
function idAt(ms: number, serial: number): string {
	const time = ms.toString(16).padStart(12, "0");
	return `${time.slice(0, 8)}-${time.slice(8)}-7000-8000-${String(serial).padStart(12, "0")}`;
}

const START = 1_700_000_000_000;
const id = (seconds: number, serial: number): string => idAt(START + seconds * 1000, serial);
const said = (at: string, text: string): Entry => ({ id: at, type: "input", delivery_id: `d${at}`, actor: "person", message: { role: "user", content: text } });
const call = (callId: string, name: string, args: Json): Json => ({ type: "function_call", call_id: callId, name, arguments: JSON.stringify(args) });
const words = (text: string): Json => ({ type: "message", id: "m", role: "assistant", content: [{ type: "output_text", text, annotations: [] }] });
const usage = (input: number, cached: number, output: number, cost: number): Json => ({
	input_tokens: input,
	input_tokens_details: { cached_tokens: cached },
	output_tokens: output,
	output_tokens_details: { reasoning_tokens: 0 },
	total_tokens: input + output,
	cost,
});
const reply = (at: string, request: string, output: Json[], used: Json): Entry => ({
	id: at,
	type: "reply",
	request,
	response: { id: "r", status: "completed", model: "openrouter/m", output, usage: used },
});

function viewOf(entries: Entry[]): ThreadView {
	return {
		entries,
		read: true,
		complete: true,
		state: { status: "replied", inbox: [], processes: [] },
		streaming: new Map(),
		failure: undefined,
		terminals: [],
		pages: [],
	};
}

describe("a thread's spending", () => {
	it("is each request its log tells of, by what it did, its model, what it read and wrote, cost and took", () => {
		const conversation = conversationOf(
			viewOf([
				said(id(0, 1), "Fix the build"),
				reply(id(3, 3), id(1, 2), [call("c1", "read", { path: "build.zig" }), call("c2", "shell", { command: "zig build" })], usage(1000, 800, 50, 0.002)),
				{ id: id(4, 4), type: "result", status: "ok", call_output: { call_id: "c1", output: "…" } },
				{ id: id(5, 5), type: "result", status: "ok", call_output: { call_id: "c2", output: "…" } },
				reply(id(7, 7), id(6, 6), [words("Fixed it.")], usage(1200, 1000, 20, 0.001)),
				{ id: id(8, 8), type: "turn-end", turn: "t1", outcome: "replied" },
			]),
		);
		const spent = spentOf(conversation.turns, conversation.compactions);
		expect(spent).toEqual([
			{ key: id(1, 2), turn: 1, words: "Read build.zig +1", model: "openrouter/m", input: 1000, cached: 800, output: 50, cost: 0.002, took: 2000 },
			{ key: id(6, 6), turn: 1, words: "Answered", model: "openrouter/m", input: 1200, cached: 1000, output: 20, cost: 0.001, took: 1000 },
		]);
		// Laid by cost, each starts where those before it left the total; by tokens, likewise.
		expect(barsOf(spent, "cost").map((bar) => [bar.start, bar.width].map((share) => Math.round(share * 1000) / 1000))).toEqual([
			[0, 0.667],
			[0.667, 0.333],
		]);
		expect(barsOf(spent, "tokens")[1]?.start).toBeCloseTo(1050 / 2270, 5);
		expect(mostOf(spent, "cost")?.key).toBe(id(1, 2));
		expect(mostOf(spent, "tokens")?.key).toBe(id(6, 6));
		expect(mostOf([], "cost")).toBeUndefined();
	});

	it("tells a compaction's request among the turns', by the turn its id falls in, a thread's at rest by the turn before", () => {
		const recap = (at: string, request: string): Entry => ({
			id: at,
			type: "compaction",
			request,
			response: { model: "openrouter/m", usage: usage(500, 0, 30, 0.0005) },
			kept: at,
			from: at,
		});
		const conversation = conversationOf(
			viewOf([
				said(id(0, 1), "Fix the build"),
				reply(id(2, 3), id(1, 2), [words("Fixed it.")], usage(1000, 800, 50, 0.002)),
				{ id: id(3, 4), type: "turn-end", turn: "t1", outcome: "replied" },
				recap(id(5, 6), id(4, 5)),
			]),
		);
		expect(conversation.turns).toHaveLength(1);
		expect(spentOf(conversation.turns, conversation.compactions).map((each) => [each.key, each.turn, each.words])).toEqual([
			[id(1, 2), 1, "Answered"],
			[id(4, 5), 1, "Summed up the thread"],
		]);
	});
});
