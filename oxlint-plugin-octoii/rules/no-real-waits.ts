import { defineRule } from "@oxlint/plugins";
import type { ESTree } from "@oxlint/plugins";
import { fieldOf, identifierName, isSyntaxNode, memberNames } from "../shared/syntax.ts";

/** The modules whose timers wait on real time when a test awaits them. */
const TIMER_MODULES = new Set(["node:timers/promises", "timers/promises"]);

/** Whether a timer call only yields a turn of the event loop: `setTimeout` with no delay, or a delay of `0`. */
function isTurnOfEventLoop(timer: string, args: readonly unknown[]): boolean {
	if (timer !== "setTimeout") return false;
	const delay = args[1];
	return delay === undefined || (isSyntaxNode(delay) && delay.type === "Literal" && fieldOf(delay, "value") === 0);
}

/**
 * No test waits on real time: no `setTimeout`, `setInterval`, `Bun.sleep` or a timer of `timers/promises`. A test
 * moves the fake clock instead, so it runs the same on a busy machine. A `setTimeout` with no delay or a delay of `0`
 * yields one turn of the event loop, for I/O to arrive, and waits on no time.
 */
export default defineRule({
	meta: { type: "problem", docs: { description: "Disallow real-time waits in tests." } },
	create(context) {
		const timers = new Set(["setTimeout", "setInterval"]);
		const report = (node: ESTree.CallExpression, what: string): void =>
			context.report({ node, message: `A test does not wait on real time (${what}): move the fake clock instead.` });
		return {
			ImportDeclaration(node) {
				// A name imported from elsewhere, such as a fake clock's `setTimeout`, is not the host's timer.
				const real = TIMER_MODULES.has(node.source.value);
				for (const specifier of node.specifiers) {
					if (real) timers.add(specifier.local.name);
					else timers.delete(specifier.local.name);
				}
			},
			CallExpression(node) {
				const name = identifierName(node.callee);
				if (name !== undefined && timers.has(name)) return isTurnOfEventLoop(name, node.arguments) ? undefined : report(node, name);
				const names = memberNames(node.callee);
				if (names === undefined) return;
				if (names[0] === "Bun" && names[1] === "sleep") report(node, names.join("."));
				if (names[0] === "globalThis" && timers.has(names[1]) && !isTurnOfEventLoop(names[1], node.arguments)) report(node, names.join("."));
			},
		};
	},
});
