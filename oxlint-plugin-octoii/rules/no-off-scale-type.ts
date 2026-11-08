import { defineRule, type Ranged } from "@oxlint/plugins";

/**
 * A utility that sets the size, the line or the spacing of type to a value of its own, such as `text-[13px]`,
 * `leading-[1.6]` or `md:tracking-[0.08em]`: a length, a number or a calculation in brackets. A colour in brackets, or a
 * variable, sets no type.
 */
const OFF_SCALE = /(?:^|[\s:"'\x60])((?:text|leading|tracking)-\[(?:-?\.?\d|calc\(|clamp\(|min\(|max\()[^\]\s]*\])/;

/**
 * No string sets type off the design's scale: every size stands with its line on the scale the theme declares, `text-ui`,
 * `text-body`, `tracking-caps`, so words stand alike wherever they are set, and centred where a control centres them; a
 * size of its own drifts from the others and from the line it stands on.
 */
export default defineRule({
	meta: { type: "suggestion", docs: { description: "Disallow type sizes, lines and spacings off the design's scale." } },
	create(context) {
		const check = (node: Ranged, text: string): void => {
			const utility = OFF_SCALE.exec(text)?.[1];
			if (utility === undefined) return;
			context.report({ node, message: `${utility} sets type off the design's scale; use its sizes and lines, such as text-ui, text-body or tracking-caps.` });
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
