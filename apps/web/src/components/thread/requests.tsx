/**
 * Where a thread's money and tokens went, unfolded under its overview's usage row: its totals — what it cost, what its
 * requests read and wrote, the request that took the most — over a waterfall of its requests, turn by turn, each a bar
 * starting where those before it left the total, by cost or by tokens as the switch says, with what it did, its model,
 * what it read and wrote, what it cost and how long it took; what its log tells nothing of — the review model's
 * verdicts, a title made, turns not read yet — as a line of its own at the end. The waterfall keeps its columns'
 * widths, scrolled sideways where its room is narrower.
 */
import { type ReactNode, useState } from "react";
import type { Conversation, Turn, Usage } from "@octoii-works/octoii-client";
import { modelLabel } from "../../core/models.ts";
import { dollars, tokens } from "../../core/numbers.ts";
import { amountOf, barsOf, type Measure, mostOf, type Spent, spentOf } from "../../core/spending.ts";
import { callDuration } from "../../core/time.ts";
import { useDirectory } from "../composer/directory.ts";
import { cn } from "../ui/cn.ts";
import { Segmented } from "../ui/segmented.tsx";

/** The columns of a request's line: what it did, its bar, what it read and wrote, what it cost, how long it took. */
const COLUMNS = "grid grid-cols-[minmax(0,1fr)_7.5rem_3.25rem_3.25rem_4.5rem_3.25rem] items-center gap-x-3";

/** The least of a dollar, and of a token, that counts as some. */
const SOME = { cost: 1e-6, tokens: 1 } as const;

/** The waterfall of the thread's requests, by `usage`, all it used, and its `turns`, as far as they were read. */
export function Requests(props: { readonly usage: Usage; readonly turns: readonly Turn[]; readonly compactions: Conversation["compactions"] }): ReactNode {
	const directory = useDirectory();
	const { usage } = props;
	const [chosen, setChosen] = useState<Measure | undefined>(undefined);
	const measure = chosen ?? (usage.cost_nanodollars > 0 ? "cost" : "tokens");
	const logged = spentOf(props.turns, props.compactions);
	const rest = restOf(usage, logged);
	const spent = rest === undefined ? logged : [...logged, rest];
	const bars = barsOf(spent, measure);
	const most = mostOf(logged, measure);
	const cost = usage.cost_nanodollars / 1e9;
	return (
		<div className="flex flex-col gap-1 pt-1 pb-2">
			<div className="grid grid-cols-3 divide-x divide-border">
				<Total title="Total cost" value={cost > 0 ? dollars(cost) : "Not told"} />
				<Total
					title="Total tokens"
					value={tokens(usage.input_tokens + usage.output_tokens)}
					aside={`${tokens(usage.input_tokens)} in · ${tokens(usage.output_tokens)} out`}
				/>
				<Total title="Took the most" value={most?.words ?? "Nothing yet"} aside={most === undefined ? undefined : amountText(most, measure)} />
			</div>
			<div className="flex items-center gap-3 px-2 pt-2">
				<span className="label-caps">Requests</span>
				<Segmented
					label="Lay the requests by"
					value={measure}
					onValueChange={setChosen}
					items={[
						{ value: "cost", label: "Cost" },
						{ value: "tokens", label: "Tokens" },
					]}
					className="ms-auto w-40"
				/>
			</div>
			<div className="overflow-x-auto">
				<div className="min-w-[36rem]">
					<div className={cn(COLUMNS, "label-caps px-2 pt-1.5 pb-1.5")}>
						<span>Request</span>
						<span className="flex justify-between tracking-normal normal-case tabular-nums">
							<span>0</span>
							<span>
								{measure === "cost"
									? dollars(spent.reduce((sum, each) => sum + (each.cost ?? 0), 0))
									: tokens(spent.reduce((sum, each) => sum + amountOf(each, "tokens"), 0))}
							</span>
						</span>
						<span className="text-end">In</span>
						<span className="text-end">Out</span>
						<span className="text-end">Cost</span>
						<span className="text-end">Time</span>
					</div>
					{spent.map((each, index) => (
						<Request
							key={each.key}
							spent={each}
							bar={bars[index] ?? { start: 0, width: 0 }}
							model={each.model === undefined ? undefined : modelLabel(each.model, directory)}
							heading={index === 0 || spent[index - 1]?.turn !== each.turn ? headingOf(each) : undefined}
							top={each === most}
						/>
					))}
				</div>
			</div>
			{spent.length === 0 ? <p className="px-2 py-3 text-ui text-muted-foreground">No request has told what it used yet.</p> : null}
		</div>
	);
}

/** One of the totals: its title over its value, and what it is made of beside. */
function Total(props: { readonly title: string; readonly value: string; readonly aside?: string | undefined }): ReactNode {
	return (
		<div className="flex min-w-0 flex-col gap-0.5 px-2 py-1.5">
			<span className="label-caps">{props.title}</span>
			<span className="truncate text-ui font-medium tabular-nums">{props.value}</span>
			{props.aside === undefined ? null : <span className="truncate text-xs text-muted-foreground tabular-nums">{props.aside}</span>}
		</div>
	);
}

/** A request's line, under the heading of its turn where it is the turn's first. */
function Request(props: {
	readonly spent: Spent;
	readonly bar: { readonly start: number; readonly width: number };
	readonly model: string | undefined;
	readonly heading: string | undefined;
	readonly top: boolean;
}): ReactNode {
	const { spent, bar } = props;
	return (
		<>
			{props.heading === undefined ? null : <p className="px-2 pt-2.5 pb-1 text-xs text-muted-foreground">{props.heading}</p>}
			<div className={cn(COLUMNS, "rounded-md px-2 py-1 text-xs hover:bg-accent")}>
				<span className="flex min-w-0 items-center gap-1.5">
					<span className="truncate text-foreground">{spent.words}</span>
					{props.model === undefined ? null : <span className="shrink-0 truncate text-muted-foreground">{props.model}</span>}
					{props.top ? <span className="shrink-0 rounded-sm bg-warning-surface px-1 text-2xs font-medium text-warning-foreground">Most</span> : null}
				</span>
				<span className="relative h-2.5 rounded-sm bg-muted">
					<span
						className="absolute inset-y-0 min-w-0.5 rounded-sm bg-info"
						style={{ left: `${String(bar.start * 100)}%`, width: `${String(bar.width * 100)}%` }}
					/>
				</span>
				<span className="text-end text-muted-foreground tabular-nums">{tokens(spent.input)}</span>
				<span className="text-end text-muted-foreground tabular-nums">{tokens(spent.output)}</span>
				<span className="text-end tabular-nums">{spent.cost === undefined ? "–" : dollars(spent.cost)}</span>
				<span className="text-end text-muted-foreground tabular-nums">{spent.turn === 0 ? "" : (callDuration(spent.took) ?? "<0.1s")}</span>
			</div>
		</>
	);
}

/** What a request amounts to by `measure`, written. */
function amountText(spent: Spent, measure: Measure): string {
	return measure === "cost" ? (spent.cost === undefined ? "–" : dollars(spent.cost)) : `${tokens(amountOf(spent, measure))} tokens`;
}

/** The heading of the turn a request was of; of what the log tells nothing of, its own. */
function headingOf(spent: Spent): string {
	return spent.turn === 0 ? "Not in the log read" : `Turn ${String(spent.turn)}`;
}

/**
 * What the thread used that its log, as far as it was read, tells nothing of — the review model's verdicts, a title
 * made, turns not read yet — as a request of its own, of turn none; none where the log tells of it all.
 */
function restOf(usage: Usage, logged: readonly Spent[]): Spent | undefined {
	const sum = (of: (each: Spent) => number): number => logged.reduce((total, each) => total + of(each), 0);
	const cost = usage.cost_nanodollars / 1e9 - sum((each) => each.cost ?? 0);
	const input = Math.max(0, usage.input_tokens - sum((each) => each.input));
	const output = Math.max(0, usage.output_tokens - sum((each) => each.output));
	if (cost < SOME.cost && input + output < SOME.tokens) return undefined;
	return {
		key: "rest",
		turn: 0,
		words: "Reviews, titles and turns not read",
		model: undefined,
		input,
		cached: 0,
		output,
		cost: cost < SOME.cost ? undefined : cost,
		took: 0,
	};
}
