import { defineRule, type Ranged } from "@oxlint/plugins";

/** Where a utility starts in a string of classes: after a space, a quote or a variant's colon. */
const START = String.raw`(?:^|[\s:"'\x60])`;

/** What a utility paints: a fill, an ink, a line, a ring. */
const PAINTS = "bg|text|border(?:-[trblxyse])?|ring|ring-offset|outline|fill|stroke|from|via|to|divide|decoration|accent|caret|placeholder";

/** Tailwind's palette, whose hues the design reaches only through its tokens. */
const PALETTE = "slate|gray|zinc|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose";

/** The sizes of type, which a slash gives a line, not an opacity: `text-ui/5`. */
const TYPE = "2xs|xs|ui|body|title";

/** What paints off the tokens, each kind with what a string holds of it and why it is off. */
const OFF_TOKENS: readonly { readonly utility: RegExp; readonly why: string }[] = [
	{
		// A palette hue, such as `bg-zinc-100`, `text-blue-600/80` or `hover:border-red-500`.
		utility: new RegExp(String.raw`${START}((?:${PAINTS})-(?:${PALETTE})-\d{2,3}(?:\/\d+)?)\b`, "g"),
		why: "paints with Tailwind's palette; use the design's tokens, such as bg-muted or text-primary",
	},
	{
		// A colour at an opacity of its own, such as `border-border/60`, `text-muted-foreground/70` or `bg-black/[0.08]`.
		utility: new RegExp(String.raw`${START}((?:${PAINTS})-(?!(?:${TYPE})\/)[a-z][a-z-]*\/(?:\d+|\[[^\]\s]+\]))`, "g"),
		why: "thins a colour to one of its own; use the token that is that step, such as text-faint-foreground, border-border or bg-accent",
	},
	{
		// A utility the dark scheme alone takes, such as `dark:bg-input`.
		utility: new RegExp(String.raw`${START}(dark:[a-z[\-][^\s"'\x60]*)`, "g"),
		why: "paints one scheme apart; a scheme changes the tokens, so the utility that reads a token is right in both",
	},
];

/**
 * No string of classes paints off the design's tokens: an interface's colours are `bg-muted`, `text-primary`,
 * `border-border`, so a scheme or a palette that changes the tokens changes everything, and a part of the page set to
 * the other scheme shows it whole. A palette hue, a token thinned to an opacity of its own and a utility for the dark
 * scheme alone each make a colour no token holds. White and black stay, whole, as ink on a filled control.
 */
export default defineRule({
	meta: { type: "suggestion", docs: { description: "Disallow colours outside the design's tokens." } },
	create(context) {
		const check = (node: Ranged, text: string): void => {
			for (const { utility, why } of OFF_TOKENS) {
				for (const found of text.matchAll(utility)) context.report({ node, message: `${found[1] ?? ""} ${why}.` });
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
