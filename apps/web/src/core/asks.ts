/**
 * What waits on the person in a thread, as the page asks it: each request a fiber made that the person answers, read
 * from the JSON Schema its answer fits. Trust in what a folder's configuration would run is asked with the servers it
 * names; a call's permission with what it does, and to what; a model's questions one by one, each with its choices and
 * the person's own words; a union of objects each named by one constant, such as `{ decision: "once" }`, is a choice of
 * them, each with the fields it takes; an object's own fields are asked one by one; a schema of neither shape is shown,
 * not asked.
 */
import { type Ask, matches } from "@octoii-works/octoii-client";
import { type Static, Type } from "typebox";
import { folderName } from "./threads.ts";

/** A JSON value, as an answer is made of. */
export type Json = string | number | boolean | null | readonly Json[] | { readonly [key: string]: Json };

/**
 * A field an answer takes: where its value goes, such as `["reason"]` or `["content", "email"]`, its label, what it
 * means, whether it must be given, and what it takes: text, a number, yes or no, or one of some values.
 */
export type Field = {
	readonly path: readonly string[];
	readonly label: string;
	readonly description?: string;
	readonly required: boolean;
	readonly takes: { readonly kind: "text" | "number" | "boolean" } | { readonly kind: "one"; readonly values: readonly string[] };
};

/** One answer a request offers: the constant that names it, its label, and the fields it takes. */
export type Choice = { readonly value: string; readonly label: string; readonly fields: readonly Field[] };

/** A server a folder's configuration would run, as the person is shown it. */
export type ServerShown = Static<typeof ServerSchema>;

/**
 * What a call does to the machine, as its permission is asked: its action; what it acts on — the files it edits, the
 * commands it runs, the tool by its name — none where that could not be read; the patterns an always grants the
 * thread's project; and whether it asks to run beyond the sandbox, and why.
 */
export type Access = Static<typeof AccessSchema>;

/** A question a model asks: its words, a short label, the choices it offers, and whether several may be chosen. */
export type Question = Static<typeof QuestionSchema>;

/** What a request asks, by its form. */
export type AskForm =
	| { readonly kind: "trust"; readonly folder: string; readonly servers: readonly ServerShown[] }
	| { readonly kind: "permission"; readonly tool: string; readonly arguments: unknown; readonly access: Access; readonly doubt: string | undefined }
	| { readonly kind: "question"; readonly questions: readonly Question[] }
	| { readonly kind: "choices"; readonly key: string; readonly choices: readonly Choice[] }
	| { readonly kind: "fields"; readonly fields: readonly Field[] }
	| { readonly kind: "shown" };

/** What the person gave of each field of an answer, by its path joined with `.`. */
export type Given = Readonly<Record<string, Json>>;

/** The name of Siphon's request for the person's trust in what a folder's configuration names to run. */
const TRUST = "trust";
/** The name of Siphon's request for the person's permission for a call. */
const PERMISSION = "permission";
/** The name of the request a `question` call asks the person by. */
const QUESTION = "question";

const AccessSchema = Type.Object({
	action: Type.Union([Type.Literal("edit"), Type.Literal("command"), Type.Literal("tool")]),
	resources: Type.Array(Type.String()),
	save: Type.Array(Type.String()),
	escalate: Type.Optional(Type.Boolean()),
	justification: Type.Optional(Type.String()),
});
const PermissionAskedSchema = Type.Object({ tool: Type.String(), arguments: Type.Unknown(), access: AccessSchema, doubt: Type.Optional(Type.String()) });
const QuestionSchema = Type.Object({
	question: Type.String(),
	header: Type.String(),
	options: Type.Optional(Type.Array(Type.Object({ label: Type.String(), description: Type.Optional(Type.String()) }))),
	multiple: Type.Optional(Type.Boolean()),
});
const QuestionsAskedSchema = Type.Object({ questions: Type.Array(QuestionSchema) });

const ServerSchema = Type.Object({ name: Type.String(), command: Type.String(), args: Type.Optional(Type.Array(Type.String())) });
const TrustAskedSchema = Type.Object({ folder: Type.String(), servers: Type.Optional(Type.Array(ServerSchema)) });
const ObjectSchema = Type.Object({ properties: Type.Record(Type.String(), Type.Unknown()), required: Type.Optional(Type.Array(Type.String())) });
const UnionSchema = Type.Object({ anyOf: Type.Array(Type.Unknown()) });
const PropertySchema = Type.Object({
	type: Type.Optional(Type.String()),
	title: Type.Optional(Type.String()),
	description: Type.Optional(Type.String()),
	enum: Type.Optional(Type.Array(Type.Unknown())),
});
const ConstSchema = Type.Object({ const: Type.String() });

type ObjectShape = Static<typeof ObjectSchema>;

/** The form of what `ask` asks: by its request's name and what it was made with, else by its answer's schema. */
export function formOf(ask: Ask): AskForm {
	const { name, payload, answer } = ask.request;
	if (name === TRUST && matches(TrustAskedSchema, payload)) return { kind: "trust", folder: payload.folder, servers: payload.servers ?? [] };
	if (name === PERMISSION && matches(PermissionAskedSchema, payload))
		return { kind: "permission", tool: payload.tool, arguments: payload.arguments, access: payload.access, doubt: payload.doubt };
	if (name === QUESTION && matches(QuestionsAskedSchema, payload)) return { kind: "question", questions: payload.questions };
	const members = matches(UnionSchema, answer) ? answer.anyOf.filter((member) => matches(ObjectSchema, member)) : [];
	const offered = members.length > 0 ? members : matches(ObjectSchema, answer) ? [answer] : [];
	const choices = choicesOf(offered);
	if (choices !== undefined) return choices;
	const [only] = offered;
	return offered.length === 1 && only !== undefined ? { kind: "fields", fields: fieldsOf(only, []) } : { kind: "shown" };
}

/** The answers objects offer, each named by a constant of the same property; none for another shape. */
function choicesOf(offered: readonly ObjectShape[]): AskForm | undefined {
	const named = offered.map((member) => ({ member, key: constKeyOf(member) }));
	const key = named[0]?.key;
	if (key === undefined || named.some((each) => each.key !== key)) return undefined;
	const choices = named.map(({ member }): Choice => {
		const property = member.properties[key];
		const value = matches(ConstSchema, property) ? property.const : "";
		const label = matches(PropertySchema, property) && property.title !== undefined ? property.title : spoken(value);
		return { value, label, fields: fieldsOf(member, [], key) };
	});
	return { kind: "choices", key, choices };
}

/** The one property of an object's schema that is a string constant; none where it has none or several. */
function constKeyOf(schema: ObjectShape): string | undefined {
	const keys = Object.keys(schema.properties).filter((name) => matches(ConstSchema, schema.properties[name]));
	return keys.length === 1 ? keys[0] : undefined;
}

/** The fields an object's schema takes, but `left`, an object's own taken one level down, under `at`. */
function fieldsOf(schema: ObjectShape, at: readonly string[], left?: string): readonly Field[] {
	const required = new Set(schema.required ?? []);
	return Object.entries(schema.properties).flatMap(([name, property]): readonly Field[] => {
		if (name === left || !matches(PropertySchema, property)) return [];
		if (property.type === "object" && at.length === 0 && matches(ObjectSchema, property)) return fieldsOf(property, [name]);
		const takes = takesOf(property);
		if (takes === undefined) return [];
		return [
			{
				path: [...at, name],
				label: property.title ?? spoken(name),
				...(property.description === undefined ? {} : { description: property.description }),
				required: required.has(name),
				takes,
			},
		];
	});
}

/** What a property takes, where a field can give it: text, a number, yes or no, or one of its values. */
function takesOf(property: Static<typeof PropertySchema>): Field["takes"] | undefined {
	const values = (property.enum ?? []).filter((value) => typeof value === "string");
	if (values.length > 0) return { kind: "one", values };
	switch (property.type) {
		case "string":
			return { kind: "text" };
		case "number":
		case "integer":
			return { kind: "number" };
		case "boolean":
			return { kind: "boolean" };
		default:
			return undefined;
	}
}

/** Whether a field was left without a value. */
export function isEmpty(value: Json | undefined): boolean {
	return value === undefined || value === null || (typeof value === "string" && value.trim() === "");
}

/** An answer of fields: each field given at its path, text trimmed, under `base`. */
export function fieldsAnswer(fields: readonly Field[], given: Given, base: Readonly<Record<string, Json>> = {}): Json {
	const answer: Record<string, Json> = { ...base };
	for (const field of fields) {
		const value = given[field.path.join(".")];
		const [first, second] = field.path;
		if (value === undefined || isEmpty(value) || first === undefined) continue;
		const kept = typeof value === "string" ? value.trim() : value;
		if (second === undefined) answer[first] = kept;
		else {
			const inner = answer[first];
			answer[first] = { ...(typeof inner === "object" && inner !== null && !Array.isArray(inner) ? inner : {}), [second]: kept };
		}
	}
	return answer;
}

/** An answer of a choice: its constant under its property, and each field given at its path. */
export function choiceAnswer(property: string, choice: Choice, given: Given): Json {
	return fieldsAnswer(choice.fields, given, { [property]: choice.value });
}

/** Whether a choice's or an object's fields are given as they must be. */
export function missingField(fields: readonly Field[], given: Given): boolean {
	return fields.some((field) => field.required && field.takes.kind !== "boolean" && isEmpty(given[field.path.join(".")]));
}

/** A line of what a call asks to do, as its card shows it: its number, which names it, and its text, plain or taken out or put in by an edit. */
export type DetailLine = { readonly number: number; readonly kind: "text" | "removed" | "added"; readonly text: string };

/** A line before it is numbered. */
type Unnumbered = Omit<DetailLine, "number">;

const CommandArgumentsSchema = Type.Object({ command: Type.String() });
const EditArgumentsSchema = Type.Object({ old: Type.String(), new: Type.String() });
const WriteArgumentsSchema = Type.Object({ content: Type.String() });

/** What a call asks the person, in words: to run a command — beyond the sandbox, where it asks to — to write or edit a file, or to use a tool. */
export function permissionTitle(tool: string, access: Access): string {
	switch (access.action) {
		case "command":
			return access.escalate === true ? "Run this beyond the sandbox?" : "Run this command?";
		case "edit":
			return tool === "write" ? "Write this file?" : "Edit this file?";
		case "tool":
			return `Use ${tool}?`;
	}
}

/**
 * What a call asks to do, line by line: the command line it runs; the file it edits — as the model writes it, relative
 * within the thread's workspace — then its change, what it takes out and puts in, or what a write puts in whole; the
 * tool it calls, then its arguments.
 */
export function permissionDetail(tool: string, args: unknown, access: Access, workspace: string | undefined): readonly DetailLine[] {
	return detailOf(tool, args, access, workspace).map((line, number) => ({ ...line, number }));
}

function detailOf(tool: string, args: unknown, access: Access, workspace: string | undefined): readonly Unnumbered[] {
	const text = (line: string): Unnumbered => ({ kind: "text", text: line });
	switch (access.action) {
		case "command":
			return (matches(CommandArgumentsSchema, args) ? args.command : access.resources.join("\n")).split("\n").map(text);
		case "edit":
			return [text(shownPath(access.resources[0] ?? "", workspace)), ...changeOf(args)];
		case "tool":
			return [text(tool), ...JSON.stringify(args, null, 2).split("\n").map(text)];
	}
}

/** An absolute path as the model writes it: relative within `workspace`, `.` for the workspace itself, else whole. */
export function shownPath(path: string, workspace: string | undefined): string {
	if (workspace === undefined) return path;
	if (path === workspace) return ".";
	const within = workspace.endsWith("/") ? workspace : `${workspace}/`;
	return path.startsWith(within) ? path.slice(within.length) : path;
}

/** The lines an edit takes out and puts in, or a write puts in whole; none of another call. */
function changeOf(args: unknown): readonly Unnumbered[] {
	const lines = (kind: DetailLine["kind"], body: string): readonly Unnumbered[] => body.split("\n").map((line) => ({ kind, text: line }));
	if (matches(EditArgumentsSchema, args)) return [...lines("removed", args.old), ...lines("added", args.new)];
	if (matches(WriteArgumentsSchema, args)) return lines("added", args.content.replace(/\n$/, ""));
	return [];
}

/** What an always answer grants the thread's project, in words; none where nothing of the call could be granted, or the thread has no project. */
export function alwaysText(access: Access, project: string | undefined): string | undefined {
	if (access.save.length === 0 || project === undefined) return undefined;
	const where = folderName(project);
	return access.action === "edit" ? `Allow every edit in ${where}` : `Always allow ${access.save.join(", ")} in ${where}`;
}

/** What the person gave of a question so far: the choices' labels they chose, and words of their own. */
export type Draft = { readonly chosen: readonly string[]; readonly own: string };

/** A question nothing is given of yet. */
export const UNANSWERED: Draft = { chosen: [], own: "" };

/** `draft` with the choice `label` taken: the one answer of a question of one choice, else toggled among the rest. */
export function choose(question: Question, draft: Draft, label: string): Draft {
	if (question.multiple === true) {
		return { ...draft, chosen: draft.chosen.includes(label) ? draft.chosen.filter((each) => each !== label) : [...draft.chosen, label] };
	}
	return { chosen: draft.chosen[0] === label ? [] : [label], own: "" };
}

/** `draft` with the person's own words: of a question of one choice, its answer in place of a choice. */
export function write(question: Question, draft: Draft, own: string): Draft {
	if (question.multiple === true || own.trim() === "") return { ...draft, own };
	return { chosen: [], own };
}

/** The answer of questions the person dismissed, answering none. */
export const DISMISSED: Json = { dismissed: true };

/** The answer to the questions, from what the person gave of each: the labels chosen, then their own words. */
export function questionsAnswer(drafts: readonly Draft[]): Json {
	return { answers: drafts.map((draft) => [...draft.chosen, ...(draft.own.trim() === "" ? [] : [draft.own.trim()])]) };
}

/** A name as people read it: `not_now` is "Not now". */
function spoken(name: string): string {
	const words = name.replaceAll(/[_-]+/g, " ").trim();
	return words.charAt(0).toUpperCase() + words.slice(1);
}
