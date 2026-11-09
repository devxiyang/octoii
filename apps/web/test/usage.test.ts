/** The plans' limits pooled: a card for each window of a provider's, a line for each account, the soonest given again first. */
import { describe, expect, it } from "bun:test";
import type { Provider, ProviderStatus } from "@octoii-works/octoii-client";
import { usageOf } from "../src/core/usage.ts";

const PROVIDERS: readonly Provider[] = [
	{ id: "claude", name: "Claude", connects: "server" },
	{ id: "openai", name: "OpenAI", connects: "api_key", credential: "api_key" },
	{ id: "work", name: "Claude · Work", connects: "server", account: { of: "claude", name: "Work" } },
];

describe("the usage page", () => {
	it("pools each window of a provider's accounts, the account given again soonest first", () => {
		const statuses = new Map<string, ProviderStatus>([
			[
				"claude",
				{
					connected: true,
					limits: [
						{ window_minutes: 300, used_percent: 40, resets_at_ms: 2_000 },
						{ window_minutes: 10_080, scope: "Opus", used_percent: 10 },
					],
				},
			],
			["work", { connected: true, limits: [{ window_minutes: 300, used_percent: 90, resets_at_ms: 1_000 }] }],
			["openai", { connected: true }],
		]);
		expect(usageOf(PROVIDERS, statuses)).toEqual([
			{
				provider: "Claude",
				windows: [
					{
						key: "300 ",
						title: "5-hour limit",
						lines: [
							{ account: "Work", usedPercent: 90, resetsAt: 1_000 },
							{ account: "Claude", usedPercent: 40, resetsAt: 2_000 },
						],
					},
					{ key: "10080 Opus", title: "Weekly limit · Opus", lines: [{ account: "Claude", usedPercent: 10, resetsAt: undefined }] },
				],
			},
		]);
	});
});
