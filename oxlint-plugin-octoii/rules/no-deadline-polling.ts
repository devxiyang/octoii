import { defineRule } from "@oxlint/plugins";
import type { ESTree } from "@oxlint/plugins";
import { identifierName, isSyntaxNode, nodesWithin } from "../shared/syntax.ts";
import { isWallClockCall } from "../shared/wall-clock.ts";

/** No test polls in a loop against a deadline: a loop whose condition reads the clock or names a deadline. */
export default defineRule({
	meta: { type: "problem", docs: { description: "Disallow polling loops with deadlines in tests." } },
	create(context) {
		const check = (node: ESTree.WhileStatement | ESTree.DoWhileStatement | ESTree.ForStatement, test: unknown): void => {
			if (!isSyntaxNode(test)) return;
			const polls = [...nodesWithin(test)].some((inner) => isWallClockCall(inner) || /deadline/i.test(identifierName(inner) ?? ""));
			if (polls) context.report({ node, message: "A test does not poll against a deadline: wait for the event itself, or move the fake clock." });
		};
		return {
			WhileStatement: (node) => check(node, node.test),
			DoWhileStatement: (node) => check(node, node.test),
			ForStatement: (node) => check(node, node.test),
		};
	},
});
