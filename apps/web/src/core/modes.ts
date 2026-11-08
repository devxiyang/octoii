/**
 * The modes a thread runs in, as the page names them: how each lets the thread's calls go ahead — what goes ahead on
 * its own and what is judged first, by the person or by a second model — and auto offered only once the environment
 * names a model to judge its calls.
 */
import type { Mode } from "@octoii-works/octoii-client";

/** A mode as the page shows it: its name and what it lets the thread do. */
export type ModeShown = { readonly label: string; readonly description: string };

/** The modes, from the one that keeps the work in most to the one that keeps it in least. */
export const MODES: readonly Mode[] = ["default", "auto", "full-access"];

const SHOWN: Readonly<Record<Mode, ModeShown>> = {
	default: { label: "Default", description: "Edit the workspace and run commands in a sandbox that writes it alone; ask to go beyond it." },
	auto: { label: "Auto", description: "A second model judges what would ask; you decide where it doubts." },
	"full-access": { label: "Full access", description: "Edit and run anything without asking, outside any sandbox." },
};

/** How the page shows `mode`. */
export function modeShown(mode: Mode): ModeShown {
	return SHOWN[mode];
}

/** Whether a thread may be set to `mode`, the environment naming `reviewModel` to judge calls: auto only where it names one. */
export function modeOffered(mode: Mode, reviewModel: string | undefined): boolean {
	return mode !== "auto" || reviewModel !== undefined;
}

/** What a mode lets go ahead on its own, and what it judges first — by whom, and what. */
export type ModeRules = { readonly own: readonly string[]; readonly judged: { readonly by: string; readonly what: readonly string[] } };

const RULES: Readonly<Record<Mode, ModeRules>> = {
	default: {
		own: ["Edits in the workspace", "Commands in the sandbox, which write the workspace and the temporary folders alone", "Reading anywhere"],
		judged: { by: "Asks you first", what: ["Edits beyond the workspace", "Commands that must go beyond the sandbox", "Tools of MCP servers"] },
	},
	auto: {
		own: ["Edits in the workspace", "Commands that only read", "Reading anywhere"],
		judged: { by: "Judged first by the review model", what: ["Every other call — it goes ahead or is blocked, and you decide where the model doubts"] },
	},
	"full-access": {
		own: ["Every call, outside any sandbox"],
		judged: { by: "Asks you first", what: [] },
	},
};

/** What `mode` lets go ahead on its own, and what it judges first. */
export function rulesOf(mode: Mode): ModeRules {
	return RULES[mode];
}
