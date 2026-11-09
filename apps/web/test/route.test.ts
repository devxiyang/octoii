import { describe, expect, it } from "bun:test";
import { HOME, type Route, routeAddress, routeOf, settingsOf, withOverlay, withSettings } from "../src/core/route.ts";
import { isSignInReturn } from "../src/core/sign-in.ts";

describe("a route's address", () => {
	const places: readonly Route[] = [
		HOME,
		{ place: "new", project: "/work/octoii" },
		{ place: "thread", thread: "0199f0c2-7a10-7000-8000-000000000001" },
		{ place: "thread", thread: "t1", over: { kind: "settings", section: "providers" } },
		{ ...HOME, over: { kind: "settings", section: "general" } },
	];

	it("reads back as the place it names, each name encoded", () => {
		for (const place of places) expect(routeOf(routeAddress(place))).toEqual(place);
		expect(routeAddress({ place: "new", project: "/work/octoii" })).toBe("#/new/%2Fwork%2Foctoii");
		expect(routeAddress({ place: "thread", thread: "t1", over: { kind: "settings", section: "chat" } })).toBe("#/thread/t1?settings=chat");
	});

	it("is home, a new thread in the last project's folder, at the root", () => {
		expect(HOME).toEqual({ place: "new" });
		expect(routeAddress(HOME)).toBe("#/");
		expect(routeAddress({ ...HOME, over: { kind: "settings", section: "general" } })).toBe("#/?settings=general");
		expect(routeOf("#/new")).toEqual(HOME);
	});

	it("leads home from an address it cannot read, and opens no settings for a section it does not know", () => {
		expect(routeOf("#/somewhere/else")).toEqual(HOME);
		expect(routeOf("")).toEqual(HOME);
		expect(routeOf("#/thread/t1?settings=nowhere")).toEqual({ place: "thread", thread: "t1" });
	});

	it("opens settings over a place and closes them, the place kept", () => {
		const thread: Route = { place: "thread", thread: "t1" };
		expect(withSettings(thread, "appearance")).toEqual({ place: "thread", thread: "t1", over: { kind: "settings", section: "appearance" } });
		expect(settingsOf(withSettings(thread, "appearance"))).toBe("appearance");
		expect(withOverlay(withSettings(thread, "appearance"), undefined)).toEqual(thread);
	});
});

describe("a sign-in's return", () => {
	it("is the node's address with what the issuer gave it, pasted or opened", () => {
		expect(isSignInReturn("http://127.0.0.1:7600/auth/callback?code=c&state=s")).toBe(true);
		expect(isSignInReturn("  http://127.0.0.1:7600/auth/callback?code=c  ")).toBe(true);
		expect(isSignInReturn("http://127.0.0.1:7600/auth/callback")).toBe(false);
		expect(isSignInReturn("http://127.0.0.1:7600/pair#token=x")).toBe(false);
		expect(isSignInReturn("not an address")).toBe(false);
	});
});
