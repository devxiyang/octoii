/** Where a conversation stands in a session: its prefixes known by what they say, and kept across starts. */
import { describe, expect, it } from "bun:test";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Message } from "../src/anthropic.ts";
import { chainOf, Positions, rootOf } from "../src/positions.ts";

const asked: Message = { role: "user", content: "Read the build file" };
const answered = (input: object): Message => ({
	role: "assistant",
	content: [
		{ type: "thinking", thinking: "the build file is build.zig", signature: "sig-a" },
		{ type: "text", text: "Reading " },
		{ type: "text", text: "it." },
		{ type: "tool_use", id: "toolu_1", name: "read", input },
	],
});

describe("a conversation's prefixes", () => {
	it("are known by what is said and called, however the client writes it back", () => {
		const first = chainOf("system", [asked, answered({ path: "build.zig", limit: 10 })]);
		// Thinking is the model's own, signed for it; texts side by side are one; an input's keys come in any order.
		const back = chainOf("system", [
			{ role: "user", content: [{ type: "text", text: "Read the build file" }] },
			{
				role: "assistant",
				content: [
					{ type: "text", text: "Reading it." },
					{ type: "tool_use", id: "toolu_1", name: "read", input: { limit: 10, path: "build.zig" } },
				],
			},
		]);
		expect(back).toEqual(first);
		expect(chainOf("system", [asked])[0]).toBe(first[0]);
		// What was called, and the system the conversation is under, tell one conversation from another.
		expect(chainOf("system", [asked, answered({ path: "build.zon" })])[1]).not.toBe(first[1]);
		expect(chainOf("another system", [asked])[0]).not.toBe(first[0]);
		expect(rootOf("system")).not.toBe(rootOf("another system"));
	});
});

describe("positions", () => {
	it("are kept in a file of lines, read again as the gateway starts, a line not whole passed over", async () => {
		const path = join(await mkdtemp(join(tmpdir(), "positions-")), "claude", "positions.jsonl");
		const positions = await Positions.open(path);
		await positions.set("a", { session: "s1", entry: "e1" });
		await positions.set("b", { session: "s1", entry: "e2" });
		await positions.set("a", { session: "s2", entry: "e3" });
		await writeFile(path, `${await readFile(path, "utf8")}{"hash":"c","sess`);
		const again = await Positions.open(path);
		expect(again.get("a")).toEqual({ session: "s2", entry: "e3" });
		expect(again.get("b")).toEqual({ session: "s1", entry: "e2" });
		expect(again.get("c")).toBeUndefined();
		// A session's tip is where it was last written to, read again from the file's last line of it.
		expect(again.isTip("a")).toBe(true);
		expect(again.isTip("b")).toBe(true);
		await again.set("d", { session: "s1", entry: "e4" });
		expect(again.isTip("b")).toBe(false);
		expect((await Positions.open(path)).isTip("d")).toBe(true);
		// Kept in memory alone where no file is named.
		const fleeting = await Positions.open(undefined);
		await fleeting.set("a", { session: "s", entry: "e" });
		expect(fleeting.get("a")).toEqual({ session: "s", entry: "e" });
	});
});
