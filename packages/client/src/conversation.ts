/**
 * A thread as the interface shows it, put together by the ids that tie its parts: its turns, each the inputs it took,
 * the model's requests it made — what streamed of each while it was answered, the reply or the failure that came of it
 * — and the calls each reply made, each with the fiber that runs it, the result it came to, and the calls made under
 * it, as a script makes them, each the same; and the requests that wait on the person. The log says what happened and
 * the state what is happening now, by the same ids: a turn's fiber key, a request's key, a call's id. A thread's turns
 * follow one another, each a run of the log from its inputs to its end, as its main fiber runs one turn at a time.
 *
 * A turn that ended never changes: it is put together once and kept, the same object from one view of the thread to
 * the next. The turn that runs is put together again only as its run of the log grows; what the state and the streams
 * say of it is laid over it, each part they change copied and every other part kept, so a reader that keeps what it
 * made of a part makes it again only where the part changed.
 */
import { Type } from "typebox";
import {
	type Entry,
	FunctionCallSchema,
	type Inbound,
	MODEL_REQUEST,
	type OpenRequest,
	type Process,
	PROGRAMS,
	type PageListed,
	type Status,
	type TerminalListed,
	TOOL_REQUEST,
} from "./protocol.ts";
import { compiled } from "./std/schema.ts";
import type { ThreadView } from "./thread.ts";

type Of<Kind extends Entry["type"]> = Extract<Entry, { type: Kind }>;

/**
 * A call: its id, its tool and its arguments; the fiber that runs it, while it runs, and what its tool tells as it
 * runs — a command's output; its result, once it came; and the calls made under it, as a script makes them.
 */
export type Call = {
	readonly id: string;
	readonly name: string;
	readonly arguments: string;
	readonly fiber: Process | undefined;
	/** What streamed of its tool's request while it runs, in the order it came. */
	readonly streaming: readonly unknown[];
	readonly result: Of<"result"> | undefined;
	readonly calls: readonly Call[];
};

/** A request a turn made of its model: its key; what streamed while it was answered; the reply or failure that came of it. */
export type Step = {
	readonly request: string;
	readonly streaming: readonly unknown[];
	readonly reply: Of<"reply"> | undefined;
	readonly failure: Of<"failure"> | undefined;
	readonly calls: readonly Call[];
};

/** A turn: its fiber's key, once known; what its model was told as it began; its inputs; its steps; its end, once it ended. */
export type Turn = {
	readonly id: string | undefined;
	readonly told: readonly Of<"system">[];
	readonly inputs: readonly Of<"input">[];
	readonly steps: readonly Step[];
	readonly end: Of<"turn-end"> | undefined;
};

/**
 * A request that waits on the person: the fiber that made it; the call it is made for, by its id — the call's own
 * fiber's, or that of a program the call runs — none for one no call made; and the request, its key and name, what it
 * asks and the form the answer takes.
 */
export type Ask = { readonly fiber: string; readonly call: string | undefined; readonly request: OpenRequest };

/** A thread as the interface shows it. */
export type Conversation = {
	/** Its turns, from the earliest the client holds: the first may be begun before the entries held reach back. */
	readonly turns: readonly Turn[];
	/**
	 * Its compactions, in the order of its log: the thread's, none a turn's own — made as a turn's window filled, or as
	 * the person asked, at rest or while a turn ran — each placed by its id, as every entry's is minted in order.
	 */
	readonly compactions: readonly Of<"compaction">[];
	/** Whether its latest entries were read: till they are, it holds none, though the thread may. */
	readonly read: boolean;
	/** Whether the turns reach the log's start: none is left to read further back. */
	readonly complete: boolean;
	readonly asks: readonly Ask[];
	/** The inputs that wait in its inbox for its next turn, in the order they came. */
	readonly inbox: readonly Inbound[];
	readonly status: Status | undefined;
	/** Its terminals, in the order they were opened. */
	readonly terminals: readonly TerminalListed[];
	/** Its pages in the browser, in the order they were opened. */
	readonly pages: readonly PageListed[];
};

const OutputSchema = Type.Object({ output: Type.Array(Type.Unknown()) });
const CallOutputSchema = Type.Object({ call_id: Type.String() });
const CallInputSchema = Type.Object({ call_id: Type.String(), name: Type.String(), arguments: Type.String() });

/** A call, a step and a turn as a run of the log is put together. */
type BuildingCall = {
	id: string;
	name: string;
	arguments: string;
	fiber: Process | undefined;
	streaming: readonly unknown[];
	result: Of<"result"> | undefined;
	calls: BuildingCall[];
};
type BuildingStep = {
	request: string;
	streaming: readonly unknown[];
	reply: Of<"reply"> | undefined;
	failure: Of<"failure"> | undefined;
	calls: BuildingCall[];
};
type BuildingTurn = {
	id: string | undefined;
	told: Of<"system">[];
	inputs: Of<"input">[];
	steps: BuildingStep[];
	end: Of<"turn-end"> | undefined;
};

/** What streamed of a request nothing streamed of: one for all, as a part that is the same is the same object. */
const NOTHING_STREAMED: readonly unknown[] = [];

/** Each view's conversation, made once: a view is the same object until its thread changes. */
const made = new WeakMap<ThreadView, Conversation>();

/**
 * Each run of the log put together, by its last entry, with its first and how many entries it holds: a run is the same
 * where it begins and ends with the same entries and holds as many, as the log is appended to alone — a turn that ended
 * by its end, the turn that runs before what the state and the streams say of it.
 */
const runs = new WeakMap<Entry, { readonly first: Entry; readonly length: number; readonly turn: Turn | undefined }>();

/** The conversation of a thread as `view` holds it. */
export function conversationOf(view: ThreadView): Conversation {
	const known = made.get(view);
	if (known !== undefined) return known;
	const processes = view.state?.processes ?? [];
	const fibers = callFibers(processes);
	const turns = turnsOf(view.entries);
	const last = turns.at(-1);
	if (last !== undefined && last.end === undefined) turns[turns.length - 1] = running(last, processes, fibers, view.streaming);
	const callOf = new Map([...fibers].map(([id, fiber]) => [fiber.key, id]));
	const asks = processes.flatMap((process) =>
		process.requests
			.filter((request) => request.answer !== undefined)
			.map((request) => ({
				fiber: process.key,
				call: callOf.get(process.key) ?? (process.parent === undefined ? undefined : callOf.get(process.parent)),
				request,
			})),
	);
	const conversation: Conversation = {
		turns,
		compactions: view.entries.filter((entry): entry is Of<"compaction"> => entry.type === "compaction"),
		read: view.read,
		complete: view.complete,
		asks,
		inbox: view.state?.inbox ?? [],
		status: view.state?.status,
		terminals: view.terminals,
		pages: view.pages,
	};
	made.set(view, conversation);
	return conversation;
}

/** The turns the log's `entries` hold: each run through a turn's end its turn, and the run after the last end the turn that runs, where it holds one. */
function turnsOf(entries: readonly Entry[]): Turn[] {
	const turns: Turn[] = [];
	let from = 0;
	entries.forEach((entry, at) => {
		if (entry.type !== "turn-end") return;
		const turn = runOf(entries, from, at);
		if (turn !== undefined) turns.push(turn);
		from = at + 1;
	});
	const runningTurn = from < entries.length ? runOf(entries, from, entries.length - 1) : undefined;
	if (runningTurn !== undefined) turns.push(runningTurn);
	return turns;
}

/** The turn the run of `entries` from `from` through `through` holds, as it was put together where the run is the same; none where it holds none. */
function runOf(entries: readonly Entry[], from: number, through: number): Turn | undefined {
	const first = entries[from];
	const last = entries[through];
	if (first === undefined || last === undefined) return undefined;
	const length = through - from + 1;
	const known = runs.get(last);
	if (known !== undefined && known.first === first && known.length === length) return known.turn;
	const turn = turnOf(entries.slice(from, through + 1));
	runs.set(last, { first, length, turn });
	return turn;
}

/** The turn a run of the log's entries holds, from its inputs to its end — what its model was told before them its own; none where the run holds none. */
function turnOf(run: readonly Entry[]): Turn | undefined {
	const told: Of<"system">[] = [];
	let turn: BuildingTurn | undefined;
	// The calls of the turn by their ids, at whatever depth: each result settles one, each call made under one goes under it.
	const calls = new Map<string, BuildingCall>();
	const open = (): BuildingTurn => {
		turn ??= { id: undefined, told, inputs: [], steps: [], end: undefined };
		return turn;
	};
	for (const entry of run) {
		switch (entry.type) {
			case "system":
				// What a turn's model is told as it begins comes before its inputs, and is told anew within it after a recap:
				// the turn's either way, as it takes what was told before it opened.
				told.push(entry);
				break;
			case "input":
				open().inputs.push(entry);
				break;
			case "reply": {
				const step = stepOf(open(), entry.request);
				step.reply = entry;
				step.calls = callsOf(entry.response);
				for (const call of step.calls) calls.set(call.id, call);
				break;
			}
			case "calls": {
				open();
				const under = calls.get(entry.under);
				for (const call of entry.calls) {
					const building: BuildingCall = {
						id: call.call_id,
						name: call.name,
						arguments: call.arguments,
						fiber: undefined,
						streaming: NOTHING_STREAMED,
						result: undefined,
						calls: [],
					};
					under?.calls.push(building);
					calls.set(building.id, building);
				}
				break;
			}
			case "failure":
				stepOf(open(), entry.request).failure = entry;
				break;
			case "compaction":
				// The thread's, not the turn's: the conversation holds it, placed by its id.
				break;
			case "result": {
				open();
				const output = compiled(CallOutputSchema);
				const call = output.Check(entry.call_output) ? calls.get(entry.call_output.call_id) : undefined;
				if (call !== undefined) call.result = entry;
				break;
			}
			case "turn-end": {
				const ended = open();
				ended.end = entry;
				ended.id = entry.turn;
				break;
			}
			case "configuration":
				// How hard the model reasons is the thread's manifest's to show; the log keeps where it was told.
				break;
		}
	}
	return turn;
}

/** The step of the request `request` in `turn`, made where the turn has none yet. */
function stepOf(turn: BuildingTurn, request: string): BuildingStep {
	const found = turn.steps.find((step) => step.request === request);
	if (found !== undefined) return found;
	const step: BuildingStep = { request, streaming: NOTHING_STREAMED, reply: undefined, failure: undefined, calls: [] };
	turn.steps.push(step);
	return step;
}

/** The calls a reply's response made, in the order its model made them. */
function callsOf(response: unknown): BuildingCall[] {
	const output = compiled(OutputSchema);
	if (!output.Check(response)) return [];
	const call = compiled(FunctionCallSchema);
	return response.output.flatMap((item) =>
		call.Check(item)
			? [{ id: item.call_id, name: item.name, arguments: item.arguments, fiber: undefined, streaming: NOTHING_STREAMED, result: undefined, calls: [] }]
			: [],
	);
}

/** The fiber of each call that runs, by the call's id, at whatever depth: the model's, and those made under them. */
function callFibers(processes: readonly Process[]): ReadonlyMap<string, Process> {
	const input = compiled(CallInputSchema);
	return new Map(processes.flatMap((process) => (process.program === PROGRAMS.call && input.Check(process.input) ? [[process.input.call_id, process]] : [])));
}

/**
 * The turn that runs, as the state and the streams say of it: its fiber's key, the requests it waits on its model for
 * as steps of their own, what streamed of each, and each call's fiber — each part they change copied, every other kept.
 */
function running(turn: Turn, processes: readonly Process[], fibers: ReadonlyMap<string, Process>, streaming: ReadonlyMap<string, readonly unknown[]>): Turn {
	const fiber = processes.find((process) => process.program === PROGRAMS.turn);
	const steps = keptWhereSame(turn.steps, (step) => runningStep(step, fibers, streaming));
	const asked = (fiber?.requests ?? []).filter((request) => request.name === MODEL_REQUEST && !turn.steps.some((step) => step.request === request.key));
	const added = asked.map((request) => ({
		request: request.key,
		streaming: streaming.get(request.key) ?? NOTHING_STREAMED,
		reply: undefined,
		failure: undefined,
		calls: [],
	}));
	const id = fiber?.key ?? turn.id;
	if (steps === turn.steps && added.length === 0 && id === turn.id) return turn;
	return { ...turn, id, steps: [...steps, ...added] };
}

/** A step of the turn that runs, as the streams and the state say of it: what streamed of its request, and its calls as they run. */
function runningStep(step: Step, fibers: ReadonlyMap<string, Process>, streaming: ReadonlyMap<string, readonly unknown[]>): Step {
	const streamed = streaming.get(step.request) ?? step.streaming;
	const calls = keptWhereSame(step.calls, (call) => runningCall(call, fibers, streaming));
	return streamed === step.streaming && calls === step.calls ? step : { ...step, streaming: streamed, calls };
}

/**
 * A call of the turn that runs: with its fiber while it has no result, and what streamed of its tool's request, which
 * its fiber waits on; the calls made under it the same.
 */
function runningCall(call: Call, fibers: ReadonlyMap<string, Process>, streaming: ReadonlyMap<string, readonly unknown[]>): Call {
	const fiber = call.result === undefined ? fibers.get(call.id) : undefined;
	const asked = fiber?.requests.find((request) => request.name === TOOL_REQUEST);
	const streamed = (asked === undefined ? undefined : streaming.get(asked.key)) ?? NOTHING_STREAMED;
	const calls = keptWhereSame(call.calls, (inner) => runningCall(inner, fibers, streaming));
	return fiber === call.fiber && streamed === call.streaming && calls === call.calls ? call : { ...call, fiber, streaming: streamed, calls };
}

/** `parts`, each as `next` makes it: the same array where it made each the same. */
function keptWhereSame<Part>(parts: readonly Part[], next: (part: Part) => Part): readonly Part[] {
	let changed = false;
	const made = parts.map((part) => {
		const remade = next(part);
		if (remade !== part) changed = true;
		return remade;
	});
	return changed ? made : parts;
}
