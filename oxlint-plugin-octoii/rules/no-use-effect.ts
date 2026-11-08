import { defineRule } from "@oxlint/plugins";
import { identifierName, memberNames } from "../shared/syntax.ts";

/** React's effect hooks. */
const EFFECTS = new Set(["useEffect", "useLayoutEffect", "useInsertionEffect"]);

/** Whether a file lies in a folder named `effects`, where the hooks that sync with an outside system live. */
function inEffectsFolder(filename: string): boolean {
	return filename.replaceAll("\\", "/").split("/").slice(0, -1).includes("effects");
}

/**
 * No React effect outside an `effects/` folder. What an effect is often used for has a better place: a value computed
 * from others is computed in render, what the person does happens in the event handler, state that starts again takes a
 * `key`, and the DOM is reached by a ref callback. An effect is left only to sync with an outside system, wrapped in a
 * named hook of an `effects/` folder.
 */
export default defineRule({
	meta: { type: "problem", docs: { description: "Disallow React effects outside an effects/ folder." } },
	create(context) {
		if (inEffectsFolder(context.filename)) return {};
		return {
			CallExpression(node) {
				const name = identifierName(node.callee) ?? memberNames(node.callee)?.[1];
				if (name === undefined || !EFFECTS.has(name)) return;
				context.report({
					node,
					message: `No ${name} here: compute in render, act in the event handler, reset with a key, or wrap the outside system in a named hook under effects/.`,
				});
			},
		};
	},
});
