import { defineRule, type Ranged } from "@oxlint/plugins";

/** Tailwind's palette, whose hues the design reaches only through its tokens. */
const PALETTE = "slate|gray|zinc|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose";

/** A utility that paints with a palette hue, such as `bg-zinc-100`, `text-blue-600/80` or `dark:border-red-500`. */
const PALETTE_UTILITY = new RegExp(
	String.raw`(?:^|[\s:"'\x60])((?:bg|text|border(?:-[trblxyse])?|ring|ring-offset|outline|fill|stroke|from|via|to|divide|decoration|shadow|accent|caret|placeholder)-(?:${PALETTE})-\d{2,3}(?:\/\d+)?)\b`,
);

/**
 * No string paints with Tailwind's palette: an interface's colours are the design's tokens, `bg-muted`, `text-primary`,
 * so a theme that changes the tokens changes everything. White and black stay, as ink on a filled control. A place that
 * draws with hues on purpose, such as a project's monogram, says so where it turns the rule off.
 */
export default defineRule({
	meta: { type: "suggestion", docs: { description: "Disallow Tailwind palette colours outside the design's tokens." } },
	create(context) {
		const check = (node: Ranged, text: string): void => {
			const utility = PALETTE_UTILITY.exec(text)?.[1];
			if (utility === undefined) return;
			context.report({ node, message: `${utility} paints with Tailwind's palette; use the design's tokens, such as bg-muted or text-primary.` });
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
