/**
 * A thread as the page shows it, read from its conversation, which the client puts together by the ids that tie its
 * parts: each turn as the person's words that began it, the work it did — a line for each call, the calls made under
 * it beneath, the model's words on the way — its answer, and the files it changed; while it runs, what streams of the
 * request it waits on; and how it ended, when, and after how long. Everything stands where its entry's id puts it, as
 * every id is minted in the order the log is written: the person's words cut a turn into parts, a step stands at its
 * request, what a reply said at the reply, a compaction — the thread's — among the work of the turn whose span holds
 * it, else a row of its own between turns, and what waits on the person that no call asks likewise. What the log holds in `ai`'s vocabulary is read
 * through schemas of the parts the page shows, each call's line by what the page knows of its tool. A turn that ended
 * is read once and kept, as the client keeps it the same; a call's line is kept while its call and what it waits on the
 * person for are the same — so a thread that grows is read again only where it grew.
 */
import { type Ask, type Call, type Conversation, type Entry, type Limited, matches, type Standing, type Step, type Turn } from "@octoii-works/octoii-client";

/** A compaction of the thread's, as its log holds it. */
type Compaction = Conversation["compactions"][number];
import { Type } from "typebox";
import { type Attachment, attachmentsOf } from "./attachments.ts";
import { settledOf } from "./blocks.ts";
import { type CallState, printedOf } from "./calls.ts";
import { mintedAt } from "./time.ts";
import { type Aside, givenOf, summaryOf, toolOf, verbOf, type WorkKind } from "./tools.ts";

/**
 * A call's line: its id, Siphon's id of it where known, the step it was made in, its tool, its kind of work, how its
 * line says what it does — its verb, what it works on and whether that is code, what it says beside that and at its end
 * where it went wrong though it ran — its arguments and what its tool told, when it began and ended, how it stands, and
 * the calls made under it.
 */
export type CallLine = {
	readonly kind: "call";
	readonly id: string;
	/** Siphon's id of the call, the key of the fiber that runs it, by which a sub-thread it made names it. */
	readonly fiber: string | undefined;
	/** The step it was made in, by its request's key: the calls one reply made share it, and those made under them. */
	readonly step: string;
	/** The thread its arguments name: the sub-thread a delegation gives more to do. */
	readonly thread: string | undefined;
	readonly tool: string;
	readonly work: WorkKind;
	/** Its verb as it stands; none for a tool the page has no words for, which its line names. */
	readonly verb: string | undefined;
	readonly subject: string | undefined;
	/** Whether what it works on is code — a command, a pattern — or, with no verb, its tool's name is. */
	readonly code: boolean;
	readonly aside: Aside | undefined;
	readonly trouble: string | undefined;
	/** Its arguments, as they were written. */
	readonly arguments: string;
	/** What its tool told: its result's output; none before it ended. */
	readonly output: string | undefined;
	/** What its tool has printed so far, while it runs — a command's output, its latest part; none where it printed nothing. */
	readonly printed: string | undefined;
	/** When it began and ended, in ms: as Siphon's id of it and its result's were minted; none of either it has not had. */
	readonly began: number | undefined;
	readonly ended: number | undefined;
	readonly state: CallState;
	/** What it waits on the person for, where it does: its permission, or a question it asks. */
	readonly ask: Ask | undefined;
	readonly calls: readonly CallLine[];
};

/**
 * A step of a turn's work: a call, a search of the web its provider ran, what the model thought — as its reply gives it,
 * with how long its request took — its words on the way, a request that came to nothing, the thread summed up.
 */
export type Work =
	| CallLine
	| { readonly kind: "web-search"; readonly key: string; readonly query: string | undefined }
	| { readonly kind: "thought"; readonly key: string; readonly text: string; readonly took: number | undefined }
	| { readonly kind: "words"; readonly key: string; readonly text: string }
	| { readonly kind: "failure"; readonly key: string; readonly text: string }
	| { readonly kind: "compaction"; readonly key: string };

/** How a turn stands: working, how it ended, or gone on with what the person said next, which steered it. */
export type Ending =
	| { readonly state: "working" }
	| { readonly state: "replied" }
	| { readonly state: "failed"; readonly why: string }
	| { readonly state: "stopped" }
	| { readonly state: "steered" };

/**
 * Words a turn took: their entry's id, when they were said, whose they are — the person's, or a thread's, by its id: a
 * sub-thread's task, given by its thread, or what came of one given in the background, told by the sub-thread — their
 * text, and the files given with them.
 */
export type Said = {
	readonly key: string;
	readonly at: number;
	readonly from: string | undefined;
	readonly text: string;
	readonly attachments: readonly Attachment[];
};

/** What streams of the request a turn waits on: the words being written, and the calls being formed, by their tools. */
export type Writing = { readonly words: string; readonly calls: readonly { readonly id: string; readonly tool: string }[] };

/** A file a turn's edits and writes changed: its path, as a call named it, and the lines they added and took out. */
export type Changed = { readonly path: string; readonly added: number; readonly removed: number };

/** A turn as the page shows it. */
export type TimelineTurn = {
	readonly key: string;
	readonly said: readonly Said[];
	readonly work: readonly Work[];
	readonly answer: { readonly key: string; readonly text: string } | undefined;
	/** The files its edits and writes changed, its calls' own among them. */
	readonly changes: readonly Changed[];
	readonly writing: Writing;
	/** When the request it waits on was made, in ms, as its key was minted; none where it waits on none. */
	readonly asking: number | undefined;
	/** What waits on the person that no call of the thread asks, as trust in a project's servers, asked within its span: on its last part alone. */
	readonly asks: readonly Ask[];
	readonly ending: Ending;
	/** When it began and ended, in ms, as the ids of its first and its last entries were minted. */
	readonly startedAt: number | undefined;
	readonly endedAt: number | undefined;
};

const PartsSchema = Type.Array(Type.Unknown());
const InputMessageSchema = Type.Object({ content: Type.Union([Type.String(), PartsSchema]) });
const InputTextSchema = Type.Object({ type: Type.Literal("input_text"), text: Type.String() });
const OutputSchema = Type.Object({ output: PartsSchema });
const AssistantMessageSchema = Type.Object({ type: Type.Literal("message"), role: Type.Literal("assistant"), content: PartsSchema });
const OutputTextSchema = Type.Object({ type: Type.Literal("output_text"), text: Type.String() });
const ErrorSchema = Type.Object({ error: Type.Object({ message: Type.String() }) });
const ItemEventSchema = Type.Object({
	type: Type.Union([Type.Literal("response.output_item.added"), Type.Literal("response.output_item.done")]),
	output_index: Type.Number(),
	item: Type.Unknown(),
});
const TextDeltaSchema = Type.Object({ type: Type.Literal("response.output_text.delta"), output_index: Type.Number(), delta: Type.String() });
const FunctionCallSchema = Type.Object({ type: Type.Literal("function_call"), call_id: Type.String(), name: Type.String() });

/**
 * A row of the timeline, at the id it stands at: a turn — a part of one the person steered — or the thread's own
 * between turns: its window summed up, or what waits on the person that no call asks.
 */
export type TimelineRow =
	| { readonly kind: "turn"; readonly key: string; readonly turn: TimelineTurn }
	| { readonly kind: "summed-up"; readonly key: string }
	| { readonly kind: "ask"; readonly key: string; readonly ask: Ask }
	| { readonly kind: "limited"; readonly key: string; readonly limited: Limited; readonly resumingAt: number | undefined };

/** `rows`, and, where the thread its model's quota limits as `standing` says, the card of that at their end. */
export function withLimited(rows: readonly TimelineRow[], standing: Standing | undefined): readonly TimelineRow[] {
	const limited = standing?.limited;
	if (limited === undefined) return rows;
	return [...rows, { kind: "limited", key: "limited", limited, resumingAt: standing?.resuming_at }];
}

/**
 * The rows of a conversation, in the order their ids give, as ids are minted in the order the log is written: each turn
 * as the page shows it — one for each part the person steered it into — from where it began, with the compactions its
 * span holds among its work and what no call asks within it on its last part; and every compaction and ask between
 * turns a row of its own.
 */
export function rowsOf(conversation: Conversation): readonly TimelineRow[] {
	const { turns, asks } = conversation;
	const spans = turns.map(spanOf);
	const placed: { readonly at: string; readonly rows: readonly TimelineRow[] }[] = [];
	const shown = turns.map((turn, place) =>
		shownOf(turn, place, { asks, compactions: conversation.compactions.filter((each) => within(spans[place], each.id)) }),
	);
	const asked = new Set(shown.flat().flatMap((turn) => askedIn(turn.work)));
	const unasked = asks.filter((ask) => !asked.has(ask.request.key));
	shown.forEach((parts, place) => {
		const waiting = unasked.filter((ask) => within(spans[place], ask.request.key));
		const last = parts.at(-1);
		const kept = last === undefined || waiting.length === 0 ? parts : [...parts.slice(0, -1), { ...last, asks: waiting }];
		placed.push({ at: spans[place]?.from ?? "", rows: kept.map((turn) => ({ kind: "turn", key: turn.key, turn })) });
	});
	const between = (id: string): boolean => !spans.some((span) => within(span, id));
	for (const compaction of conversation.compactions) {
		if (between(compaction.id)) placed.push({ at: compaction.id, rows: [{ kind: "summed-up", key: compaction.id }] });
	}
	for (const ask of unasked) if (between(ask.request.key)) placed.push({ at: ask.request.key, rows: [{ kind: "ask", key: ask.request.key, ask }] });
	return placed.toSorted((a, b) => (a.at < b.at ? -1 : a.at > b.at ? 1 : 0)).flatMap((each) => each.rows);
}

/** Where a turn lies in its log, by ids: from the first of its entries, through its end — on, while it runs. */
type TurnSpan = { readonly from: string; readonly through: string | undefined };

/** The span of `turn`: from what its model was told as it began, else its first words, its first step, or its end. */
function spanOf(turn: Turn): TurnSpan | undefined {
	const from = turn.told[0]?.id ?? turn.inputs[0]?.id ?? turn.steps[0]?.request ?? turn.end?.id;
	return from === undefined ? undefined : { from, through: turn.end?.id };
}

/** The place among `turns` of the turn the entry of `id` falls in — the one whose span holds it, else the last that began before it — the first for one before any. */
export function placeOf(turns: readonly Turn[], id: string): number {
	let place = 0;
	turns.forEach((turn, at) => {
		const span = spanOf(turn);
		if (span !== undefined && span.from <= id) place = at;
	});
	return place;
}

/** Whether the entry of `id` lies within `span`. */
function within(span: TurnSpan | undefined, id: string): boolean {
	return span !== undefined && span.from <= id && (span.through === undefined || id <= span.through);
}

/** What of the thread's stands beside a turn's own entries: what waits on the person, and the compactions its span holds. */
type Beside = { readonly asks: readonly Ask[]; readonly compactions: readonly Compaction[] };

/** Each turn that ended as the page shows it, by the client's turn: read once, as a turn that ended never changes — the compactions its span holds among it. */
const shownTurns = new WeakMap<Turn, readonly TimelineTurn[]>();

/**
 * `turn`, the `place`th the client holds, as the page shows it — one turn for each part of it — with what of `beside`
 * its calls wait on the person for, and the compactions its span holds.
 */
function shownOf(turn: Turn, place: number, beside: Beside): readonly TimelineTurn[] {
	const known = shownTurns.get(turn);
	if (known !== undefined) return known;
	const parts = partsOf(turn);
	const shown = parts.map((part, index) => partOf(turn, part, parts[index + 1], place, index, beside));
	if (turn.end !== undefined) shownTurns.set(turn, shown);
	return shown;
}

/** The keys of what the calls of `work` wait on the person for, a script's own among them. */
function askedIn(work: readonly Work[]): readonly string[] {
	return work.flatMap((step) => (step.kind === "call" ? [...(step.ask === undefined ? [] : [step.ask.request.key]), ...askedIn(step.calls)] : []));
}

/** Words of the person's a turn took, and the steps from them on: the words it began with, or words that steered it. */
type Part = { readonly inputs: readonly Input[]; readonly steps: readonly Step[] };

type Input = Turn["inputs"][number];

/** Where a part of a turn lies in its log, by the ids of its entries: from its first, none for the turn's first part, until the next part's first, none for its last. */
type Span = { readonly from: string | undefined; readonly until: string | undefined };

/**
 * A turn's parts: the words it began with and its steps from them, then each of the person's words it took within it
 * and its steps from them — placed among the steps by their ids, which are minted in the order the log was written.
 */
function partsOf(turn: Turn): readonly Part[] {
	const parts: { inputs: Input[]; steps: Step[] }[] = [{ inputs: [], steps: [] }];
	let waiting = [...turn.inputs];
	for (const step of turn.steps) {
		const before = waiting.filter((input) => input.id < step.request);
		waiting = waiting.filter((input) => input.id >= step.request);
		const current = parts.at(-1);
		if (current === undefined) break;
		if (before.length > 0 && current.steps.length > 0) parts.push({ inputs: before, steps: [step] });
		else {
			current.inputs.push(...before);
			current.steps.push(step);
		}
	}
	if (waiting.length > 0) parts.push({ inputs: waiting, steps: [] });
	return parts;
}

/**
 * The part `part` of `turn` as the page shows it, the part after it, where there is one, the words that steered it on;
 * with those of the compactions `beside` it its span holds.
 */
function partOf(turn: Turn, part: Part, next: Part | undefined, place: number, index: number, beside: Beside): TimelineTurn {
	const first = part.inputs[0]?.id ?? (index === 0 ? turn.told[0]?.id : part.steps[0]?.request);
	const steeredAt = next?.inputs[0]?.id;
	const span: Span = { from: index === 0 ? undefined : first, until: steeredAt };
	const held = beside.compactions.filter((each) => (span.from === undefined || each.id > span.from) && (span.until === undefined || each.id < span.until));
	const { work, answer } = workOf(turn, part, held, beside.asks);
	const waiting = part.steps.find((step) => step.reply === undefined && step.failure === undefined);
	return {
		// Known by the entry it began with, which it has from the first, not by its fiber's key, which the client may learn
		// after — so a turn keeps its row as it goes, rather than being drawn anew.
		key: index === 0 ? (first ?? turn.id ?? turn.end?.id ?? `turn-${String(place)}`) : (first ?? `turn-${String(place)}-${String(index)}`),
		said: part.inputs.flatMap((input) => {
			const from = threadOfActor(input.actor);
			const text = from === undefined ? inputText(input.message) : threadText(input.message);
			const attachments = attachmentsOf(input.message);
			// What a sub-thread told is shown though it holds no words: how its work ended.
			const shown = text !== "" || attachments.length > 0 || from !== undefined;
			return shown ? [{ key: input.id, at: mintedAt(input.id), from, text, attachments }] : [];
		}),
		work,
		answer,
		changes: changesOf(work),
		writing: writingOf(waiting?.streaming ?? []),
		asking: waiting === undefined ? undefined : mintedAt(waiting.request),
		asks: [],
		ending: steeredAt === undefined ? endingOf(turn) : { state: "steered" },
		startedAt: first === undefined ? undefined : mintedAt(first),
		endedAt: steeredAt !== undefined ? mintedAt(steeredAt) : turn.end === undefined ? undefined : mintedAt(turn.end.id),
	};
}

/**
 * The work of a part of a turn, its steps in the order its log has them, and its answer: the words of its last reply
 * that made no call. Words an earlier reply gave are words on the way once the turn went on. `held`, the compactions
 * its span holds, stand among its steps by their ids.
 */
function workOf(
	turn: Turn,
	part: Part,
	held: readonly Compaction[],
	asks: readonly Ask[],
): { readonly work: readonly Work[]; readonly answer: TimelineTurn["answer"] } {
	const work: Work[] = [];
	let answer: TimelineTurn["answer"];
	const compactions = [...held];
	for (const step of part.steps) {
		const at = stepId(step);
		while (at !== undefined && compactions[0] !== undefined && compactions[0].id < at) {
			work.push({ kind: "compaction", key: compactions[0].id });
			compactions.shift();
		}
		const text = step.reply === undefined ? "" : replyText(step.reply.response);
		const thought = step.reply === undefined ? "" : reasoningText(step.reply.response);
		if (step.reply !== undefined && thought !== "") {
			work.push({ kind: "thought", key: `${step.reply.id}:thought`, text: thought, took: mintedAt(step.reply.id) - mintedAt(step.request) });
		}
		if (step.reply !== undefined && text !== "") {
			if (answer !== undefined) work.push({ kind: "words", ...answer });
			answer = step.calls.length > 0 ? undefined : { key: step.reply.id, text };
			if (step.calls.length > 0) work.push({ kind: "words", key: step.reply.id, text });
		}
		if (step.failure !== undefined) work.push({ kind: "failure", key: step.failure.id, text: failureText(step.failure.response) });
		if (step.reply !== undefined) work.push(...searchesOf(step.reply.response));
		for (const call of step.calls) work.push(callLine(call, turn, step.request, asks));
	}
	for (const compaction of compactions) work.push({ kind: "compaction", key: compaction.id });
	return { work, answer };
}

/** The id of the entry that says what came of a step's request; none while it is answered. */
function stepId(step: Step): string | undefined {
	return step.reply?.id ?? step.failure?.id;
}

/** Each call's line, by the client's call, with the step it was made in and what it waits on the person for: kept while they are the same. */
const lines = new WeakMap<Call, { readonly step: string; readonly ask: Ask | undefined; readonly line: CallLine }>();

/**
 * A call as its line shows it, made in `turn` at the step `step`, with what of `asks` it waits on the person for — the
 * line it had where the call and what it waits for are the same, as a call the client keeps the same is: one with no
 * result when its turn ended was stopped with it, and a turn that ends is put together anew.
 */
function callLine(call: Call, turn: Turn, step: string, asks: readonly Ask[]): CallLine {
	const ask = asks.find((each) => each.call === call.id);
	const known = lines.get(call);
	if (known !== undefined && known.step === step && known.ask === ask) return known.line;
	const line = lineOf(call, turn, step, asks, ask);
	lines.set(call, { step, ask, line });
	return line;
}

/** The line of `call`, as `callLine` gives it, read anew: by what the page knows of its tool, the calls made under it its own lines, which a call with any says what did beside its verb. */
function lineOf(call: Call, turn: Turn, step: string, asks: readonly Ask[], ask: Ask | undefined): CallLine {
	const tool = toolOf(call.name);
	const given = givenOf(call.arguments);
	const fiber = call.result?.call ?? call.fiber?.key;
	const state = call.result === undefined ? liveState(call, turn) : CALL_STATES[call.result.status];
	const output = call.result === undefined ? undefined : outputOf(call.result.call_output);
	const printed = call.result === undefined ? printedOf(call.streaming) : undefined;
	const told = { tool: call.name, arguments: call.arguments, output, printed, state };
	const calls = call.calls.map((inner) => callLine(inner, turn, step, asks));
	return {
		kind: "call",
		id: call.id,
		fiber,
		step,
		thread: call.name === "delegate" ? given.thread : undefined,
		tool: call.name,
		work: tool.work,
		verb: verbOf(told),
		subject: tool.subject(given),
		code: tool.code,
		aside: calls.length > 0 ? { kind: "words", text: summaryOf(calls) } : tool.aside(told),
		trouble: tool.trouble(told),
		arguments: call.arguments,
		output,
		printed,
		began: fiber === undefined ? undefined : mintedAt(fiber),
		ended: call.result === undefined ? undefined : mintedAt(call.result.id),
		state,
		ask,
		calls,
	};
}

/**
 * The steps of `work` as the page lays them out: a stretch of calls one after another — what the model thought between
 * them among them, its words or a failure ending it, a call that waits on the person standing on its own — as one item
 * from its first call on, gathered where it made more than one, so a stretch that grows is the same item: one call the
 * line of its own, what was thought before it lines of their own; each call that delegates gathered with those made
 * straight after it; every other step on its own.
 */
export type Laid =
	| { readonly kind: "step"; readonly step: Work }
	| { readonly kind: "calls"; readonly key: string; readonly steps: readonly Work[]; readonly calls: readonly CallLine[] }
	| { readonly kind: "delegations"; readonly key: string; readonly calls: readonly CallLine[] };

export function laidOut(work: readonly Work[]): readonly Laid[] {
	const laid: Laid[] = [];
	let stretch: Work[] = [];
	const close = (): void => {
		const calls = stretch.flatMap((step) => (step.kind === "call" ? [step] : []));
		const [first] = calls;
		if (first !== undefined && calls.length > 1) laid.push({ kind: "calls", key: first.id, steps: stretch, calls });
		else for (const step of stretch) laid.push(step.kind === "call" ? { kind: "calls", key: step.id, steps: [step], calls: [step] } : { kind: "step", step });
		stretch = [];
	};
	for (const step of work) {
		if ((step.kind === "call" && step.work !== "delegate" && step.ask === undefined) || step.kind === "thought") {
			stretch.push(step);
			continue;
		}
		close();
		const last = laid.at(-1);
		if (step.kind === "call" && step.work === "delegate") {
			if (last?.kind === "delegations") laid[laid.length - 1] = { ...last, calls: [...last.calls, step] };
			else laid.push({ kind: "delegations", key: step.id, calls: [step] });
		} else laid.push({ kind: "step", step });
	}
	close();
	return laid;
}

/** How many calls `work` made, a script's own among them. */
export function callsIn(work: readonly Work[]): number {
	return work.reduce((count, step) => (step.kind === "call" ? count + 1 + callsIn(step.calls) : count), 0);
}

/** How a call with no result stands: stopped with its turn, waiting where its fiber waits on the person, else running. */
function liveState(call: Call, turn: Turn): CallState {
	if (turn.end !== undefined) return "stopped";
	return call.fiber?.requests.some((request) => request.answer !== undefined) === true ? "waiting" : "running";
}

/** How a call stands, by its result's status. */
const CALL_STATES: Readonly<Record<Extract<Entry, { type: "result" }>["status"], CallState>> = {
	ok: "done",
	"invalid-arguments": "failed",
	unavailable: "failed",
	"tool-error": "failed",
	interrupted: "stopped",
	stopped: "stopped",
	rejected: "rejected",
};

/** The files the edits and writes of `work` changed — a call's own among them — in the order they were first changed. */
function changesOf(work: readonly Work[]): readonly Changed[] {
	const changed = new Map<string, Changed>();
	const visit = (steps: readonly Work[]): void => {
		for (const step of steps) {
			if (step.kind !== "call") continue;
			if (step.aside?.kind === "change" && step.subject !== undefined) {
				const before = changed.get(step.subject);
				changed.set(step.subject, { path: step.subject, added: (before?.added ?? 0) + step.aside.added, removed: (before?.removed ?? 0) + step.aside.removed });
			}
			visit(step.calls);
		}
	};
	visit(work);
	return [...changed.values()];
}

/** What a call the person declined is marked: questions they dismissed, any other call they rejected. */
export function declinedText(call: CallLine): string {
	return call.work === "ask" ? "Dismissed" : "Rejected";
}

/** What streams of a request, read as the reply being written: each output item by its place, words as they grow. */
function writingOf(events: readonly unknown[]): Writing {
	const items = new Map<number, { readonly words: string } | { readonly id: string; readonly tool: string }>();
	for (const event of events) {
		if (matches(TextDeltaSchema, event)) {
			const item = items.get(event.output_index);
			items.set(event.output_index, { words: `${item !== undefined && "words" in item ? item.words : ""}${event.delta}` });
		} else if (matches(ItemEventSchema, event)) {
			if (matches(FunctionCallSchema, event.item)) items.set(event.output_index, { id: event.item.call_id, tool: event.item.name });
			else if (matches(AssistantMessageSchema, event.item)) items.set(event.output_index, { words: outputText(event.item.content) });
		}
	}
	const ordered = [...items].toSorted(([a], [b]) => a - b).map(([, item]) => item);
	return {
		words: ordered
			.flatMap((item) => ("words" in item ? [item.words] : []))
			.join("\n\n")
			.trim(),
		calls: ordered.flatMap((item) => ("tool" in item ? [item] : [])),
	};
}

/** How a turn stands, as its end says. */
function endingOf(turn: Turn): Ending {
	const end = turn.end;
	if (end === undefined) return { state: "working" };
	switch (end.outcome) {
		case "replied":
			return { state: "replied" };
		case "failed":
			return { state: "failed", why: end.reason ?? "The turn failed." };
		case "stopped":
			return { state: "stopped" };
	}
}

const WebSearchSchema = Type.Object({
	type: Type.Union([Type.Literal("web_search_call"), Type.Literal("openrouter:web_search")]),
	id: Type.Optional(Type.String()),
	action: Type.Optional(Type.Object({ query: Type.Optional(Type.String()) })),
});

/** The searches of the web a reply's provider ran, in the order it gave them, each by what it searched for. */
function searchesOf(response: unknown): readonly Work[] {
	if (!matches(OutputSchema, response)) return [];
	return response.output.flatMap((item, place): Work[] =>
		matches(WebSearchSchema, item) ? [{ kind: "web-search", key: item.id ?? `search-${String(place)}`, query: item.action?.query }] : [],
	);
}

const ReasoningSchema = Type.Object({
	type: Type.Literal("reasoning"),
	summary: Type.Optional(PartsSchema),
	content: Type.Optional(PartsSchema),
});
const TextPartSchema = Type.Object({ text: Type.String() });

/** What a reply says its model thought: its reasoning's summary, else the reasoning itself, as the provider gave it. */
function reasoningText(response: unknown): string {
	if (!matches(OutputSchema, response)) return "";
	return response.output
		.flatMap((item) => (matches(ReasoningSchema, item) ? [partsText(item.summary ?? []) || partsText(item.content ?? [])] : []))
		.join("\n\n")
		.trim();
}

/** The text of parts that hold text, one after another. */
function partsText(parts: readonly unknown[]): string {
	return parts
		.flatMap((part) => (matches(TextPartSchema, part) ? [part.text] : []))
		.join("\n\n")
		.trim();
}

const CallOutputSchema = Type.Object({ output: Type.Unknown() });

/** What a call's result told the model: its output's text, or the text of its parts. */
function outputOf(callOutput: unknown): string {
	if (!matches(CallOutputSchema, callOutput)) return "";
	const { output } = callOutput;
	if (typeof output === "string") return output;
	return Array.isArray(output) ? partsText(output) : "";
}

/** The words of a reply: its assistant messages' text. */
function replyText(response: unknown): string {
	if (!matches(OutputSchema, response)) return "";
	return response.output
		.flatMap((item) => (matches(AssistantMessageSchema, item) ? [outputText(item.content)] : []))
		.join("\n\n")
		.trim();
}

/** The text of an assistant message's parts. */
function outputText(parts: readonly unknown[]): string {
	return parts.flatMap((part) => (matches(OutputTextSchema, part) ? [part.text] : [])).join("");
}

/** The text of a message delivered: its text, or its text parts. */
export function inputText(message: unknown): string {
	if (!matches(InputMessageSchema, message)) return "";
	const { content } = message;
	if (typeof content === "string") return content.trim();
	return content
		.flatMap((part) => (matches(InputTextSchema, part) ? [part.text] : []))
		.join("\n")
		.trim();
}

/** The thread whose an input is, by its actor — `thread.<id>`; none for the person's. */
export function threadOfActor(actor: string): string | undefined {
	return actor.startsWith("thread.") ? actor.slice("thread.".length) : undefined;
}

/**
 * The words of a message a thread delivered: a task, its text; what came of a task given in the background, its parts
 * after the first — Siphon's note, the model's to read — none where the sub-thread said nothing, as it did not finish.
 */
function threadText(message: unknown): string {
	if (!matches(InputMessageSchema, message)) return "";
	const { content } = message;
	if (typeof content === "string") return content.trim();
	return content
		.slice(1)
		.flatMap((part) => (matches(InputTextSchema, part) ? [part.text] : []))
		.join("\n")
		.trim();
}

/** Why a request came to nothing, as its failed response says. */
function failureText(response: unknown): string {
	return matches(ErrorSchema, response) ? response.error.message : "The model's answer came to nothing.";
}

/** The words a turn's reply shows: its answer, and of the words being written, those whose blocks are whole. */
export function replyOf(turn: TimelineTurn): string {
	return [turn.answer?.text ?? "", settledOf(turn.writing.words)].filter((words) => words !== "").join("\n\n");
}

/** A thread's title where it has none: the start of its first words, as read. */
export function firstSaid(rows: readonly TimelineRow[]): string | undefined {
	return rows.flatMap((row) => (row.kind === "turn" ? row.turn.said : []))[0]?.text.split("\n")[0];
}
