/**
 * What fills a thread's window as its details show it: each part by its words and the hue it is drawn in — what
 * Octoii tells the model drawn neutral, the rest each in a hue of its own — its share of the window its model takes,
 * and whether the thread compacts now, as its process table shows its one compaction running.
 */
import { COMPACT_PROGRAM, type Composition, type ContextPart, type Listed } from "@octoii-works/octoii-client";
import type { MONOGRAM_HUES } from "./monogram.ts";

/** Each part's words, and its hue — none for what Octoii tells the model, drawn neutral. */
export const PARTS: Readonly<Record<ContextPart, { readonly label: string; readonly hue: (typeof MONOGRAM_HUES)[number] | undefined }>> = {
	system: { label: "System", hue: undefined },
	instructions: { label: "Instructions", hue: "amber" },
	skills: { label: "Skills", hue: "violet" },
	catalog: { label: "MCP tools", hue: "cyan" },
	tools: { label: "Tool definitions", hue: "indigo" },
	recap: { label: "Recap", hue: "orange" },
	messages: { label: "Your messages", hue: "blue" },
	replies: { label: "Replies", hue: "emerald" },
	results: { label: "Tool results", hue: "rose" },
};

/** A part's share of a window: its tokens, and the fraction of the window they take. */
export type PartShare = { readonly part: ContextPart; readonly tokens: number; readonly fraction: number };

/** The parts of `composition` as shares of a window of `window` tokens, in the order it gives them. */
export function sharesOf(composition: Composition, window: number): readonly PartShare[] {
	return composition.parts.map((share) => ({ ...share, fraction: window > 0 ? share.tokens / window : 0 }));
}

/** Whether the thread compacts now: its one compaction running, as its process table shows it. */
export function isCompacting(row: Listed | undefined): boolean {
	return row?.state.processes.some((process) => process.program === COMPACT_PROGRAM && process.state !== "zombie") ?? false;
}
