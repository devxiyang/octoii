/**
 * A thread put together by its ids: turns from the log's runs, each step by its request's key, each call by its id with
 * its result and its fiber, the calls a script made under the call that runs it, and what waits on the person; a turn
 * that ended the same object from one view to the next, and of the turn that runs, each part nothing is laid over.
 */
import { describe, expect, test } from "bun:test";
import { conversationOf, type Entry, type Process, type ThreadView } from "../src/index.ts";

/** A JSON value, as the log holds what a model said. */
type Json = string | number | boolean | null | readonly Json[] | { readonly [key: string]: Json };

const response = (output: Json[]): Json => ({ id: "r", status: "completed", output });
const text = (value: string): Json => ({ type: "message", id: "m", role: "assistant", content: [{ type: "output_text", text: value, annotations: [] }] });
const call = (id: string, name: string): Json => ({ type: "function_call", call_id: id, name, arguments: "{}" });
const made = (id: string, name: string) => ({ type: "function_call" as const, call_id: id, name, arguments: "{}" });
const input = (id: string, said: string): Entry => ({ id, type: "input", delivery_id: `d${id}`, actor: "person", message: { role: "user", content: said } });
const fiber = (key: string, program: string, parent: string | undefined, given?: unknown, requests: Process["requests"] = []): Process => ({
	key,
	program,
	state: "sleeping",
	requests,
	...(parent === undefined ? {} : { parent }),
	...(given === undefined ? {} : { input: given }),
});

function viewOf(entries: Entry[], processes: Process[], streaming: [string, unknown[]][] = []): ThreadView {
	return {
		entries,
		read: true,
		complete: true,
		state: { status: "running", inbox: [{ id: "9", actor: "person", message: { role: "user", content: "and then?" } }], processes },
		streaming: new Map(streaming),
		failure: undefined,
		terminals: [],
		pages: [],
	};
}

describe("a thread's conversation, by its ids", () => {
	test("a turn ended holds its steps and calls with their results; a turn that runs, its fiber, its calls' fibers and a script's calls", () => {
		const view = viewOf(
			[
				{ id: "1", type: "system", request: "q0", sections: [{ name: "base", text: "b" }], tools: [] },
				input("2", "read a.md"),
				{ id: "3", type: "reply", request: "q1", response: response([call("c1", "read")]) },
				{ id: "4", type: "result", call: "k1", status: "ok", call_output: { call_id: "c1", output: { text: "alpha" } } },
				{ id: "5", type: "reply", request: "q2", response: response([text("It says alpha.")]) },
				{ id: "6", type: "turn-end", turn: "t1", outcome: "replied" },
				input("7", "run a script"),
				{ id: "8", type: "reply", request: "q3", response: response([call("c2", "execute")]) },
				{ id: "9", type: "calls", under: "c2", calls: [made("k3", "read"), made("k4", "glob")] },
				{ id: "10", type: "result", call: "k4", under: "c2", status: "ok", call_output: { call_id: "k4", output: "a.md" } },
			],
			[
				fiber("main", "siphon.thread", undefined),
				fiber("t2", "siphon.turn", "main"),
				fiber("k2", "siphon.call", "t2", { call_id: "c2", name: "execute", arguments: "{}" }),
				fiber("s2", "siphon.script", "k2"),
				fiber("k3", "siphon.call", "s2", { call_id: "k3", name: "read", arguments: "{}" }),
				fiber("trust-1", "siphon.trust", "main", undefined, [{ key: "a1", name: "trust", payload: { folder: "/w" }, answer: { type: "object" } }]),
			],
		);
		const conversation = conversationOf(view);
		expect(conversationOf(view)).toBe(conversation);
		const [ended, running] = conversation.turns;
		expect(conversation.turns).toHaveLength(2);
		expect(ended?.id).toBe("t1");
		expect(ended?.told.map((entry) => entry.id)).toEqual(["1"]);
		expect(ended?.steps.map((step) => step.request)).toEqual(["q1", "q2"]);
		expect(ended?.steps[0]?.calls[0]?.result?.id).toBe("4");
		expect(ended?.end?.outcome).toBe("replied");
		expect(running?.id).toBe("t2");
		expect(running?.end).toBeUndefined();
		const execute = running?.steps[0]?.calls[0];
		expect([execute?.name, execute?.fiber?.key]).toEqual(["execute", "k2"]);
		// The calls its script made are the log's, each settled by its result, the one that runs with its fiber.
		expect(execute?.calls.map((inner) => [inner.name, inner.fiber?.key, inner.result?.id])).toEqual([
			["read", "k3", undefined],
			["glob", undefined, "10"],
		]);
		expect(conversation.asks.map((ask) => [ask.fiber, ask.request.key])).toEqual([["trust-1", "a1"]]);
		expect(conversation.inbox.map((input) => input.id)).toEqual(["9"]);
	});

	test("the request a turn waits on its model for is a step of its own, what streams of it there, before its reply comes", () => {
		const view = viewOf(
			[input("1", "hello")],
			[fiber("main", "siphon.thread", undefined), fiber("t1", "siphon.turn", "main", undefined, [{ key: "q1", name: "model" }])],
			[["q1", ["Hel", "lo"]]],
		);
		const [turn] = conversationOf(view).turns;
		expect(turn?.id).toBe("t1");
		expect(turn?.steps.map((step) => [step.request, step.streaming, step.reply])).toEqual([["q1", ["Hel", "lo"], undefined]]);
	});
	test("a turn that ended is the same object from one view to the next, and so is each part of the turn that runs that nothing is laid over", () => {
		const entries: Entry[] = [
			input("1", "read a.md"),
			{ id: "2", type: "reply", request: "q1", response: response([call("c1", "read")]) },
			{ id: "3", type: "result", call: "k1", status: "ok", call_output: { call_id: "c1", output: "alpha" } },
			{ id: "4", type: "turn-end", turn: "t1", outcome: "replied" },
			input("5", "and b.md"),
			{ id: "6", type: "reply", request: "q2", response: response([call("c2", "read"), call("c3", "execute")]) },
		];
		const processes = [
			fiber("main", "siphon.thread", undefined),
			fiber("t2", "siphon.turn", "main", undefined, [{ key: "q3", name: "model" }]),
			fiber("k3", "siphon.call", "t2", { call_id: "c3", name: "execute", arguments: "{}" }, [{ key: "a3", name: "tool" }]),
		];
		const before = conversationOf(viewOf(entries, processes));
		// Something streams of the next request: the view is another, what it changed alone made again.
		const after = conversationOf(viewOf(entries, processes, [["q3", ["Wor"]]]));
		const [ended, running] = before.turns;
		const [endedAfter, runningAfter] = after.turns;
		expect(endedAfter).toBe(ended);
		expect(runningAfter?.steps[1]?.streaming).toEqual(["Wor"]);
		// The call nothing is laid over is the log's own, the same object; the one that runs has its fiber laid over it,
		// and what streams of the request its tool is asked by.
		expect(runningAfter?.steps[0]?.calls[0]).toBe(running?.steps[0]?.calls[0]);
		expect(runningAfter?.steps[0]?.calls.map((each) => each.fiber?.key)).toEqual([undefined, "k3"]);
		const printing = conversationOf(viewOf(entries, processes, [["a3", [{ text: "built" }]]]));
		expect(printing.turns[1]?.steps[0]?.calls[1]?.streaming).toEqual([{ text: "built" }]);
		// The log grows by the turn's next entry: the turn that ended is still the same object.
		const grown = conversationOf(
			viewOf([...entries, { id: "7", type: "result", call: "k2", status: "ok", call_output: { call_id: "c2", output: "beta" } }], processes),
		);
		expect(grown.turns[0]).toBe(ended);
		expect(grown.turns[1]?.steps[0]?.calls[0]?.result?.id).toBe("7");
	});

	test("a compaction is the thread's, by its id, none a turn's: one made at rest begins no turn", () => {
		const compacted: Entry[] = [
			input("1", "hello"),
			{ id: "2", type: "reply", request: "q1", response: response([text("Hi")]) },
			{ id: "3", type: "turn-end", turn: "t1", outcome: "replied" },
			{ id: "4", type: "compaction", request: "q2", response: response([text("They said hello.")]), kept: "1", from: "1" },
			{ id: "5", type: "system", request: "q3", sections: [{ name: "base", text: "b" }], tools: [] },
		];
		const conversation = conversationOf(viewOf(compacted, []));
		expect(conversation.turns).toHaveLength(1);
		expect(conversation.compactions.map((each) => each.id)).toEqual(["4"]);
		// The next turn begins with the next input, as ever.
		const next = conversationOf(viewOf([...compacted, input("6", "and now?")], [])).turns;
		expect(next.map((turn) => turn.inputs.map((each) => each.id))).toEqual([["1"], ["6"]]);
	});

	test("a turn whose first entries were read later, or let go of, is put together again from the run it holds now", () => {
		const tail: Entry[] = [
			{ id: "3", type: "reply", request: "q1", response: response([text("alpha")]) },
			{ id: "4", type: "turn-end", turn: "t1", outcome: "replied" },
		];
		const partial = conversationOf(viewOf(tail, []));
		const whole = conversationOf(viewOf([input("2", "say alpha"), ...tail], []));
		expect(partial.turns[0]?.inputs).toEqual([]);
		expect(whole.turns[0]).not.toBe(partial.turns[0]);
		expect(whole.turns[0]?.inputs.map((each) => each.id)).toEqual(["2"]);
	});
});
