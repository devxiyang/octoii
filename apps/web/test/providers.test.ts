/** The providers as settings show them: those in use, how each stands, and the catalogue one is added from. */
import { describe, expect, it } from "bun:test";
import type { Provider, ProviderStatus } from "@octoii-works/octoii-client";
import { catalogueOf, inUseOf, standingAsked, standingOf, standingShortOf, takesAccounts } from "../src/core/providers.ts";

const PROVIDERS: readonly Provider[] = [
	{ id: "anthropic", name: "Anthropic", connects: "api_key" },
	{ id: "claude", name: "Claude", connects: "agent", through: "Claude Code" },
	{ id: "chatgpt", name: "ChatGPT", connects: "sign_in", credential: "oauth" },
	{ id: "openrouter", name: "OpenRouter", connects: "api_key", credential: "api_key" },
	{ id: "ollama", name: "Ollama", connects: "server" },
	{ id: "work", name: "Claude · Work", connects: "agent", through: "Claude Code", account: { of: "claude", name: "Work" } },
];

const answering: ProviderStatus = { connected: true };
const PROBLEM = "Claude Code is not signed in: run `claude` in a terminal.";
const silent: ProviderStatus = { connected: false, problem: PROBLEM };

describe("the providers in use", () => {
	it("are those holding a key or a sign-in, accounts the person added, and agents and servers that answer, each account after its provider", () => {
		const statuses = new Map([
			["claude", answering],
			["ollama", { connected: false }],
			["work", silent],
		]);
		expect(inUseOf(PROVIDERS, statuses).map((each) => each.id)).toEqual(["claude", "work", "chatgpt", "openrouter"]);
		// An account whose provider is not in use stands at the end, still in use.
		expect(inUseOf(PROVIDERS, new Map()).map((each) => each.id)).toEqual(["chatgpt", "openrouter", "work"]);
	});

	it("are asked how they stand where it tells anything: what holds something, and agents and servers", () => {
		expect(PROVIDERS.filter(standingAsked).map((each) => each.id)).toEqual(["claude", "chatgpt", "openrouter", "ollama", "work"]);
	});
});

describe("how a provider stands", () => {
	it("is who it is connected as, or what is wrong in the node's words, its details told in full and its line in a few words", () => {
		const claude = PROVIDERS[1];
		if (claude === undefined) throw new Error("no Claude");
		expect(standingOf(claude, undefined)).toBe("Checking…");
		expect(standingOf(claude, { connected: true, account: "me@example.com" })).toBe("me@example.com");
		expect(standingOf(claude, answering)).toBe("Signed in");
		expect(standingOf(claude, silent)).toBe(PROBLEM);
		expect(standingShortOf(claude, silent)).toBe("Not signed in");
	});
});

describe("the catalogue", () => {
	it("groups the node's own providers by how each connects, no account among them, and takes accounts of any but a server", () => {
		expect(catalogueOf(PROVIDERS).map((group) => [group.title, group.providers.map((each) => each.id)])).toEqual([
			["Sign in", ["claude", "chatgpt"]],
			["API key", ["anthropic", "openrouter"]],
			["On this computer", ["ollama"]],
		]);
		expect(PROVIDERS.filter(takesAccounts).map((each) => each.id)).toEqual(["anthropic", "claude", "chatgpt", "openrouter"]);
	});
});
