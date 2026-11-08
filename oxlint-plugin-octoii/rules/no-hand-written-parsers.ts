import { defineRule } from "@oxlint/plugins";
import type { ESTree } from "@oxlint/plugins";
import { functionName, functionVisitors, type FunctionLike } from "../shared/functions.ts";
import { fieldOf, identifierName, isSyntaxNode, memberNames, nodesWithin, type SyntaxNode } from "../shared/syntax.ts";

type Parameter = ESTree.ParamPattern;

/** Types that say nothing of an object's fields: data whose structure a guard over it would check by hand. */
const UNTYPED_REFERENCES = new Set(["JsonValue", "JsonObject"]);

/** Calls that read a field of their first argument. */
const FIELD_READS = new Set(["Reflect.get", "Reflect.has", "Object.hasOwn"]);

/** Calls that narrow untyped data to an object whose fields a parser then reads by hand. */
const OBJECT_NARROWINGS = new Set(["isJsonObject", "isRecord", "isObject", "isPlainObject"]);

/**
 * Structured data is described by a schema, which is both the check and the type (`matches`, `parsed` of
 * `@octoii-works/octoii-std/schema`): no type guard checks the fields of untyped data by hand (`value is T` over `unknown` or JSON,
 * reading its properties), and no parser narrows an untyped parameter to an object (`isJsonObject(value)`,
 * `typeof value === "object"`) and then reads its fields.
 */
export default defineRule({
	meta: {
		type: "suggestion",
		docs: { description: "Disallow hand-written guards and parsers that inspect an untyped object's fields." },
	},
	create(context) {
		const check = (node: FunctionLike): void => {
			if (!("body" in node) || !isSyntaxNode(node.body)) return;
			const body = node.body;
			const guarded = guardedParameter(node);
			if (guarded !== undefined) {
				if (!isUntyped(parameterType(guarded.param)) || !readsPropertiesOf(body, guarded.name)) return;
				context.report({
					node: node.returnType ?? node,
					message: `${functionName(node) ?? "This guard"} checks the fields of ${guarded.name} by hand: describe them with a schema and use \`matches\` or \`parsed\`.`,
				});
				return;
			}
			for (const param of node.params) {
				const name = parameterName(param);
				if (name === undefined || !isUntyped(parameterType(param))) continue;
				if (!narrowsToObject(body, name) || !readsPropertiesOf(body, name)) continue;
				context.report({
					node: param,
					message: `${functionName(node) ?? "This function"} parses the fields of ${name} by hand: describe them with a schema and use \`parsed\` or \`matches\`.`,
				});
			}
		};
		return functionVisitors(check);
	},
});

function guardedParameter(node: FunctionLike): { readonly name: string; readonly param: Parameter } | undefined {
	const predicate = node.returnType?.typeAnnotation;
	if (predicate?.type !== "TSTypePredicate" || predicate.parameterName.type !== "Identifier") return undefined;
	const name = predicate.parameterName.name;
	const param = node.params.find((candidate) => parameterName(candidate) === name);
	return param === undefined ? undefined : { name, param };
}

function parameterName(param: Parameter): string | undefined {
	const binding = param.type === "TSParameterProperty" ? param.parameter : param.type === "RestElement" ? param.argument : param;
	const target = binding.type === "AssignmentPattern" ? binding.left : binding;
	return target.type === "Identifier" ? target.name : undefined;
}

function parameterType(param: Parameter): ESTree.TSType | undefined {
	const binding = param.type === "TSParameterProperty" ? param.parameter : param;
	const target = binding.type === "AssignmentPattern" ? binding.left : binding;
	return target.typeAnnotation?.typeAnnotation ?? undefined;
}

/** `unknown`, JSON or a bare object type, alone or with `undefined` or `null`. */
function isUntyped(type: ESTree.TSType | undefined): boolean {
	if (type === undefined) return false;
	if (type.type === "TSUnknownKeyword" || type.type === "TSObjectKeyword") return true;
	if (type.type === "TSUnionType") {
		const rest = type.types.filter((member) => member.type !== "TSUndefinedKeyword" && member.type !== "TSNullKeyword");
		return rest.length > 0 && rest.every(isUntyped);
	}
	if (type.type !== "TSTypeReference" || type.typeName.type !== "Identifier") return false;
	const [first, second] = type.typeArguments?.params ?? [];
	if (type.typeName.name === "Readonly") return isUntyped(first);
	if (type.typeName.name === "Record") return second?.type === "TSUnknownKeyword";
	return UNTYPED_REFERENCES.has(type.typeName.name);
}

/**
 * Whether `body` reads a named field of `name`: `name.field`, `name["field"]`, `"field" in name` or
 * `Reflect.get(name, "field")`. A method called on it, such as an array's `every`, reads no field; nor does `length` or
 * a key held in a variable, which walk any JSON rather than a shape.
 */
function readsPropertiesOf(body: ESTree.Node, name: string): boolean {
	for (const node of nodesWithin(body)) {
		if (node.type === "MemberExpression" && identifierName(fieldOf(node, "object")) === name && isNamedKey(node) && !isCallee(node)) return true;
		if (
			node.type === "BinaryExpression" &&
			fieldOf(node, "operator") === "in" &&
			identifierName(fieldOf(node, "right")) === name &&
			isStringLiteral(fieldOf(node, "left"))
		)
			return true;
		if (node.type === "CallExpression" && isFieldRead(node, name)) return true;
	}
	return false;
}

/** A key a shape names; an array's or a string's `length` is none. */
function isNamedKey(member: SyntaxNode): boolean {
	const property = fieldOf(member, "property");
	if (fieldOf(member, "computed") === true) return isStringLiteral(property);
	return identifierName(property) !== "length";
}

function isStringLiteral(node: unknown): boolean {
	return isSyntaxNode(node) && node.type === "Literal" && typeof fieldOf(node, "value") === "string";
}

function isCallee(node: SyntaxNode): boolean {
	const parent = fieldOf(node, "parent");
	return isSyntaxNode(parent) && parent.type === "CallExpression" && fieldOf(parent, "callee") === node;
}

function isFieldRead(call: SyntaxNode, name: string): boolean {
	const callee = memberNames(fieldOf(call, "callee"))?.join(".");
	const args = fieldOf(call, "arguments");
	if (callee === undefined || !FIELD_READS.has(callee) || !Array.isArray(args)) return false;
	return identifierName(args[0]) === name && (args[1] === undefined || isStringLiteral(args[1]));
}

/** Whether `body` narrows `name` to an object: `isJsonObject(name)` and the like, or `typeof name === "object"`. */
function narrowsToObject(body: ESTree.Node, name: string): boolean {
	for (const node of nodesWithin(body)) {
		if (node.type === "CallExpression" && isObjectNarrowing(node, name)) return true;
		if (node.type === "BinaryExpression" && isTypeofObject(node, name)) return true;
	}
	return false;
}

function isObjectNarrowing(call: SyntaxNode, name: string): boolean {
	const callee = identifierName(fieldOf(call, "callee"));
	const args = fieldOf(call, "arguments");
	if (callee === undefined || !OBJECT_NARROWINGS.has(callee) || !Array.isArray(args)) return false;
	return identifierName(args[0]) === name;
}

function isTypeofObject(comparison: SyntaxNode, name: string): boolean {
	const operator = fieldOf(comparison, "operator");
	if (operator !== "===" && operator !== "!==") return false;
	const sides = [fieldOf(comparison, "left"), fieldOf(comparison, "right")];
	const literal = sides.some((side) => isSyntaxNode(side) && side.type === "Literal" && fieldOf(side, "value") === "object");
	const typeofName = sides.some(
		(side) =>
			isSyntaxNode(side) && side.type === "UnaryExpression" && fieldOf(side, "operator") === "typeof" && identifierName(fieldOf(side, "argument")) === name,
	);
	return literal && typeofName;
}
