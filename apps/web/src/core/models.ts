/**
 * The models a thread can run with, as its picker lists them: the text models of the node's providers that are
 * connected — those that hold a credential, and the servers, whose models are listed only as they answer — by
 * provider, the newest first, those whose name or id holds the search; each with its reference and its context; the
 * person's starred models, and the models the newest threads chose.
 */
import type { Effort, Listed, Model, Provider } from "@octoii-works/octoii-client";
import { tokens } from "./numbers.ts";

/** What the picker draws on: the models the node lists, and its providers, each with how it is connected. */
export type Directory = { readonly models: readonly Model[]; readonly providers: readonly Provider[] };

/**
 * Whether a provider's models may be chosen: it holds a credential, or it is a server or reached through an agent, whose
 * models are listed as it answers.
 */
export function isConnected(provider: Provider): boolean {
	return provider.connects === "server" || provider.connects === "agent" || provider.credential !== undefined;
}

/** A model as the picker offers it. */
export type ModelChoice = { readonly reference: string; readonly name: string; readonly context?: string };

/** A provider's models in the picker. */
export type ProviderModels = { readonly provider: string; readonly models: readonly ModelChoice[] };

/** A model's reference, as a thread names it: its provider and its id there. */
export function referenceOf(model: Model): string {
	return `${model.octoii.provider}/${model.id}`;
}

/** The provider of a model's reference. */
export function providerOf(reference: string): string {
	return reference.slice(0, Math.max(0, reference.indexOf("/")));
}

/** The text models a person can choose, by provider in the node's order, the newest first, those matching `search`. */
export function modelChoices(directory: Directory, search: string): readonly ProviderModels[] {
	const wanted = search.trim().toLowerCase();
	const connected = new Set(directory.providers.flatMap((provider) => (isConnected(provider) ? [provider.id] : [])));
	const groups = new Map<string, Model[]>();
	for (const model of directory.models) {
		const { provider } = model.octoii;
		if (!connected.has(provider)) continue;
		if (wanted !== "" && !`${model.name} ${model.id}`.toLowerCase().includes(wanted)) continue;
		groups.set(provider, [...(groups.get(provider) ?? []), model]);
	}
	return [...groups].map(([provider, models]) => ({
		provider,
		models: models.toSorted((a, b) => (b.octoii.release_date ?? "").localeCompare(a.octoii.release_date ?? "")).map(choiceOf),
	}));
}

/** A model's choice: its reference, name and context. */
function choiceOf(model: Model): ModelChoice {
	return {
		reference: referenceOf(model),
		name: model.name,
		...(model.context_length === undefined ? {} : { context: tokens(model.context_length) }),
	};
}

/**
 * A model as a chip names it: its name without the maker a name may lead with, as in "DeepSeek: DeepSeek V4.1 Flash",
 * else its id without its provider.
 */
export function modelLabel(reference: string, directory: Directory | undefined): string {
	const name = directory?.models.find((model) => referenceOf(model) === reference)?.name;
	return name === undefined ? reference.slice(reference.lastIndexOf("/") + 1) : shortName(name);
}

/** A model's name without the maker it may lead with, as in "Anthropic: Claude Opus 5.5". */
export function shortName(name: string): string {
	return name.slice(name.indexOf(": ") + 1).trim();
}

/** A provider's name, as the node gives it; its id where it gives none. */
export function providerName(directory: Directory | undefined, id: string): string {
	return directory?.providers.find((provider) => provider.id === id)?.name ?? id;
}

/** A section of the model dialog: its title, and its models, each by its choice. */
export type ModelSection = { readonly title: string; readonly models: readonly ModelChoice[] };

/** What the dialog's sections draw on: the directory, the search, and the starred and recent models. */
export type SectionsOf = {
	readonly directory: Directory;
	readonly search: string;
	readonly favorites: readonly string[];
	readonly recent: readonly string[];
};

/**
 * The model dialog's sections: with nothing searched, the starred models, then the recent ones, then each provider's;
 * searching, each provider's that match. A model may stand in a first section and its provider's both.
 */
export function modelSections(of: SectionsOf): readonly ModelSection[] {
	const groups = modelChoices(of.directory, of.search);
	const providers = groups.map((group) => ({ title: providerName(of.directory, group.provider), models: group.models }));
	if (of.search.trim() !== "") return providers;
	const all = new Map(groups.flatMap((group) => group.models).map((model) => [model.reference, model]));
	const picked = (references: readonly string[]): readonly ModelChoice[] => references.flatMap((reference) => all.get(reference) ?? []);
	return [
		{ title: "Favorites", models: picked(of.favorites) },
		{ title: "Recent", models: picked(of.recent.filter((reference) => !of.favorites.includes(reference))) },
		...providers,
	].filter((section) => section.models.length > 0);
}

/** The most recent models kept. */
export const RECENT_MODELS = 10;

/** The models the threads run with, as the newest threads chose them, `rows` newest first: each once, at most `RECENT_MODELS`. */
export function recentModelsOf(rows: readonly Listed[]): readonly string[] {
	const recent: string[] = [];
	for (const row of rows) {
		const { model } = row.manifest;
		if (model !== undefined && !recent.includes(model)) recent.push(model);
		if (recent.length === RECENT_MODELS) break;
	}
	return recent;
}

/** The starred models with `reference` starred, or no longer where it was. */
export function toggledFavorite(favorites: readonly string[], reference: string): readonly string[] {
	return favorites.includes(reference) ? favorites.filter((each) => each !== reference) : [...favorites, reference];
}

/** The model a reference names in the directory, where it lists it. */
export function modelOf(directory: Directory | undefined, reference: string | undefined): Model | undefined {
	if (directory === undefined || reference === undefined) return undefined;
	return directory.models.find((model) => referenceOf(model) === reference);
}

/** Every effort, highest first. */
const EFFORTS: readonly Effort[] = ["max", "xhigh", "high", "medium", "low", "minimal", "none"];

/** The efforts offered where a model that reasons lists none: the node fits each to the nearest it takes. */
const OFFERED: readonly Effort[] = ["high", "medium", "low"];

/** Whether a model reasons: it takes the `reasoning` parameter, or says how it reasons. */
function reasons(model: Model): boolean {
	return model.reasoning !== undefined || (model.supported_parameters?.includes("reasoning") ?? false);
}

/**
 * The efforts a person may choose for a model, highest first: those it lists, else high, medium and low — `none`
 * where it may reason not at all; none for a model that does not reason, or that the directory does not list.
 */
export function effortsOf(model: Model | undefined): readonly Effort[] {
	if (model === undefined || !reasons(model)) return [];
	const listed = model.reasoning?.supported_efforts;
	if (listed !== undefined && listed.length > 0) return EFFORTS.filter((effort) => listed.includes(effort));
	return model.reasoning?.mandatory === true ? OFFERED : [...OFFERED, "none"];
}

/** An effort as the person reads it. */
export function effortLabel(effort: Effort): string {
	switch (effort) {
		case "max":
			return "Max";
		case "xhigh":
			return "Extra high";
		case "high":
			return "High";
		case "medium":
			return "Medium";
		case "low":
			return "Low";
		case "minimal":
			return "Minimal";
		case "none":
			return "No reasoning";
	}
}

/** The effort after `effort` among `efforts`, as a shortcut steps through them, from the highest again after the lowest. */
export function nextEffort(efforts: readonly Effort[], effort: Effort | undefined): Effort | undefined {
	if (efforts.length === 0) return undefined;
	const at = effort === undefined ? -1 : efforts.indexOf(effort);
	return efforts[(at + 1) % efforts.length];
}
