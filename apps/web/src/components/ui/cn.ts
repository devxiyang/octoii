/**
 * Class names joined, Tailwind's conflicts resolved in favour of the last: the theme's own text sizes, `text-2xs` and
 * `text-2xs`, known as sizes rather than colours, so a size never drops a colour or the other way round.
 */
import { type CxOptions, cx } from "class-variance-authority";
import { extendTailwindMerge } from "tailwind-merge";

const merge = extendTailwindMerge({ extend: { theme: { text: ["2xs", "3xs"] } } });

/** `inputs` as one class name, the later of two conflicting utilities kept. */
export function cn(...inputs: CxOptions): string {
	return merge(cx(inputs));
}
