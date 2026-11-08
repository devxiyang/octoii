import { defineRule } from "@oxlint/plugins";
import { identifierName } from "../shared/syntax.ts";
import { isWallClockCall } from "../shared/wall-clock.ts";

/** No test reads the wall clock: `Date.now()`, `performance.now()` and `new Date()` give the fake clock's time instead. */
export default defineRule({
	meta: { type: "problem", docs: { description: "Disallow reading the wall clock in tests." } },
	create(context) {
		const message = "A test does not read the wall clock: take the time from the fake clock.";
		return {
			CallExpression(node) {
				if (isWallClockCall(node)) context.report({ node, message });
			},
			NewExpression(node) {
				if (identifierName(node.callee) === "Date" && node.arguments.length === 0) context.report({ node, message });
			},
		};
	},
});
