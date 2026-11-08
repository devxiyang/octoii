/**
 * Where a thread's money and tokens went, as its log tells it: each request of its model — a step of a turn, or the
 * thread summed up as it grew too long — with what it did, its model, what it read and wrote, what it cost where its
 * provider said, and how long it took; laid as a waterfall, each starting where those before it left the total, by
 * cost or by tokens.
 */
import { type Call, type Conversation, matches, type Turn } from "@octoii-works/octoii-client";
import { placeOf } from "./timeline.ts";

/** A compaction of the thread's, as its log holds it. */
type Compaction = Conversation["compactions"][number];
import { Type } from "typebox";
import { mintedAt } from "./time.ts";
import { callWords } from "./tools.ts";

/**
 * A request spent: its key; the turn it was of, counted from one; what it did; its model; the tokens it read, of them
 * those from the cache, and those it wrote; what it cost in dollars, none where its provider said nothing; and how long
 * it took, in ms.
 */
export type Spent = {
	readonly key: string;
	readonly turn: number;
	readonly words: string;
	readonly model: string | undefined;
	readonly input: number;
	readonly cached: number;
	readonly output: number;
	readonly cost: number | undefined;
	readonly took: number;
};

const ResponseSchema = Type.Object({
	model: Type.Optional(Type.String()),
	usage: Type.Object({
		input_tokens: Type.Number(),
		output_tokens: Type.Number(),
		input_tokens_details: Type.Optional(Type.Object({ cached_tokens: Type.Optional(Type.Number()) })),
		cost: Type.Optional(Type.Number()),
	}),
});

/** The requests of `turns` and of the thread's `compactions` that told what they used, in the order they were made, each by the turn it falls in. */
export function spentOf(turns: readonly Turn[], compactions: readonly Compaction[]): readonly Spent[] {
	return [
		...turns.flatMap((turn, place) =>
			turn.steps.flatMap((step) =>
				step.reply === undefined ? [] : spentAs(step.request, step.reply.id, step.reply.response, place + 1, stepWords(step.calls)),
			),
		),
		...compactions.flatMap((compaction) =>
			spentAs(compaction.request, compaction.id, compaction.response, placeOf(turns, compaction.id) + 1, "Summed up the thread"),
		),
	].toSorted((a, b) => mintedAt(a.key) - mintedAt(b.key));
}

/** What a step's calls did, in words, as each went once it ran: its first call's, and how many more it made; that it answered, where it made none. */
function stepWords(calls: readonly Call[]): string {
	const [first] = calls;
	if (first === undefined) return "Answered";
	const words = callWords({ tool: first.name, arguments: first.arguments, state: "done" });
	return calls.length > 1 ? `${words} +${String(calls.length - 1)}` : words;
}

/** The request `key`, answered by the entry `answered` with `response`, as it was spent; none where it told nothing of what it used. */
function spentAs(key: string, answered: string, response: unknown, turn: number, words: string): readonly Spent[] {
	if (!matches(ResponseSchema, response)) return [];
	const { usage } = response;
	return [
		{
			key,
			turn,
			words,
			model: response.model,
			input: usage.input_tokens,
			cached: usage.input_tokens_details?.cached_tokens ?? 0,
			output: usage.output_tokens,
			cost: usage.cost,
			took: Math.max(0, mintedAt(answered) - mintedAt(key)),
		},
	];
}

/** What a waterfall is laid by: the dollars each request cost, or the tokens it read and wrote. */
export type Measure = "cost" | "tokens";

/** What `spent` amounts to by `measure`: its cost, nothing where none is known; or the tokens it read and wrote. */
export function amountOf(spent: Spent, measure: Measure): number {
	return measure === "cost" ? (spent.cost ?? 0) : spent.input + spent.output;
}

/** A request's bar on the waterfall: where it starts and how wide it is, each a share of the whole, from 0 to 1. */
export type Bar = { readonly start: number; readonly width: number };

/** Each request's bar, by `measure`: starting where those before it left the total. */
export function barsOf(spent: readonly Spent[], measure: Measure): readonly Bar[] {
	const whole = spent.reduce((sum, each) => sum + amountOf(each, measure), 0);
	let before = 0;
	return spent.map((each) => {
		const amount = amountOf(each, measure);
		const bar = whole === 0 ? { start: 0, width: 0 } : { start: before / whole, width: amount / whole };
		before += amount;
		return bar;
	});
}

/** The request that took the most by `measure`; none where none took anything. */
export function mostOf(spent: readonly Spent[], measure: Measure): Spent | undefined {
	return spent.reduce<Spent | undefined>(
		(most, each) => (amountOf(each, measure) > (most === undefined ? 0 : amountOf(most, measure)) ? each : most),
		undefined,
	);
}
