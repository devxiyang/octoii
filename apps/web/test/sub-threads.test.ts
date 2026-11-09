/** Sub-threads as the thread that delegated to them shows them: how each stands, a step's gathered, what one said in a line. */
import { describe, expect, it } from "bun:test";
import type { Listed, State } from "@octoii-works/octoii-client";
import { plainLine, standingOf, standingsSummary, workedOf } from "../src/core/sub-threads.ts";
import type { CallLine } from "../src/core/timeline.ts";

const sub = (status: State["status"], span: Pick<State, "began_at" | "ended_at"> = {}): Listed => ({
	id: "s",
	manifest: { mode: "auto", parent: { thread: "p", call: "c" } },
	state: { status, ...span, inbox: [], processes: [] },
});

const delegation = (id: string, state: CallLine["state"] = "done"): CallLine => ({
	kind: "call",
	id,
	fiber: undefined,
	step: "q",
	thread: undefined,
	tool: "delegate",
	work: "delegate",
	verb: "Delegated",
	subject: undefined,
	code: false,
	aside: undefined,
	trouble: undefined,
	arguments: "{}",
	output: undefined,
	printed: undefined,
	began: undefined,
	ended: undefined,
	state,
	ask: undefined,
	calls: [],
});

describe("sub-threads", () => {
	it("stand as their status says, and, where they are not listed, as the call that gave them their task stands", () => {
		expect(standingOf(sub("created"))).toBe("running");
		expect(standingOf(sub("running"), delegation("c"))).toBe("running");
		// A task given in the background is answered at once: its sub-thread's own status says it works.
		expect(standingOf(sub("running"), delegation("c", "done"))).toBe("running");
		expect(standingOf(sub("replied"))).toBe("completed");
		expect(standingOf(sub("failed"))).toBe("failed");
		expect(standingOf(sub("stopped"))).toBe("stopped");
		expect(standingOf(undefined, delegation("c", "running"))).toBe("running");
		expect(standingOf(undefined, delegation("c", "failed"))).toBe("failed");
		expect(standingOf(undefined)).toBe("stopped");
		expect(standingsSummary(["completed", "running", "running", "failed"])).toBe("2 running · 1 completed · 1 failed");
	});

	it("worked from the first one's latest turn's beginning to the last one's end, and on while any works", () => {
		expect(workedOf([sub("created"), undefined])).toBeUndefined();
		expect(workedOf([sub("replied", { began_at: 1_000, ended_at: 4_000 })])).toEqual({ began: 1_000, ended: 4_000 });
		const done = sub("replied", { began_at: 2_000, ended_at: 9_000 });
		expect(workedOf([sub("replied", { began_at: 1_000, ended_at: 4_000 }), done, undefined])).toEqual({ began: 1_000, ended: 9_000 });
		expect(workedOf([sub("running", { began_at: 3_000 }), done])).toEqual({ began: 2_000, ended: undefined });
	});

	it("say what they said in a plain line", () => {
		expect(plainLine("- Read [the guide](https://a.b)\n- ran `zig build`  ok")).toBe("Read the guide ran zig build ok");
		expect(plainLine("## Done\nIt printed **2026**, in snake_case_names")).toBe("Done It printed 2026, in snake_case_names");
	});
});
