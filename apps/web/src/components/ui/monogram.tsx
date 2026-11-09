/* oxlint-disable octoii/no-palette-colors -- a monogram, and a chart's series, take one of eight hues by a name, beyond what the tokens name */
/**
 * A name's monogram, a project's or a provider's: a letter or two of it on a tint of its hue — the same for a name every
 * time, or the one its caller gives, as a project holds one of its own among the person's projects.
 */
import type { ReactNode } from "react";
import { type Hue, monogramHue, monogramOf } from "../../core/monogram.ts";

const HUES: Readonly<Record<Hue, string>> = {
	blue: "text-blue-600 dark:text-blue-400",
	violet: "text-violet-600 dark:text-violet-400",
	emerald: "text-emerald-600 dark:text-emerald-400",
	amber: "text-amber-600 dark:text-amber-400",
	rose: "text-rose-600 dark:text-rose-400",
	cyan: "text-cyan-600 dark:text-cyan-400",
	orange: "text-orange-600 dark:text-orange-400",
	indigo: "text-indigo-600 dark:text-indigo-400",
};

/** The text colour of `hue`, for a series a chart gives a hue of its own. */
export function hueClassOf(hue: Hue): string {
	return HUES[hue];
}

/** The monogram of `name`, in `hue` where one is given, greyed where `faded`, its color back on its row's hover. */
export function Monogram(props: { readonly name: string; readonly hue?: Hue | undefined; readonly faded?: boolean; readonly size?: "sm" | "md" }): ReactNode {
	const size = props.size === "md" ? "size-5 text-glyph" : "size-4 text-glyph-sm";
	const hue = hueClassOf(props.hue ?? monogramHue(props.name));
	return (
		<span
			aria-hidden
			className={`relative inline-flex shrink-0 items-center justify-center overflow-hidden rounded-[25%] font-mono font-bold ${size} ${hue} ${props.faded === true ? "opacity-40 grayscale group-hover/row:opacity-100 group-hover/row:grayscale-0" : ""}`}
		>
			<span className="absolute inset-0 bg-current opacity-[0.14]" />
			<span className="relative">{monogramOf(props.name)}</span>
		</span>
	);
}
