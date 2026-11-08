/** A thread's details as its card tells them: how full its window is, what its requests cost and how much was cached. */
import { describe, expect, it } from "bun:test";
import type { Turn, Usage } from "@octoii-works/octoii-client";
import { cachedShare, contextOf, fullnessOf } from "../src/core/details.ts";

type Step = Turn["steps"][number];

const step = (usage?: { readonly input_tokens: number; readonly output_tokens: number }): Step => ({
	request: "q",
	streaming: [],
	reply: { id: "e", type: "reply", request: "q", response: { id: "r", status: "completed", output: [], ...(usage === undefined ? {} : { usage }) } },
	failure: undefined,
	calls: [],
});

const turn = (...steps: Step[]): Turn => ({ id: "t", told: [], inputs: [], steps, end: undefined });

const usage = (given: Partial<Usage>): Usage => ({ input_tokens: 0, cached_tokens: 0, output_tokens: 0, reasoning_tokens: 0, cost_nanodollars: 0, ...given });

describe("a thread's details", () => {
	it("hold its window as full as its latest request that told what it used read and wrote", () => {
		const turns = [turn(step({ input_tokens: 100, output_tokens: 20 })), turn(step({ input_tokens: 900, output_tokens: 100 }), step())];
		expect(contextOf(turns, 10_000)).toEqual({ used: 1_000, window: 10_000 });
	});

	it("hold no window before a request told what it used, nor where the window is not known", () => {
		expect(contextOf([turn(step())], 10_000)).toBeUndefined();
		expect(contextOf([turn(step({ input_tokens: 1, output_tokens: 1 }))], undefined)).toBeUndefined();
		expect(contextOf([turn(step({ input_tokens: 1, output_tokens: 1 }))], 0)).toBeUndefined();
	});

	it("stand filling past seven tenths of the window, and near its end past nine", () => {
		expect([69, 70, 89, 90].map((used) => fullnessOf({ used, window: 100 }))).toEqual(["room", "filling", "filling", "full"]);
	});

	it("tell the share of what was read that came from the cache, none before anything was read", () => {
		expect(cachedShare(usage({ input_tokens: 200, cached_tokens: 80 }))).toBe(40);
		expect(cachedShare(usage({}))).toBeUndefined();
	});
});
