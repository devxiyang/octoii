/**
 * A name's monogram, a project's or a provider's: a letter or two of it on a tint of its hue — the same for a name every
 * time, or the one its caller gives, as a project holds one of its own among the person's projects.
 */
import type { ReactNode } from "react";
import { type Hue, monogramHue, monogramOf } from "../../core/monogram.ts";

/** Each hue's ink, a token the scheme sets. */
const HUES: Readonly<Record<Hue, string>> = {
	blue: "text-hue-blue",
	violet: "text-hue-violet",
	emerald: "text-hue-emerald",
	amber: "text-hue-amber",
	rose: "text-hue-rose",
	cyan: "text-hue-cyan",
	orange: "text-hue-orange",
	indigo: "text-hue-indigo",
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
			className={`relative inline-flex shrink-0 items-center justify-center overflow-hidden rounded-sm font-mono font-bold ${size} ${hue} ${props.faded === true ? "opacity-40 grayscale group-hover/row:opacity-100 group-hover/row:grayscale-0" : ""}`}
		>
			<span className="absolute inset-0 bg-current opacity-[0.14]" />
			<span className="relative">{monogramOf(props.name)}</span>
		</span>
	);
}
