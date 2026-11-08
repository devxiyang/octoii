/** A name's monogram, a project's or a provider's: two letters of it, and a hue that is the same for the name every time. */

/** The two letters a monogram shows: its first two words' first letters, else its first two letters. */
export function monogramOf(name: string): string {
	const words = name.split(/[\s_\-./]+/).filter((word) => word !== "");
	const letters = words.length > 1 ? `${words[0]?.[0] ?? ""}${words[1]?.[0] ?? ""}` : name.slice(0, 2);
	return letters.toUpperCase();
}

/** The hue of a monogram, the same for a name every time: one of `MONOGRAM_HUES`. */
export function monogramHue(name: string): (typeof MONOGRAM_HUES)[number] {
	let sum = 0;
	for (const character of name) sum = (sum * 31 + (character.codePointAt(0) ?? 0)) % 9973;
	return MONOGRAM_HUES[sum % MONOGRAM_HUES.length] ?? "blue";
}

/** The hues a monogram takes. */
export const MONOGRAM_HUES = ["blue", "violet", "emerald", "amber", "rose", "cyan", "orange", "indigo"] as const;
