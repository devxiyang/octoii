/** What waits on the person, read from each request's name, what it was made with, and its answer's schema. */
import { describe, expect, it } from "bun:test";
import type { Ask } from "@octoii-works/octoii-client";
import {
	alwaysText,
	askTitle,
	type Choice,
	choiceAnswer,
	choose,
	fieldsAnswer,
	formOf,
	missingField,
	permissionDetail,
	permissionTitle,
	type Question,
	questionsAnswer,
	shownPath,
	UNANSWERED,
	write,
} from "../src/core/asks.ts";

const ask = (name: string, answer: unknown, payload?: unknown): Ask => ({
	fiber: "f1",
	call: undefined,
	request: { key: "a1", name, answer, ...(payload === undefined ? {} : { payload }) },
});

/** The answer Siphon's trust request takes. */
const TRUSTED = { type: "object", properties: { trusted: { type: "boolean" } }, required: ["trusted"] };

describe("what a request asks", () => {
	it("asks trust in a folder's configuration with the servers it would run", () => {
		const trust = ask("trust", TRUSTED, {
			folder: "/w/app",
			path: "/w/app/.mcp.json",
			digest: "d",
			servers: [{ name: "docs", command: "node", args: ["s.js"] }],
		});
		expect(formOf(trust)).toEqual({ kind: "trust", folder: "/w/app", servers: [{ name: "docs", command: "node", args: ["s.js"] }] });
		expect(askTitle(trust)).toBe("Trust what app runs?");
	});

	it("is told in a line by what it asks: a permission's title, a question's heading, else the request's name", () => {
		const access = { action: "command" as const, resources: ["ls"], save: [] };
		expect(askTitle(ask("permission", { type: "object" }, { tool: "shell", arguments: { command: "ls" }, access }))).toBe("Run this command?");
		expect(askTitle(ask("question", { type: "object" }, { questions: [{ question: "Which one?", header: "Target" }] }))).toBe("Target");
		expect(askTitle(ask("decide", { type: "object", properties: { note: { type: "string" } } }))).toBe("decide");
	});

	it("asks a union of objects, each named by one constant, as a choice of them with the fields each takes", () => {
		const form = formOf(
			ask("decide", {
				anyOf: [
					{ type: "object", properties: { decision: { const: "once" } } },
					{ type: "object", properties: { decision: { const: "not_now" }, reason: { type: "string", title: "Why" } }, required: ["reason"] },
				],
			}),
		);
		expect(form).toMatchObject({
			kind: "choices",
			key: "decision",
			choices: [
				{ value: "once", label: "Once", fields: [] },
				{ value: "not_now", label: "Not now", fields: [{ path: ["reason"], label: "Why", required: true, takes: { kind: "text" } }] },
			],
		});
		const choice: Choice | undefined = form.kind === "choices" ? form.choices[1] : undefined;
		if (choice === undefined) throw new Error("no second choice");
		expect(missingField(choice.fields, {})).toBe(true);
		expect(choiceAnswer("decision", choice, { reason: "  later " })).toEqual({ decision: "not_now", reason: "later" });
	});

	it("asks an object's own fields, one level of nesting, and shows what it cannot ask", () => {
		const form = formOf(
			ask("contact", {
				type: "object",
				properties: { trusted: { type: "boolean" }, size: { enum: ["s", "m"] }, content: { type: "object", properties: { email: { type: "string" } } } },
			}),
		);
		expect(form).toMatchObject({
			kind: "fields",
			fields: [
				{ path: ["trusted"], takes: { kind: "boolean" } },
				{ path: ["size"], takes: { kind: "one", values: ["s", "m"] } },
				{ path: ["content", "email"], takes: { kind: "text" } },
			],
		});
		if (form.kind !== "fields") throw new Error("not fields");
		expect(fieldsAnswer(form.fields, { trusted: false, "content.email": "a@b.c" })).toEqual({ trusted: false, content: { email: "a@b.c" } });
		expect(formOf(ask("odd", { type: "string" }))).toEqual({ kind: "shown" });
		expect(formOf(ask("trust", TRUSTED, { not: "a folder" }))).toMatchObject({ kind: "fields" });
	});
});

describe("a call's permission", () => {
	const command = { action: "command" as const, resources: ["npm install lodash"], save: ["npm install *"] };

	it("is asked with what the call does, and what an always grants", () => {
		const form = formOf(ask("permission", { type: "object" }, { tool: "shell", arguments: { command: "npm install lodash" }, access: command }));
		expect(form).toEqual({ kind: "permission", tool: "shell", arguments: { command: "npm install lodash" }, access: command, doubt: undefined });
		// Asked after the model that judged it would not let it go ahead, it says why.
		const doubted = formOf(ask("permission", { type: "object" }, { tool: "shell", arguments: {}, access: command, doubt: "it installs a package" }));
		expect(doubted).toMatchObject({ kind: "permission", doubt: "it installs a package" });
		expect(permissionTitle("shell", command)).toBe("Run this command?");
		expect(permissionTitle("shell", { ...command, escalate: true })).toBe("Run this beyond the sandbox?");
		expect(alwaysText(command, "/w/app")).toBe("Always allow npm install * in app");
		// A thread of no project has nothing to grant always.
		expect(alwaysText(command, undefined)).toBeUndefined();
		expect(alwaysText({ ...command, resources: [], save: [] }, "/w/app")).toBeUndefined();
	});

	it("shows an edit's file, then what it takes out and puts in, each line numbered", () => {
		const edit = { action: "edit" as const, resources: ["/w/app/a.zig"], save: ["*"] };
		expect(permissionDetail("edit", { path: "a.zig", old: "one", new: "two\nthree" }, edit, "/w/app")).toEqual([
			{ number: 0, kind: "text", text: "a.zig" },
			{ number: 1, kind: "removed", text: "one" },
			{ number: 2, kind: "added", text: "two" },
			{ number: 3, kind: "added", text: "three" },
		]);
		expect(permissionDetail("write", { path: "a.zig", content: "x\n" }, edit, undefined)).toMatchObject([
			{ text: "/w/app/a.zig" },
			{ kind: "added", text: "x" },
		]);
		expect(shownPath("/w/application/b.zig", "/w/app")).toBe("/w/application/b.zig");
		expect(shownPath("/w/app", "/w/app")).toBe(".");
		expect(permissionTitle("write", edit)).toBe("Write this file?");
		expect(alwaysText(edit, "/w/app")).toBe("Allow every edit in app");
	});
});

describe("a model's questions", () => {
	const single: Question = { question: "Which stack?", header: "Stack", options: [{ label: "Bun" }, { label: "Node" }] };
	const multiple: Question = { question: "Which checks?", header: "Checks", options: [{ label: "lint" }, { label: "test" }], multiple: true };

	it("are asked one by one from the request's questions", () => {
		expect(formOf(ask("question", { type: "object" }, { questions: [single, multiple] }))).toEqual({ kind: "question", questions: [single, multiple] });
	});

	it("take one choice or the person's own words for a question of one, several and words of their own for one of several", () => {
		const bun = choose(single, UNANSWERED, "Bun");
		expect(choose(single, bun, "Node").chosen).toEqual(["Node"]);
		expect(choose(single, bun, "Bun").chosen).toEqual([]);
		expect(write(single, bun, "Deno")).toEqual({ chosen: [], own: "Deno" });
		const both = choose(multiple, choose(multiple, UNANSWERED, "lint"), "test");
		expect(write(multiple, both, " e2e ")).toEqual({ chosen: ["lint", "test"], own: " e2e " });
		expect(questionsAnswer([bun, write(multiple, both, " e2e "), UNANSWERED])).toEqual({ answers: [["Bun"], ["lint", "test", "e2e"], []] });
	});
});
