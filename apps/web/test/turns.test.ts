/** Asking for many things at most a few at a time. */
import { describe, expect, it } from "bun:test";
import { inTurns } from "../src/core/turns.ts";

/** Lets what was answered be taken and the next be asked. */
async function settle(): Promise<void> {
	for (let tick = 0; tick < 10; tick += 1) await Promise.resolve();
}

describe("asking in turns", () => {
	it("gives each item's answer in the items' order, never asking more than the most at once", async () => {
		const asked: (() => void)[] = [];
		let asking = 0;
		let most = 0;
		const given = inTurns(
			[1, 2, 3, 4, 5],
			2,
			(item) =>
				new Promise<number>((resolve) => {
					asking += 1;
					most = Math.max(most, asking);
					asked.push(() => {
						asking -= 1;
						resolve(item * 10);
					});
				}),
		);
		// The latest asked is answered first, each answer letting the next be asked.
		for (let round = 0; round < 5; round += 1) {
			await settle();
			asked.pop()?.();
		}
		expect(await given).toEqual([10, 20, 30, 40, 50]);
		expect(most).toBe(2);
		expect(await inTurns([], 3, async (item: number) => item)).toEqual([]);
	});
});
