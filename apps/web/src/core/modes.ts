/**
 * The modes a thread runs in, as the page names them, each in a few words of what it lets the thread do; auto offered
 * only once the environment names a model to judge its calls.
 */
import type { Mode } from "@octoii-works/octoii-client";

/** A mode as the page shows it: its name, and in a few words what it lets the thread do. */
export type ModeShown = { readonly label: string; readonly description: string };

/** The modes, from the one that keeps the work in most to the one that keeps it in least. */
export const MODES: readonly Mode[] = ["default", "auto", "full-access"];

const SHOWN: Readonly<Record<Mode, ModeShown>> = {
	default: { label: "Default", description: "Asks before leaving the sandbox" },
	auto: { label: "Auto", description: "A model reviews what would ask" },
	"full-access": { label: "Full access", description: "Runs anything without asking" },
};

/** How the page shows `mode`. */
export function modeShown(mode: Mode): ModeShown {
	return SHOWN[mode];
}

/** Whether a thread may be set to `mode`, the environment naming `reviewModel` to judge calls: auto only where it names one. */
export function modeOffered(mode: Mode, reviewModel: string | undefined): boolean {
	return mode !== "auto" || reviewModel !== undefined;
}
