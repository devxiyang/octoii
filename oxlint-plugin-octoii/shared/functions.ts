import type { ESTree } from "@oxlint/plugins";

/** A node that declares a function or the type of one: what the rules read of its parameters and return type. */
export type FunctionLike =
	| ESTree.Function
	| ESTree.ArrowFunctionExpression
	| ESTree.TSMethodSignature
	| ESTree.TSFunctionType
	| ESTree.TSCallSignatureDeclaration
	| ESTree.TSConstructSignatureDeclaration;

/** A visitor that hands every function, and every type of one, to `check`. */
export function functionVisitors(check: (node: FunctionLike) => void) {
	return {
		FunctionDeclaration: check,
		FunctionExpression: check,
		ArrowFunctionExpression: check,
		TSDeclareFunction: check,
		TSMethodSignature: check,
		TSFunctionType: check,
		TSCallSignatureDeclaration: check,
		TSConstructSignatureDeclaration: check,
	};
}

/** The name the function is known by: its own, its variable's, or its key in an object, class or type. */
export function functionName(node: FunctionLike): string | undefined {
	if ("id" in node && node.id !== null && node.id !== undefined && node.id.type === "Identifier") return node.id.name;
	if (node.type === "TSMethodSignature") return keyName(node.key);
	const parent = node.type === "TSFunctionType" ? node.parent.parent : node.parent;
	if (parent === null) return undefined;
	if (parent.type === "VariableDeclarator") return parent.id.type === "Identifier" ? parent.id.name : undefined;
	if (parent.type === "MethodDefinition" || parent.type === "Property" || parent.type === "PropertyDefinition" || parent.type === "TSPropertySignature") {
		return keyName(parent.key);
	}
	return undefined;
}

function keyName(key: ESTree.Node): string | undefined {
	if (key.type === "Identifier") return key.name;
	return key.type === "Literal" && typeof key.value === "string" ? key.value : undefined;
}
