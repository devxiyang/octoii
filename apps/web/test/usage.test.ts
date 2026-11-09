/**
 * The plans' limits pooled: a card for each window of a provider's, how much its accounts have left together and how
 * they spend it, what its next reset gives back, and a column for each account in the order they were added.
 */
import { describe, expect, it } from "bun:test";
import type { Provider, ProviderStatus } from "@octoii-works/octoii-client";
import { monogramHue } from "../src/core/monogram.ts";
import { countdown, paceOf, usageOf } from "../src/core/usage.ts";

const HOUR = 60 * 60_000;

const PROVIDERS: readonly Provider[] = [
	{ id: "claude", name: "Claude", connects: "agent" },
	{ id: "openai", name: "OpenAI", connects: "api_key", credential: "api_key" },
	{ id: "work", name: "Claude · Work", connects: "agent", account: { of: "claude", name: "Work" } },
	{ id: "spare", name: "Claude · Spare", connects: "agent", account: { of: "claude", name: "Spare" } },
];

describe("the usage page", () => {
	it("pools each window of a provider's accounts, a column for each account that tells its limits", () => {
		const statuses = new Map<string, ProviderStatus>([
			[
				"claude",
				{
					connected: true,
					limits: [
						{ window_minutes: 300, used_percent: 40, resets_at_ms: 3 * HOUR },
						{ window_minutes: 10_080, scope: "Opus", used_percent: 10 },
					],
				},
			],
			["work", { connected: true, limits: [{ window_minutes: 300, used_percent: 90, resets_at_ms: HOUR }] }],
			["spare", { connected: false }],
			["openai", { connected: true }],
		]);
		expect(usageOf(PROVIDERS, statuses, 0)).toEqual([
			{
				provider: "Claude",
				windows: [
					{
						key: "300 ",
						title: "5-hour limit",
						minutes: 300,
						leftPercent: 35,
						pace: "on",
						next: { percent: 45, at: HOUR },
						columns: [
							{ id: "claude", segment: { account: "Claude", hue: monogramHue("Claude"), leftPercent: 60, resetsAt: 3 * HOUR, timeLeft: 0.6 } },
							{ id: "work", segment: { account: "Work", hue: monogramHue("Claude · Work"), leftPercent: 10, resetsAt: HOUR, timeLeft: 0.2 } },
						],
					},
					{
						key: "10080 Opus",
						title: "Weekly limit · Opus",
						minutes: 10_080,
						leftPercent: 90,
						pace: undefined,
						next: undefined,
						columns: [
							{ id: "claude", segment: { account: "Claude", hue: monogramHue("Claude"), leftPercent: 90, resetsAt: undefined, timeLeft: undefined } },
							{ id: "work", segment: undefined },
						],
					},
				],
			},
		]);
	});

	it("gives back nothing at a reset where the pool is one account", () => {
		const statuses = new Map<string, ProviderStatus>([
			["claude", { connected: true, limits: [{ window_minutes: 300, used_percent: 40, resets_at_ms: HOUR }] }],
		]);
		expect(usageOf(PROVIDERS, statuses, 0)[0]?.windows[0]?.next).toBeUndefined();
	});

	it("judges a window's pace by how much of it is used against how much of its time has passed", () => {
		expect(paceOf(50, 0.3)).toBe("ahead");
		expect(paceOf(34, 0.3)).toBe("on");
		expect(paceOf(10, 0.3)).toBe("under");
	});

	it("tells how long till a window is given again", () => {
		expect(countdown(55 * HOUR, 0)).toBe("2d 7h");
		expect(countdown(3 * HOUR + 51 * 60_000, 0)).toBe("3h 51m");
		expect(countdown(12 * 60_000, 0)).toBe("12m");
	});
});
