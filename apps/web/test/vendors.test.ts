/** Whose mark a model or a provider is drawn with: its maker's, the service it is, or none the page knows. */
import { describe, expect, it } from "bun:test";
import type { Provider } from "@octoii-works/octoii-client";
import { vendorOfModel, vendorOfProvider, vendorOfReference } from "../src/core/vendors.ts";

describe("a model's vendor", () => {
	it("is the maker its id leads with, where a service serves many makers' models", () => {
		expect(vendorOfModel("openrouter", "openai/gpt-6.1-terra")).toBe("openai");
		expect(vendorOfModel("openrouter", "anthropic/claude-haiku-5.5")).toBe("claude");
		expect(vendorOfModel("openrouter", "moonshotai/kimi-k3.1-pro")).toBe("kimi");
		expect(vendorOfModel("openrouter", "x-ai/grok-4.7")).toBe("grok");
		expect(vendorOfModel("openrouter", "z-ai/glm-5")).toBe("zai");
	});

	it("is the maker a provider serves alone, whatever its id is called", () => {
		expect(vendorOfModel("claude", "haiku")).toBe("claude");
		expect(vendorOfModel("chatgpt", "gpt-6.1")).toBe("openai");
		expect(vendorOfModel("google", "gemini-4-argon")).toBe("gemini");
	});

	it("is the family its id names, where a server on the person's machine runs it; none for one the page knows nothing of", () => {
		expect(vendorOfModel("ollama", "qwen3-coder:30b")).toBe("qwen");
		expect(vendorOfModel("lmstudio", "llama-4-scout")).toBe("meta");
		expect(vendorOfModel("ollama", "gpt-oss:20b")).toBe("openai");
		expect(vendorOfModel("ollama", "my-own-model")).toBeUndefined();
		expect(vendorOfModel("openrouter", "someone/new-model")).toBeUndefined();
	});

	it("is read through an account the person added, as the provider it is another of", () => {
		const providers: readonly Provider[] = [
			{ id: "claude", name: "Claude", connects: "agent" },
			{ id: "work", name: "Claude · Work", connects: "agent", account: { of: "claude", name: "Work" } },
		];
		expect(vendorOfReference({ models: [], providers }, "work/opus")).toBe("claude");
		expect(vendorOfReference(undefined, "openrouter/deepseek/deepseek-v4.1-flash")).toBe("deepseek");
	});
});

describe("a provider's vendor", () => {
	it("is the service it is, or the one an account is another of; none for one the page has no mark for", () => {
		expect(vendorOfProvider({ id: "openrouter", name: "OpenRouter", connects: "api_key" })).toBe("openrouter");
		expect(vendorOfProvider({ id: "work", name: "Claude · Work", connects: "agent", account: { of: "claude", name: "Work" } })).toBe("claude");
		expect(vendorOfProvider({ id: "deepgram", name: "Deepgram", connects: "api_key" })).toBeUndefined();
	});
});
