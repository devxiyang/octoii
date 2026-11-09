/**
 * A call as its tool told it, read: its text and the notes after it, how a command exited, what an edit or a write
 * changed and an edit's diff, the lines a read held, what a search found, and its arguments as fields.
 */
import { describe, expect, it } from "bun:test";
import { changeOf, exitOf, fieldsOf, foundOf, hunksOf, prettyArguments, printedOf, spanOf, type ToolCall, toldOf } from "../src/core/calls.ts";

/** A call of `tool` that ran, its tool having told `output`. */
const ran = (tool: string, output: string): ToolCall => ({ tool, arguments: "{}", output, printed: undefined, state: "done" });

describe("a call as its tool told it", () => {
	it("tells a tool's text from the notes after it, a line each in brackets, the text left as it is", () => {
		expect(toldOf("a\n[b] c\n[exit 1]\n[timed out after 5 s; killed]")).toEqual({ text: "a\n[b] c", notes: ["exit 1", "timed out after 5 s; killed"] });
		expect(toldOf("[no match]")).toEqual({ text: "", notes: ["no match"] });
		expect(toldOf("plain\n")).toEqual({ text: "plain\n", notes: [] });
	});

	it("reads how a command exited: its code, a signal, or its time running out; nothing while it runs", () => {
		expect(exitOf(ran("shell", "built\n[exit 0]"))).toEqual({ kind: "code", code: 0 });
		expect(exitOf(ran("shell", "[signal 9]"))).toEqual({ kind: "signal", signal: 9 });
		expect(exitOf(ran("shell", "…\n[timed out after 120 s; killed]"))).toEqual({ kind: "timed-out" });
		expect(exitOf({ ...ran("shell", ""), output: undefined, state: "running" })).toBeUndefined();
	});

	it("counts what an edit changed from its diff — a removed line of dashes still removed — and reads a write's words", () => {
		const diff = "--- a.sql\n+++ a.sql\n@@ -1,3 +1,2 @@\n--- an old comment\n-select 1;\n+select 2;\n kept";
		expect(changeOf(ran("edit", `${diff}\n[tier fuzzy]`))).toEqual({ added: 1, removed: 2 });
		expect(hunksOf(ran("edit", diff))).toBe("@@ -1,3 +1,2 @@\n--- an old comment\n-select 1;\n+select 2;\n kept");
		expect(changeOf(ran("write", "created b.md +12"))).toEqual({ added: 12, removed: 0 });
		expect(changeOf(ran("write", "wrote b.md +3 -9"))).toEqual({ added: 3, removed: 9 });
		expect(changeOf({ ...ran("edit", "not-found"), state: "failed" })).toBeUndefined();
	});

	it("reads the lines a read held, and what a glob and a grep found", () => {
		expect(spanOf(ran("read", "…\n[lines 1-200; more from offset 201]"))).toBe("lines 1–200");
		expect(spanOf(ran("read", "whole"))).toBeUndefined();
		expect(foundOf(ran("glob", "src/a.ts\nsrc/b.ts"))).toEqual([
			{ path: "src/a.ts", line: undefined, text: undefined },
			{ path: "src/b.ts", line: undefined, text: undefined },
		]);
		expect(foundOf(ran("grep", "src/a.ts:3: let x\nsrc/a.ts:4- context\n[more matches than shown]"))).toEqual([{ path: "src/a.ts", line: 3, text: "let x" }]);
	});

	it("gives arguments as their fields, a value not a string as JSON, and as they were laid out where they are no object", () => {
		expect(fieldsOf('{"query":"bugs","limit":5,"open":true}')).toEqual([
			{ name: "query", value: "bugs" },
			{ name: "limit", value: "5" },
			{ name: "open", value: "true" },
		]);
		expect(fieldsOf("[1,2]")).toBeUndefined();
		expect(fieldsOf("{not json")).toBeUndefined();
		expect(prettyArguments('{"path":"a.md","limit":2}')).toBe('{\n  "path": "a.md",\n  "limit": 2\n}');
		expect(prettyArguments("{not json")).toBe("{not json");
	});
	it("reads what a running command printed from what streamed of its tool's request — its latest part", () => {
		expect(printedOf([{ text: "one\n" }, { other: true }, { text: "two" }])).toBe("one\ntwo");
		expect(printedOf([])).toBeUndefined();
		const long = printedOf([{ text: "x".repeat(70_000) }, { text: "end" }]) ?? "";
		expect([long.length, long.endsWith("xend")]).toEqual([64 * 1024, true]);
	});
});
