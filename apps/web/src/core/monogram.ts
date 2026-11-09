/**
 * A name's monogram, a project's or a provider's: a letter or two of it, and a hue — the same for a name every time, or,
 * for the person's projects, one of their own as far as there are hues.
 */

/** The hues a monogram takes. */
export const MONOGRAM_HUES = ["blue", "violet", "emerald", "amber", "rose", "cyan", "orange", "indigo"] as const;

/** One of the hues a monogram takes. */
export type Hue = (typeof MONOGRAM_HUES)[number];

/**
 * The letters a monogram shows: a one-word name's first, else the first of each of its first two words — words parted
 * by spaces and marks, and by a capital within a word, as `octoii-cloud` and `DeepSeek` are — so that a name and one
 * that extends it, as `octoii` and `octoii-cloud`, read apart.
 */
export function monogramOf(name: string): string {
	const words = name
		.replace(/([a-z0-9])([A-Z])/g, "$1 $2")
		.split(/[\s_\-./]+/)
		.filter((word) => word !== "");
	const letters = words.length > 1 ? `${words[0]?.[0] ?? ""}${words[1]?.[0] ?? ""}` : (words[0]?.[0] ?? "");
	return letters.toUpperCase();
}

/** The hue of a monogram, the same for a name every time: one of `MONOGRAM_HUES`. */
export function monogramHue(name: string): Hue {
	let sum = 0;
	for (const character of name) sum = (sum * 31 + (character.codePointAt(0) ?? 0)) % 9973;
	return MONOGRAM_HUES[sum % MONOGRAM_HUES.length] ?? "blue";
}

/**
 * The hues of `names`, the oldest first, in their order: each its own hue where no name before it holds it, else the
 * next one free after it — so they read apart as far as there are hues, and one keeps its hue as newer names come.
 * Where every hue is held, a name takes its own.
 */
export function huesApart(names: readonly string[]): readonly Hue[] {
	const held = new Set<Hue>();
	return names.map((name) => {
		const own = MONOGRAM_HUES.indexOf(monogramHue(name));
		const free = MONOGRAM_HUES.map((_, step) => MONOGRAM_HUES[(own + step) % MONOGRAM_HUES.length] ?? "blue").find((hue) => !held.has(hue));
		const hue = free ?? monogramHue(name);
		held.add(hue);
		return hue;
	});
}
