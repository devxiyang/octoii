import { fieldOf, memberNames, type SyntaxNode } from "./syntax.ts";

/** The calls that read the wall clock. */
const WALL_CLOCK_CALLS = [
	["Date", "now"],
	["performance", "now"],
] as const;

/** Whether a node is a call that reads the wall clock: `Date.now()` or `performance.now()`. */
export function isWallClockCall(node: SyntaxNode): boolean {
	if (node.type !== "CallExpression") return false;
	const names = memberNames(fieldOf(node, "callee"));
	return names !== undefined && WALL_CLOCK_CALLS.some(([object, property]) => names[0] === object && names[1] === property);
}
