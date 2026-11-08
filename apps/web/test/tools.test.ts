/**
 * What the page knows of each tool: its kind of work and its verbs as a call stands, what it works on and whether that
 * is code, what its line says beside that and at its end, what opens under it by its shape — a tool it knows nothing
 * of named as it is — and a stretch of calls summed up as a person says it.
 */
import { describe, expect, it } from "bun:test";
import type { CallState } from "../src/core/calls.ts";
import { callWords, detailOf, summaryOf, toolOf, verbOf } from "../src/core/tools.ts";

/** A call of `tool` with `given`, standing as `state`, its tool having told `output`. */
const called = (tool: string, given: object, state: CallState = "done", output?: string, printed?: string) => ({
	tool,
	arguments: JSON.stringify(given),
	output,
	printed,
	state,
});

describe("what the page knows of each tool", () => {
	it("says a call by its verb as it stands and what it works on, a tool it knows nothing of by its name", () => {
		expect(callWords(called("read", { path: "a.md" }))).toBe("Read a.md");
		expect(callWords(called("shell", { command: "ls" }, "waiting"))).toBe("Running ls");
		expect(callWords(called("write", { path: "a.md" }, "rejected"))).toBe("Write a.md");
		expect(callWords(called("grep", { pattern: "TODO" }))).toBe("Searched for TODO");
		expect(callWords(called("execute", { code: "return 1" }))).toBe("Ran a script");
		expect(callWords(called("question", { questions: [{ header: "Stack" }, { header: "Checks" }] }))).toBe("Asked about Stack, Checks");
		expect(callWords(called("delegate", { title: "Docs" }, "running"))).toBe("Delegating Docs");
		expect(callWords(called("browser_navigate", { url: "https://example.com" }))).toBe("Opened https://example.com");
		expect(callWords(called("github.create_issue", { title: "x" }))).toBe("github.create_issue");
		expect(verbOf({ tool: "github.create_issue", state: "done" })).toBeUndefined();
		expect([toolOf("shell").code, toolOf("read").code, toolOf("github.create_issue").work]).toEqual([true, false, "other"]);
	});

	it("says beside a call what came of it, and at its end how a command went wrong though it ran", () => {
		const read = called("read", { path: "a.md" }, "done", "…\n[lines 1-200; more from offset 201]");
		expect(toolOf("read").aside(read)).toEqual({ kind: "words", text: "lines 1–200" });
		expect(toolOf("grep").aside(called("grep", { pattern: "x" }, "done", "[no match]"))).toEqual({ kind: "words", text: "no match" });
		expect(toolOf("glob").aside(called("glob", { pattern: "*" }, "done", "a\nb"))).toEqual({ kind: "words", text: "2 files" });
		expect(toolOf("edit").aside(called("edit", {}, "done", "@@ -1 +1 @@\n-a\n+b"))).toEqual({ kind: "change", added: 1, removed: 1 });
		expect(toolOf("shell").trouble(called("shell", {}, "done", "oops\n[exit 2]"))).toBe("exit 2");
		expect(toolOf("shell").trouble(called("shell", {}, "done", "fine\n[exit 0]"))).toBeUndefined();
	});

	it("opens a call by its tool's shape, and one that did not go through as what it was given and told", () => {
		expect(detailOf(called("shell", { command: "zig build" }, "done", "built\n[exit 0]"))).toEqual({
			shape: "command",
			command: "zig build",
			told: { text: "built", notes: ["exit 0"] },
		});
		expect(detailOf(called("edit", { path: "a.md" }, "done", "--- a.md\n+++ a.md\n@@ -1 +1 @@\n-a\n+b"))).toEqual({
			shape: "diff",
			hunks: "@@ -1 +1 @@\n-a\n+b",
			notes: [],
		});
		expect(detailOf(called("write", { path: "b.md", content: "hello" }, "done", "created b.md +1"))).toMatchObject({
			shape: "file",
			path: "b.md",
			told: { text: "hello" },
		});
		expect(detailOf(called("execute", { code: "return 1" }, "running"))).toEqual({ shape: "script", code: "return 1", told: undefined });
		// A command that runs shows what it has printed so far.
		expect(detailOf(called("shell", { command: "zig build" }, "running", undefined, "compiling\n"))).toEqual({
			shape: "command",
			command: "zig build",
			told: { text: "compiling\n", notes: [] },
		});
		expect(detailOf(called("edit", { path: "a.md" }, "failed", "not-found"))).toMatchObject({
			shape: "fields",
			fields: [{ name: "path", value: "a.md" }],
			told: { text: "not-found" },
		});
		expect(detailOf(called("github.create_issue", { title: "x" }, "done", "#12"))).toMatchObject({ shape: "fields", fields: [{ name: "title", value: "x" }] });
	});

	it("sums up a stretch of calls by the first two kinds of work it did, as they go where one runs, and how many more", () => {
		const call = (work: "read" | "command" | "search" | "edit", state: CallState = "done") => ({ work, state });
		expect(summaryOf([call("read"), call("read"), call("read"), call("command")])).toBe("read 3 files and ran 1 command");
		expect(summaryOf([call("read"), call("command", "running")])).toBe("read 1 file and running 1 command");
		expect(summaryOf([call("read"), call("search"), call("edit"), call("edit")])).toBe("read 1 file, searched 1 time and 2 more");
	});
});
