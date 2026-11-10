import { defineRule, type Ranged } from "@oxlint/plugins";

/** Where a utility starts in a string of classes — after a space, a quote or a variant's colon — and where it ends. */
const START = String.raw`(?:^|[\s:"'\x60])`;
const END = String.raw`(?=$|[\s"'\x60])`;

/** What is off the design's scale, each kind with what a string holds of it and what the scale offers in its place. */
const OFF_SCALE: readonly { readonly utility: RegExp; readonly instead: string }[] = [
	{
		// A size, a line or a spacing of type of its own, such as `text-[13px]`, `leading-[1.6]` or `md:tracking-[0.08em]`: a
		// length, a number or a calculation in brackets. A colour in brackets, or a variable, sets no type.
		utility: new RegExp(String.raw`${START}((?:text|leading|tracking)-\[(?:-?\.?\d|calc\(|clamp\(|min\(|max\()[^\]\s]*\])`, "g"),
		instead: "sets type off the design's scale; use its sizes and lines, such as text-ui, text-body or tracking-caps",
	},
	{
		// One of Tailwind's own sizes of type, which the theme takes out: `text-sm`, `text-base`, `text-2xl`.
		utility: new RegExp(String.raw`${START}(text-(?:3xs|sm|base|lg|xl|[2-9]xl))${END}`, "g"),
		instead: "is no size of the design's; use text-2xs, text-xs, text-ui, text-body or text-title",
	},
	{
		// A radius of its own, `rounded-[20px]`, one of Tailwind's the theme takes out, `rounded-xl`, or the bare
		// `rounded`, on any corner or side.
		utility: new RegExp(String.raw`${START}(rounded(?:-(?:[trblse]|[tb][lr]|[se][se]))?(?:-(?:xs|xl|[2-4]xl|\[-?\.?\d[^\]\s]*\]))?)${END}`, "g"),
		instead: "is no radius of the design's; use rounded-sm, rounded-md, rounded-lg or rounded-full",
	},
	{
		// A shadow besides the two the tokens hold: one of Tailwind's, one of its own in brackets, an inset one, the bare
		// `shadow`, or one tinted with a colour.
		utility: new RegExp(String.raw`${START}((?:inset-|drop-)?shadow(?:-(?!raised${END}|floating${END}|none${END})[^\s"'\x60]+)?)${END}`, "g"),
		instead: "is no shadow of the design's; use shadow-raised for what stands a little raised, shadow-floating for what floats",
	},
];

/**
 * No string of classes steps off the design's scales: five sizes of type, each with its line, `text-ui`, `text-body`;
 * three radii, `rounded-sm`, `rounded-md`, `rounded-lg`, and the full round; two shadows, `shadow-raised` and
 * `shadow-floating`. A value of its own drifts from the others, so words, corners and what floats stop reading alike.
 */
export default defineRule({
	meta: { type: "suggestion", docs: { description: "Disallow type sizes, radii and shadows off the design's scales." } },
	create(context) {
		const check = (node: Ranged, text: string): void => {
			for (const { utility, instead } of OFF_SCALE) {
				for (const found of text.matchAll(utility)) context.report({ node, message: `${found[1] ?? ""} ${instead}.` });
			}
		};
		return {
			Literal(node) {
				if (typeof node.value === "string") check(node, node.value);
			},
			TemplateElement(node) {
				check(node, node.value.raw);
			},
		};
	},
});
