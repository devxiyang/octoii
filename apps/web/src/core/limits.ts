/**
 * A thread its model's quota limits, as the page shows it: the window the quota is counted over, in words; and the
 * other accounts of the same provider it may go on with — connected, their quota not used up, serving the same model.
 */
import type { Limited, Provider } from "@octoii-works/octoii-client";
import { type Directory, isConnected, referenceOf } from "./models.ts";

/** The window a quota is counted over, as a person names it — "5-hour", "weekly" — none where it is not known. */
export function windowWords(minutes: number | undefined): string | undefined {
	if (minutes === undefined) return undefined;
	if (minutes === 7 * 24 * 60) return "weekly";
	if (minutes % 60 === 0) return `${String(minutes / 60)}-hour`;
	return `${String(minutes)}-minute`;
}

/** The host's provider a provider is an account of: the one it is another account of, or itself. */
function baseOf(provider: Provider): string {
	return provider.account?.of ?? provider.id;
}

/** Another account a limited thread may go on with: its provider, and its reference of the thread's model. */
export type Onward = { readonly provider: Provider; readonly reference: string };

/** The other accounts of the provider `limited` names that a thread of `model` may go on with, in the node's order. */
export function onwardOf(directory: Directory, limited: Limited, model: string): readonly Onward[] {
	const own = directory.providers.find((each) => each.id === limited.provider);
	if (own === undefined) return [];
	const base = baseOf(own);
	const id = model.slice(model.indexOf("/") + 1);
	return directory.providers.flatMap((provider) => {
		if (provider.id === own.id || baseOf(provider) !== base || !isConnected(provider) || provider.used_up !== undefined) return [];
		const reference = `${provider.id}/${id}`;
		return directory.models.some((each) => referenceOf(each) === reference) ? [{ provider, reference }] : [];
	});
}
