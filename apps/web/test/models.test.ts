/** The models a thread can run with, as the picker lists them from the node's models and how its providers are connected. */
import { describe, expect, it } from "bun:test";
import type { Listed, Model } from "@octoii-works/octoii-client";
import {
	type Directory,
	effortLabel,
	effortsOf,
	modelChoices,
	modelLabel,
	modelOf,
	modelSections,
	nextEffort,
	providerName,
	recentModelsOf,
	toggledFavorite,
} from "../src/core/models.ts";

const model = (provider: string, id: string, name: string, released: string, context?: number): Model => ({
	id,
	name,
	...(context === undefined ? {} : { context_length: context }),
	octoii: { provider, release_date: released },
});

const DIRECTORY: Directory = {
	models: [
		model("openrouter", "deepseek/deepseek-v4.1-flash", "DeepSeek: DeepSeek V4.1 Flash", "2026-08-01", 1_000_000),
		model("openrouter", "z/old", "Z: Old", "2025-01-01"),
		model("anthropic", "claude-opus-5-5", "Claude Opus 5.5", "2026-09-01", 400_000),
		model("ollama", "qwen4:8b", "qwen4:8b", "2026-07-01"),
	],
	providers: [
		{ id: "openrouter", name: "OpenRouter", connects: "api_key", credential: "api_key" },
		{ id: "anthropic", name: "Anthropic", connects: "api_key" },
		{ id: "ollama", name: "Ollama", connects: "server" },
	],
};

describe("the model picker", () => {
	it("offers the models of the providers that hold a credential, and of the servers that listed theirs, the newest first, those the search names", () => {
		expect(modelChoices(DIRECTORY, "")).toEqual([
			{
				provider: "openrouter",
				models: [
					{ reference: "openrouter/deepseek/deepseek-v4.1-flash", name: "DeepSeek: DeepSeek V4.1 Flash", context: "1M" },
					{ reference: "openrouter/z/old", name: "Z: Old" },
				],
			},
			{ provider: "ollama", models: [{ reference: "ollama/qwen4:8b", name: "qwen4:8b" }] },
		]);
		expect(modelChoices(DIRECTORY, "flash").flatMap((group) => group.models.map((each) => each.reference))).toEqual([
			"openrouter/deepseek/deepseek-v4.1-flash",
		]);
	});

	it("puts the starred and the recent models first, each once, with nothing searched", () => {
		const sections = modelSections({
			directory: DIRECTORY,
			search: "",
			favorites: ["openrouter/z/old"],
			recent: ["openrouter/z/old", "openrouter/deepseek/deepseek-v4.1-flash"],
		});
		expect(sections.map((section) => [section.title, section.models.map((each) => each.reference)])).toEqual([
			["Favorites", ["openrouter/z/old"]],
			["Recent", ["openrouter/deepseek/deepseek-v4.1-flash"]],
			["OpenRouter", ["openrouter/deepseek/deepseek-v4.1-flash", "openrouter/z/old"]],
			["Ollama", ["ollama/qwen4:8b"]],
		]);
	});

	it("names a model without its maker, and a provider by the node's name", () => {
		expect(modelLabel("openrouter/deepseek/deepseek-v4.1-flash", DIRECTORY)).toBe("DeepSeek V4.1 Flash");
		expect(modelLabel("openai/gpt-x", DIRECTORY)).toBe("gpt-x");
		expect(providerName(DIRECTORY, "anthropic")).toBe("Anthropic");
		expect(providerName(undefined, "anthropic")).toBe("anthropic");
	});

	it("takes the recent models from the newest threads, each once, and stars a model or no longer", () => {
		const row = (id: string, chosen?: string): Listed => ({
			id,
			manifest: { mode: "auto", ...(chosen === undefined ? {} : { model: chosen }) },
			standing: { status: "replied", inbox: [], asks: [], compacting: false },
		});
		expect(recentModelsOf([row("3", "b"), row("2"), row("1", "a"), row("0", "b")])).toEqual(["b", "a"]);
		expect(toggledFavorite(["a"], "b")).toEqual(["a", "b"]);
		expect(toggledFavorite(["a", "b"], "a")).toEqual(["b"]);
	});
});

describe("a model's efforts", () => {
	const plain = model("openrouter", "z/old", "Z: Old", "2025-01-01");
	it("are those it lists, highest first; high, medium and low where it lists none; none where it does not reason", () => {
		expect(effortsOf({ ...plain, reasoning: { supported_efforts: ["low", "high", "xhigh"] } })).toEqual(["xhigh", "high", "low"]);
		expect(effortsOf({ ...plain, supported_parameters: ["reasoning"] })).toEqual(["high", "medium", "low", "none"]);
		expect(effortsOf({ ...plain, reasoning: { mandatory: true } })).toEqual(["high", "medium", "low"]);
		expect(effortsOf(plain)).toEqual([]);
		expect(effortsOf(undefined)).toEqual([]);
	});

	it("are stepped through from the highest again after the lowest, and read as words", () => {
		expect(nextEffort(["high", "medium", "low"], "medium")).toBe("low");
		expect(nextEffort(["high", "medium", "low"], "low")).toBe("high");
		expect(nextEffort(["high", "medium", "low"], undefined)).toBe("high");
		expect(nextEffort([], "high")).toBeUndefined();
		expect(effortLabel("xhigh")).toBe("Extra high");
		expect(modelOf(DIRECTORY, "anthropic/claude-opus-5-5")?.name).toBe("Claude Opus 5.5");
	});
});
