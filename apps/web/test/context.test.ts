/** What fills a thread's window as its details show it: each part's share of the window, and whether it compacts now. */
import { describe, expect, it } from "bun:test";
import type { Listed, Process } from "@octoii-works/octoii-client";
import { isCompacting, PARTS, sharesOf } from "../src/core/context.ts";

/** A thread at rest, its fibers those given. */
const row = (processes: readonly Process[]): Listed => ({
	id: "t1",
	manifest: { vocabulary: 1, mode: "default" },
	state: { status: "replied", inbox: [], processes: [...processes] },
});

/** A fiber of `program`, standing as `state` says. */
const fiber = (program: string, state: Process["state"]): Process => ({ key: program, program, state, requests: [] });

describe("the context", () => {
	it("is shared among its parts, each its fraction of the window its model takes", () => {
		const shares = sharesOf(
			{
				tokens: 3_000,
				parts: [
					{ part: "system", tokens: 1_000 },
					{ part: "messages", tokens: 2_000 },
				],
			},
			10_000,
		);
		expect(shares).toEqual([
			{ part: "system", tokens: 1_000, fraction: 0.1 },
			{ part: "messages", tokens: 2_000, fraction: 0.2 },
		]);
		expect(sharesOf({ tokens: 1, parts: [{ part: "tools", tokens: 1 }] }, 0)[0]?.fraction).toBe(0);
		// What Octoii tells the model is drawn neutral; the rest each in a hue of its own.
		const hues = Object.values(PARTS).flatMap((part) => (part.hue === undefined ? [] : [part.hue]));
		expect(new Set(hues).size).toBe(hues.length);
		expect(PARTS.system.hue).toBeUndefined();
	});

	it("is compacted while the thread's one compaction runs, not once it ended", () => {
		expect(isCompacting(row([fiber("siphon.thread", "sleeping"), fiber("siphon.compact", "sleeping")]))).toBe(true);
		expect(isCompacting(row([fiber("siphon.compact", "zombie")]))).toBe(false);
		expect(isCompacting(row([]))).toBe(false);
		expect(isCompacting(undefined)).toBe(false);
	});
});
