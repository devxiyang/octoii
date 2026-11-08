import { defineRule } from "@oxlint/plugins";
import type { ESTree } from "@oxlint/plugins";
import { functionName, functionVisitors, type FunctionLike } from "../shared/functions.ts";

/**
 * No function returns `unknown` or `Promise<unknown>`: it returns JSON (`JsonValue`, `JsonObject`), the type a schema
 * parsed, or a type parameter its caller picks.
 */
export default defineRule({
	meta: { type: "suggestion", docs: { description: "Disallow functions that return `unknown`." } },
	create(context) {
		const check = (node: FunctionLike): void => {
			const returned = node.returnType?.typeAnnotation;
			if (returned === undefined || !returnsUnknown(returned)) return;
			context.report({
				node: returned,
				message: `${functionName(node) ?? "This function"} returns \`unknown\`: return JSON, a schema's type, or a type parameter.`,
			});
		};
		return functionVisitors(check);
	},
});

function returnsUnknown(type: ESTree.TSType): boolean {
	if (type.type === "TSUnknownKeyword") return true;
	if (type.type !== "TSTypeReference" || type.typeName.type !== "Identifier") return false;
	if (type.typeName.name !== "Promise" && type.typeName.name !== "PromiseLike") return false;
	const [inner] = type.typeArguments?.params ?? [];
	return inner?.type === "TSUnknownKeyword";
}
