/**
 * What the page knows of each of Siphon's tools, one entry each: the kind of work it does — its mark, and the words a
 * stretch of calls sums it up in — its verbs as it is asked, as it goes and as it went; what it works on, read from its
 * arguments, and whether that is code; what its line says beside that, and at its end where it went wrong though it
 * ran; and what opens under its line, by its shape. A tool it knows nothing of — a server's, `server.tool` — is named as
 * it is, its arguments shown as their fields; and a call that did not go through is shown as what it was given and
 * what it was told, whatever its tool.
 */
import { matches } from "@octoii-works/octoii-client";
import { type Static, Type } from "typebox";
import {
	type CallState,
	changeOf,
	commandToldOf,
	exitOf,
	type Field,
	fieldsOf,
	type Found,
	foundOf,
	hunksOf,
	spanOf,
	type ToolCall,
	type Told,
	toldOf,
} from "./calls.ts";

/** The kind of work a call does, by its tool: its mark, and how a stretch of calls says it. */
export type WorkKind = "read" | "edit" | "search" | "command" | "script" | "browse" | "ask" | "delegate" | "other";

/** What a call's line says beside what it works on: quiet words — the lines a read held, how many a search found, what a script's calls did — or the lines an edit or a write added and took out. */
export type Aside = { readonly kind: "words"; readonly text: string } | { readonly kind: "change"; readonly added: number; readonly removed: number };

/**
 * What opens under a call's line, by its shape: a command and what it printed; an edit's diff; a file's text, as read or
 * as written; the places a search found; a script's code and what it told; or its arguments' fields and what its tool
 * told.
 */
export type Detail =
	| { readonly shape: "command"; readonly command: string; readonly told: Told | undefined }
	| { readonly shape: "diff"; readonly hunks: string; readonly notes: readonly string[] }
	| { readonly shape: "file"; readonly path: string | undefined; readonly told: Told | undefined }
	| { readonly shape: "found"; readonly found: readonly Found[]; readonly notes: readonly string[] }
	| { readonly shape: "script"; readonly code: string; readonly told: Told | undefined }
	| { readonly shape: "fields"; readonly fields: readonly Field[] | undefined; readonly arguments: string; readonly told: Told | undefined };

const GivenSchema = Type.Object({
	path: Type.Optional(Type.String()),
	pattern: Type.Optional(Type.String()),
	command: Type.Optional(Type.String()),
	code: Type.Optional(Type.String()),
	content: Type.Optional(Type.String()),
	questions: Type.Optional(Type.Array(Type.Object({ header: Type.String() }))),
	title: Type.Optional(Type.String()),
	task: Type.Optional(Type.String()),
	thread: Type.Optional(Type.String()),
	url: Type.Optional(Type.String()),
	go: Type.Optional(Type.String()),
	action: Type.Optional(Type.String()),
	expression: Type.Optional(Type.String()),
	text: Type.Optional(Type.String()),
});

/** A call's arguments as far as the page reads them. */
export type Given = Static<typeof GivenSchema>;

/** The arguments `text` gives, as far as the page reads them; none of them where their JSON does not parse, as a model's may not. */
export function givenOf(text: string): Given {
	try {
		const value: unknown = JSON.parse(text);
		return matches(GivenSchema, value) ? value : {};
	} catch {
		return {};
	}
}

/** A tool's verbs: as it is asked, as it goes, and as it went — "Write", "Writing", "Wrote". */
type Verbs = readonly [asked: string, going: string, went: string];

/** What the page knows of a tool. */
type ToolView = {
	readonly work: WorkKind;
	/** None for a tool the page has no words for, which its line names. */
	readonly verbs: Verbs | undefined;
	readonly subject: (given: Given) => string | undefined;
	/** Whether what it works on is code — a command, a pattern, an expression — as its line sets it. */
	readonly code: boolean;
	readonly aside: (call: ToolCall) => Aside | undefined;
	/** How it went wrong though its tool did it, as its line ends: a command's exit. */
	readonly trouble: (call: ToolCall) => string | undefined;
	readonly detail: (call: ToolCall, given: Given) => Detail;
};

/** A tool's view, what it leaves out as a tool says nothing of it: no subject, words, nothing beside or at its end, its arguments' fields under it. */
function toolView(view: Pick<ToolView, "work" | "verbs"> & Partial<ToolView>): ToolView {
	return { subject: () => undefined, code: false, aside: () => undefined, trouble: () => undefined, detail: fieldsDetail, ...view };
}

/** What each of Siphon's own tools is. */
const TOOLS: Readonly<Partial<Record<string, ToolView>>> = {
	read: toolView({
		work: "read",
		verbs: ["Read", "Reading", "Read"],
		subject: (given) => given.path,
		aside: (call) => wordsAside(spanOf(call)),
		detail: (call, given) => ({ shape: "file", path: given.path, told: toldOfCall(call) }),
	}),
	write: toolView({
		work: "edit",
		verbs: ["Write", "Writing", "Wrote"],
		subject: (given) => given.path,
		aside: changeAside,
		detail: (_, given) => ({ shape: "file", path: given.path, told: { text: given.content ?? "", notes: [] } }),
	}),
	edit: toolView({
		work: "edit",
		verbs: ["Edit", "Editing", "Edited"],
		subject: (given) => given.path,
		aside: changeAside,
		detail: (call) => ({ shape: "diff", hunks: hunksOf(call) ?? "", notes: toldOfCall(call)?.notes ?? [] }),
	}),
	glob: toolView({
		work: "search",
		verbs: ["Find files matching", "Finding files matching", "Found files matching"],
		subject: (given) => given.pattern,
		code: true,
		aside: (call) => foundAside(call, "file", "files"),
		detail: foundDetail,
	}),
	grep: toolView({
		work: "search",
		verbs: ["Search for", "Searching for", "Searched for"],
		subject: (given) => given.pattern,
		code: true,
		aside: (call) => foundAside(call, "match", "matches"),
		detail: foundDetail,
	}),
	shell: toolView({
		work: "command",
		verbs: ["Run", "Running", "Ran"],
		subject: (given) => given.command,
		code: true,
		trouble: exitTrouble,
		detail: (call, given) => ({
			shape: "command",
			command: given.command ?? "",
			told: call.output === undefined ? printedOfCall(call) : commandToldOf(call.output),
		}),
	}),
	execute: toolView({
		work: "script",
		verbs: ["Run a script", "Running a script", "Ran a script"],
		detail: (call, given) => ({ shape: "script", code: given.code ?? "", told: toldOfCall(call) }),
	}),
	question: toolView({
		work: "ask",
		verbs: ["Ask about", "Asking about", "Asked about"],
		subject: (given) => given.questions?.map((question) => question.header).join(", "),
	}),
	delegate: toolView({ work: "delegate", verbs: ["Delegate", "Delegating", "Delegated"], subject: (given) => given.title ?? given.task?.split("\n")[0] }),
	browser_navigate: toolView({ work: "browse", verbs: ["Open", "Opening", "Opened"], subject: (given) => given.url ?? given.go }),
	browser_snapshot: toolView({ work: "browse", verbs: ["Read the page", "Reading the page", "Read the page"] }),
	browser_act: toolView({
		work: "browse",
		verbs: ["Act on the page", "Acting on the page", "Acted on the page"],
		subject: (given) => given.action,
		code: true,
	}),
	browser_evaluate: toolView({
		work: "browse",
		verbs: ["Run in the page", "Running in the page", "Ran in the page"],
		subject: (given) => given.expression,
		code: true,
	}),
	browser_wait: toolView({
		work: "browse",
		verbs: ["Wait for the page", "Waiting for the page", "Waited for the page"],
		subject: (given) => given.text ?? given.url,
	}),
};

/** A tool the page knows nothing of: named as it is, as code. */
const UNKNOWN = toolView({ work: "other", verbs: undefined, code: true });

/** What the page knows of the tool `name`. */
export function toolOf(name: string): ToolView {
	return TOOLS[name] ?? UNKNOWN;
}

/** A call's verb as it stands — as it is asked while it waits on the person or where it never went ahead, as it goes while it runs, as it went once it ran; none for a tool the page has no verb for. */
export function verbOf(call: { readonly tool: string; readonly state: CallState }): string | undefined {
	const verbs = toolOf(call.tool).verbs;
	if (verbs === undefined) return undefined;
	const [asked, going, went] = verbs;
	if (call.state === "running") return going;
	return call.state === "waiting" || call.state === "rejected" || call.state === "stopped" ? asked : went;
}

/** What a call did, or does, in words: its verb and what it works on — "Read a.md" — or, for a tool the page has no verb for, its name. */
export function callWords(call: { readonly tool: string; readonly arguments: string; readonly state: CallState }): string {
	const verb = verbOf(call);
	if (verb === undefined) return call.tool;
	const subject = toolOf(call.tool).subject(givenOf(call.arguments));
	return subject === undefined ? verb : `${verb} ${subject}`;
}

/** What opens under the line of `call`: its tool's shape of it — or, where it did not go through, what it was given and what it was told. */
export function detailOf(call: ToolCall): Detail {
	const given = givenOf(call.arguments);
	if (call.state === "failed" || call.state === "rejected" || call.state === "stopped") return fieldsDetail(call);
	return toolOf(call.tool).detail(call, given);
}

/** What each kind of work did, as a stretch of calls sums it up: as it went once done, and as it goes while one runs. */
const ACTIONS: Readonly<Record<WorkKind, readonly [went: (count: number) => string, going: (count: number) => string]>> = {
	read: [(n) => `read ${counted(n, "file", "files")}`, (n) => `reading ${counted(n, "file", "files")}`],
	edit: [(n) => `edited ${counted(n, "file", "files")}`, (n) => `editing ${counted(n, "file", "files")}`],
	search: [(n) => `searched ${counted(n, "time", "times")}`, (n) => `searching ${counted(n, "time", "times")}`],
	command: [(n) => `ran ${counted(n, "command", "commands")}`, (n) => `running ${counted(n, "command", "commands")}`],
	script: [(n) => `ran ${counted(n, "script", "scripts")}`, (n) => `running ${counted(n, "script", "scripts")}`],
	browse: [(n) => `used the browser ${counted(n, "time", "times")}`, () => "using the browser"],
	ask: [(n) => `asked ${counted(n, "question", "questions")}`, (n) => `asking ${counted(n, "question", "questions")}`],
	delegate: [(n) => `delegated ${counted(n, "task", "tasks")}`, (n) => `delegating ${counted(n, "task", "tasks")}`],
	other: [(n) => `used ${counted(n, "tool", "tools")}`, (n) => `using ${counted(n, "tool", "tools")}`],
};

/**
 * What a stretch of calls did, as a person says it within a sentence: the first two kinds of work it did, in the order
 * it began them — as they go where one of the kind runs — and how many calls more it made; "read 3 files and ran 1
 * command".
 */
export function summaryOf(calls: readonly { readonly work: WorkKind; readonly state: CallState }[]): string {
	const kinds = [...new Set(calls.map((call) => call.work))].slice(0, 2);
	const said = kinds.map((kind) => {
		const ofKind = calls.filter((call) => call.work === kind);
		const [went, going] = ACTIONS[kind];
		return ofKind.some((call) => call.state === "running" || call.state === "waiting") ? going(ofKind.length) : went(ofKind.length);
	});
	const rest = calls.filter((call) => !kinds.includes(call.work)).length;
	return rest === 0 ? said.join(" and ") : `${said.join(", ")} and ${String(rest)} more`;
}

/** `count` of a thing, as one or as many. */
function counted(count: number, one: string, many: string): string {
	return `${String(count)} ${count === 1 ? one : many}`;
}

/** What `call`'s tool told, once it ended. */
function toldOfCall(call: ToolCall): Told | undefined {
	return call.output === undefined ? undefined : toldOf(call.output);
}

/** What `call` has printed so far while it runs, as what its tool told; none where it printed nothing. */
function printedOfCall(call: ToolCall): Told | undefined {
	return call.printed === undefined ? undefined : { text: call.printed, notes: [] };
}

/** `text` as quiet words beside a line's subject; none where there is no text. */
function wordsAside(text: string | undefined): Aside | undefined {
	return text === undefined ? undefined : { kind: "words", text };
}

/** What an edit or a write changed, beside its line's subject. */
function changeAside(call: ToolCall): Aside | undefined {
	const change = changeOf(call);
	return change === undefined ? undefined : { kind: "change", ...change };
}

/** How many places a search found, as its `one` and `many` count them, or that it found none; nothing while it runs. */
function foundAside(call: ToolCall, one: string, many: string): Aside | undefined {
	if (call.state !== "done") return undefined;
	const found = foundOf(call).length;
	return wordsAside(found === 0 ? "no match" : counted(found, one, many));
}

/** How a command went wrong though it ran: exited with a code other than nought, by a signal, or killed as its time ran out. */
function exitTrouble(call: ToolCall): string | undefined {
	const exit = exitOf(call);
	switch (exit?.kind) {
		case "code":
			return exit.code === 0 ? undefined : `exit ${String(exit.code)}`;
		case "signal":
			return `signal ${String(exit.signal)}`;
		case "timed-out":
			return "timed out";
		case undefined:
			return undefined;
	}
}

/** What a search found, and its notes. */
function foundDetail(call: ToolCall): Detail {
	return { shape: "found", found: foundOf(call), notes: toldOfCall(call)?.notes ?? [] };
}

/** A call as the fields of its arguments and what its tool told. */
function fieldsDetail(call: ToolCall): Detail {
	return { shape: "fields", fields: fieldsOf(call.arguments), arguments: call.arguments, told: toldOfCall(call) };
}
