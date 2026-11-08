import { defineRule } from "@oxlint/plugins";

/**
 * No type, interface, class or enum named `…Record`: a type is named for what it is, not for being a record. TypeScript's
 * `Record<K, V>` is a use, not a declaration, and stays allowed.
 */
export default defineRule({
	meta: { type: "suggestion", docs: { description: "Disallow type names that end in `Record`." } },
	create(context) {
		const check = (id: { readonly name: string; readonly range: [number, number] } | null): void => {
			if (id === null || !id.name.endsWith("Record") || id.name === "Record") return;
			context.report({ node: id, message: `Name the type for what it is, not \`Record\`: ${id.name}.` });
		};
		return {
			TSTypeAliasDeclaration: (node) => check(node.id),
			TSInterfaceDeclaration: (node) => check(node.id),
			TSEnumDeclaration: (node) => check(node.id),
			ClassDeclaration: (node) => check(node.id),
			ClassExpression: (node) => check(node.id),
		};
	},
});
