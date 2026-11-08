import { defineRule } from "@oxlint/plugins";
import type { ESTree } from "@oxlint/plugins";
import { fieldOf, identifierName, isSyntaxNode, memberNames } from "../shared/syntax.ts";

/** The module whose hooks read the runtime's data. */
const CLIENT_HOOKS = "@octoii-works/octoii-client/react";

/** React's hooks that keep a component's own state, and which of their arguments is its first value. */
const STATE_HOOKS: ReadonlyMap<string, number> = new Map([
	["useState", 0],
	["useReducer", 1],
]);

/** The name an expression starts from: `a` of `a`, `a.b`, `a.b.c` and `a[0]`. */
function rootName(node: unknown): string | undefined {
	let current = node;
	while (isSyntaxNode(current) && current.type === "MemberExpression") current = fieldOf(current, "object");
	return identifierName(current);
}

/** The names a declarator binds: `a` of `const a = …`, `a` and `b` of `const { a, b: [b] } = …`. */
function boundNames(pattern: ESTree.BindingPattern): string[] {
	switch (pattern.type) {
		case "Identifier":
			return [pattern.name];
		case "ObjectPattern":
			return pattern.properties.flatMap((property) => boundNames(property.type === "RestElement" ? property.argument : property.value));
		case "ArrayPattern":
			return pattern.elements.flatMap((element) => (element === null ? [] : boundNames(element.type === "RestElement" ? element.argument : element)));
		case "AssignmentPattern":
			return boundNames(pattern.left);
		default:
			return [];
	}
}

/**
 * The runtime's data is not copied into a component's state: what a client hook answers is not the first value of
 * `useState` or `useReducer`, read directly or through a name bound to it. A copy stops following the runtime; the
 * component reads the hook's answer as it is, and keeps in its own state only what the person is doing.
 */
export default defineRule({
	meta: { type: "problem", docs: { description: "Disallow copying a client hook's answer into React state." } },
	create(context) {
		const hooks = new Set<string>();
		const fromHooks = new Set<string>();
		const isHookCall = (node: unknown): boolean =>
			isSyntaxNode(node) && node.type === "CallExpression" && hooks.has(identifierName(fieldOf(node, "callee")) ?? "");
		const copies = (node: unknown): boolean => isHookCall(node) || fromHooks.has(rootName(node) ?? "");
		return {
			ImportDeclaration(node) {
				if (node.source.value !== CLIENT_HOOKS) return;
				for (const specifier of node.specifiers) hooks.add(specifier.local.name);
			},
			VariableDeclarator(node) {
				if (isHookCall(node.init) || fromHooks.has(rootName(node.init) ?? "")) for (const name of boundNames(node.id)) fromHooks.add(name);
			},
			CallExpression(node) {
				const name = identifierName(node.callee) ?? memberNames(node.callee)?.[1];
				const index = name === undefined ? undefined : STATE_HOOKS.get(name);
				if (index === undefined || !copies(node.arguments[index])) return;
				context.report({ node, message: `The runtime's data is read from its hook, not copied into ${name}: a copy stops following the runtime.` });
			},
		};
	},
});
