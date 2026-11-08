import { defineRule } from "@oxlint/plugins";
import { fieldOf, identifierName, isSyntaxNode, type SyntaxNode } from "../shared/syntax.ts";

/** The comparisons that test a model's id against something. */
const COMPARISONS = new Set(["===", "!==", "==", "!="]);

/** The string methods that take a part of a model's id or match it. */
const ID_METHODS = new Set(["includes", "startsWith", "endsWith", "indexOf", "lastIndexOf", "match", "matchAll", "search", "slice", "substring", "split"]);

/** The methods that look a model's id up in a set, a map or a list, or test a pattern on it. */
const LOOKUPS = new Set(["has", "get", "includes", "indexOf", "test", "exec"]);

const MESSAGE = "No code names a model: read what sets it apart from its facts (octoii.features, supported_parameters), not from its id.";

/**
 * No protocol, check or price tells models apart by their ids: none compares a model's `id`, takes a part of it, matches
 * it, looks it up in a set, a map, a list or a table, or switches on it. A model's id only goes onto the wire, which
 * passing it as a value does. A model's id is `.id` of an expression named `model` or ending in `Model`.
 */
export default defineRule({
	meta: { type: "problem", docs: { description: "Disallow telling models apart by their ids." } },
	create(context) {
		return {
			BinaryExpression(node) {
				if (COMPARISONS.has(node.operator) && (isModelId(node.left) || isModelId(node.right))) context.report({ node, message: MESSAGE });
			},
			CallExpression(node) {
				const callee = unwrapped(node.callee);
				if (callee?.type !== "MemberExpression") return;
				const method = identifierName(fieldOf(callee, "property"));
				if (method === undefined || fieldOf(callee, "computed") === true) return;
				if (ID_METHODS.has(method) && isModelId(fieldOf(callee, "object"))) context.report({ node, message: MESSAGE });
				else if (LOOKUPS.has(method) && node.arguments.some((argument) => isModelId(argument))) context.report({ node, message: MESSAGE });
			},
			MemberExpression(node) {
				if (node.computed && isModelId(node.property)) context.report({ node, message: MESSAGE });
			},
			SwitchStatement(node) {
				if (isModelId(node.discriminant)) context.report({ node: node.discriminant, message: MESSAGE });
			},
		};
	},
});

/** Whether `node` is a model's id: `.id` of an expression named `model` or ending in `Model`, optional or asserted. */
function isModelId(node: unknown): boolean {
	const member = unwrapped(node);
	if (member?.type !== "MemberExpression" || fieldOf(member, "computed") === true) return false;
	if (identifierName(fieldOf(member, "property")) !== "id") return false;
	return isModelNamed(unwrapped(fieldOf(member, "object")));
}

/** Whether `node` is named as a model: an identifier, or a member's property, `model` or ending in `Model`. */
function isModelNamed(node: SyntaxNode | undefined): boolean {
	if (node === undefined) return false;
	const name = node.type === "MemberExpression" && fieldOf(node, "computed") !== true ? identifierName(fieldOf(node, "property")) : identifierName(node);
	return name !== undefined && (name === "model" || name.endsWith("Model"));
}

/** The node `node` is without the optional chain, non-null assertion or parentheses around it; undefined for no node. */
function unwrapped(node: unknown): SyntaxNode | undefined {
	let current = node;
	while (isSyntaxNode(current) && (current.type === "ChainExpression" || current.type === "TSNonNullExpression" || current.type === "ParenthesizedExpression"))
		current = fieldOf(current, "expression");
	return isSyntaxNode(current) ? current : undefined;
}
