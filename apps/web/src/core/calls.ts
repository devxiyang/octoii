/**
 * A call as its tool told it, read: the text its tool gave, and the notes its tools write after it in brackets — how a
 * command exited, the lines a read held, what an edit or a write added and took out, an edit's diff, what a search
 * found; and the arguments it was given, as fields.
 */
import { matches } from "@octoii-works/octoii-client";
import { Type } from "typebox";
import { diffTones } from "./diff.ts";

/** How a call stands: running, waiting for the person's approval, done, or not done — failed, stopped, or rejected. */
export type CallState = "running" | "waiting" | "done" | "failed" | "stopped" | "rejected";

/**
 * A call as its tool's readers take it: its tool, its arguments as they were written, what its tool told — none before
 * it ended — what it has printed so far while it runs, and how it stands.
 */
export type ToolCall = {
	readonly tool: string;
	readonly arguments: string;
	readonly output: string | undefined;
	readonly printed: string | undefined;
	readonly state: CallState;
};

const PrintedSchema = Type.Object({ text: Type.String() });

/** How much of what a call printed is read, from its end: what a line shows of it, and what opens under it while it runs. */
const PRINTED_MAX = 64 * 1024;

/** What a call's tool printed as it ran, by what streamed of its request — its latest part alone; none where it printed nothing. */
export function printedOf(streamed: readonly unknown[]): string | undefined {
	const parts: string[] = [];
	let length = 0;
	for (let at = streamed.length - 1; at >= 0 && length < PRINTED_MAX; at--) {
		const part = streamed[at];
		if (!matches(PrintedSchema, part)) continue;
		parts.push(part.text);
		length += part.text.length;
	}
	if (parts.length === 0) return undefined;
	const printed = parts.reverse().join("");
	return printed.length > PRINTED_MAX ? printed.slice(printed.length - PRINTED_MAX) : printed;
}

/**
 * The last `count` lines of what a command printed, as a terminal shows them: a carriage return writing the line it
 * ends over from its start, as a progress bar draws itself, and the sequences that colour or move what it shows left
 * out; the lines past its last that hold nothing too.
 */
export function lastLines(printed: string, count: number): readonly string[] {
	const lines = printed
		// oxlint-disable-next-line no-control-regex -- the escape sequences a terminal reads are what this leaves out.
		.replace(/\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]/g, "")
		.split("\n")
		.map((line) => line.split("\r").findLast((part) => part !== "") ?? "");
	while (lines.length > 0 && lines.at(-1)?.trim() === "") lines.pop();
	return lines.slice(-count);
}

/** What a tool told: its text, and the notes after it, each a line in brackets. */
export type Told = { readonly text: string; readonly notes: readonly string[] };

/** `output` as its text and the notes after it, read from its end, the text left as it is. */
export function toldOf(output: string): Told {
	const notes: string[] = [];
	let end = output.length;
	while (end > 0) {
		const start = output.lastIndexOf("\n", end - 1) + 1;
		const note = /^\[(.*)\]$/.exec(output.slice(start, end));
		if (note === null) break;
		notes.unshift(note[1] ?? "");
		end = Math.max(0, start - 1);
	}
	return { text: output.slice(0, end), notes };
}

/** How a command exited: with its code, ended by a signal, or killed as its time ran out. */
export type Exit = { readonly kind: "code"; readonly code: number } | { readonly kind: "signal"; readonly signal: number } | { readonly kind: "timed-out" };

/** How the command `call` ran exited, by its notes; none while it runs, or where its tool tells nothing. */
export function exitOf(call: ToolCall): Exit | undefined {
	if (call.output === undefined) return undefined;
	for (const note of toldOf(call.output).notes) {
		const code = /^exit (\d+)$/.exec(note);
		if (code !== null) return { kind: "code", code: Number(code[1]) };
		const signal = /^signal (\d+)$/.exec(note);
		if (signal !== null) return { kind: "signal", signal: Number(signal[1]) };
		if (note.startsWith("timed out")) return { kind: "timed-out" };
	}
	return undefined;
}

/** What an edit or a write added and took out, in lines. */
export type Change = { readonly added: number; readonly removed: number };

/** What the edit or the write `call` changed: counted from an edit's diff, read from a write's words; none for any other call, or one that did not go through. */
export function changeOf(call: ToolCall): Change | undefined {
	if (call.output === undefined || call.state !== "done") return undefined;
	const { text } = toldOf(call.output);
	if (call.tool === "write") {
		const written = /^(?:created|wrote) .* \+(\d+)(?: -(\d+))?$/.exec(text.trim());
		return written === null ? undefined : { added: Number(written[1]), removed: Number(written[2] ?? 0) };
	}
	if (call.tool !== "edit") return undefined;
	const tones = diffTones(text.split("\n"));
	return { added: tones.filter((tone) => tone === "added").length, removed: tones.filter((tone) => tone === "removed").length };
}

/** The diff the edit `call` gave, from its first hunk on — its head, which names the file its line names, left out; none for any other call, or one that did not go through. */
export function hunksOf(call: ToolCall): string | undefined {
	if (call.tool !== "edit" || call.output === undefined || call.state !== "done") return undefined;
	const lines = toldOf(call.output).text.split("\n");
	return lines
		.slice(
			Math.max(
				0,
				lines.findIndex((line) => line.startsWith("@@")),
			),
		)
		.join("\n");
}

/** The lines a read held, as its notes tell them, "lines 1–200"; none where it held a whole file. */
export function spanOf(call: ToolCall): string | undefined {
	if (call.output === undefined) return undefined;
	for (const note of toldOf(call.output).notes) {
		const lines = /^lines (\d+)-(\d+)/.exec(note);
		if (lines !== null) return `lines ${lines[1] ?? ""}–${lines[2] ?? ""}`;
	}
	return undefined;
}

/** A place a search found: a file's path, and the line and its words where it found a line in it. */
export type Found = { readonly path: string; readonly line: number | undefined; readonly text: string | undefined };

/** What the search `call` found: a glob's paths, a grep's matching lines — its lines around them left out. */
export function foundOf(call: ToolCall): readonly Found[] {
	if (call.output === undefined || call.state !== "done") return [];
	const lines = toldOf(call.output)
		.text.split("\n")
		.filter((line) => line !== "");
	if (call.tool === "glob") return lines.map((path) => ({ path, line: undefined, text: undefined }));
	return lines.flatMap((line) => {
		const match = /^(.+?):(\d+): (.*)$/.exec(line);
		return match === null ? [] : [{ path: match[1] ?? "", line: Number(match[2]), text: match[3] ?? "" }];
	});
}

/** A field of a call's arguments: its name, and its value as text — a string as it is, anything else as JSON. */
export type Field = { readonly name: string; readonly value: string };

const FieldsSchema = Type.Record(Type.String(), Type.Unknown());

/** The fields of the arguments `text` holds, in the order they were written; none where they are no JSON object. */
export function fieldsOf(text: string): readonly Field[] | undefined {
	try {
		const given: unknown = JSON.parse(text);
		if (!matches(FieldsSchema, given) || Array.isArray(given)) return undefined;
		return Object.entries(given).map(([name, value]) => ({ name, value: typeof value === "string" ? value : JSON.stringify(value) }));
	} catch {
		return undefined;
	}
}

/** Arguments as a person reads them: their JSON laid out, a line for each field; as they were written where they do not parse. */
export function prettyArguments(text: string): string {
	try {
		return JSON.stringify(JSON.parse(text), null, 2);
	} catch {
		return text;
	}
}
