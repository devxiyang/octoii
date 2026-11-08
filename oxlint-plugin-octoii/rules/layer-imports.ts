import { defineRule } from "@oxlint/plugins";

import type { ESTree, Options } from "@oxlint/plugins";

/**
 * The rule's option as `meta.schema` describes it, which requires `root` and `layers`: the directory the layers lie in,
 * the layers from the bottom up, the lowest layer each package may be imported from, and the imports kept for now that
 * break the order, by importing file.
 */
type LayerOption = {
	readonly root?: string;
	readonly layers?: readonly string[];
	readonly packages?: Readonly<Record<string, string>>;
	readonly debts?: Readonly<Record<string, readonly string[]>>;
};

/** Where an import leads: a file under the root, a file outside it, or a package. */
type Target = { readonly kind: "inside"; readonly path: string } | { readonly kind: "outside" } | { readonly kind: "package"; readonly name: string };

function layerOption(options: Readonly<Options> | undefined): LayerOption | undefined {
	// SAFETY: oxlint checks the options against `meta.schema` before the rule runs.
	const [option] = (options ?? []) as readonly (LayerOption | undefined)[];
	return option;
}

/** `path` with its `.` and `..` segments resolved, or undefined when it climbs above where it starts. */
function resolved(path: string): string | undefined {
	const parts: string[] = [];
	for (const part of path.split("/")) {
		if (part === "..") {
			if (parts.pop() === undefined) return undefined;
		} else if (part !== "." && part !== "") parts.push(part);
	}
	return parts.join("/");
}

/** The file's path below the root, or undefined when it lies outside it. */
function pathBelowRoot(filename: string, root: string): string | undefined {
	const marker = `/${root}/`;
	const slashed = filename.replaceAll("\\", "/");
	const at = slashed.lastIndexOf(marker);
	return at === -1 ? undefined : slashed.slice(at + marker.length);
}

function targetOf(file: string, specifier: string): Target {
	if (!specifier.startsWith(".")) return { kind: "package", name: specifier };
	const path = resolved(`${file.split("/").slice(0, -1).join("/")}/${specifier}`);
	return path === undefined ? { kind: "outside" } : { kind: "inside", path };
}

/** The package a specifier names: its scope and name, without a subpath. */
function packageName(specifier: string): string {
	const parts = specifier.split("/");
	return specifier.startsWith("@") ? parts.slice(0, 2).join("/") : (parts[0] ?? specifier);
}

/**
 * Each layer imports only itself and the layers below it: a file in a layer directory under `root` may import a file of
 * its own layer or a lower one, and a package only from the layer `packages` names for it upward. The top layer composes
 * the rest and may import anything under the root. An import that breaks the order is reported unless `debts` lists it
 * for its file, and a debt its file no longer has is reported too, so the list only shrinks.
 */
export default defineRule({
	meta: {
		type: "problem",
		docs: { description: "Require each layer to import only itself and the layers below it." },
		schema: [
			{
				type: "object",
				properties: {
					root: { type: "string", minLength: 1 },
					layers: { type: "array", items: { type: "string", minLength: 1 }, minItems: 1, uniqueItems: true },
					packages: { type: "object", additionalProperties: { type: "string" } },
					debts: { type: "object", additionalProperties: { type: "array", items: { type: "string" }, uniqueItems: true } },
				},
				required: ["root", "layers"],
				additionalProperties: false,
			},
		],
	},
	create(context) {
		const { root, layers, packages = {}, debts = {} } = layerOption(context.options) ?? {};
		if (root === undefined || layers === undefined) return {};
		const file = pathBelowRoot(context.filename, root);
		const layer = file === undefined ? -1 : layers.indexOf(file.split("/")[0] ?? "");
		if (file === undefined || layer === -1) return {};
		const top = layers.length - 1;
		const owed = new Set(debts[file] ?? []);
		const used = new Set<string>();

		/** The import's name in `debts`, and the layer it belongs to; undefined when the order allows it anyway. */
		const breach = (specifier: string): { readonly name: string; readonly layer: string } | undefined => {
			const target = targetOf(file, specifier);
			if (target.kind === "outside") return undefined;
			if (target.kind === "package") {
				const name = packageName(target.name);
				const lowest = packages[name];
				return lowest !== undefined && layers.indexOf(lowest) > layer ? { name, layer: lowest } : undefined;
			}
			const targetLayer = layers.indexOf(target.path.split("/")[0] ?? "");
			if (layer === top || (targetLayer !== -1 && targetLayer <= layer)) return undefined;
			return { name: target.path, layer: targetLayer === -1 ? "outside the layers" : (layers[targetLayer] ?? "") };
		};

		const check = (source: ESTree.Node, specifier: string) => {
			const found = breach(specifier);
			if (found === undefined) return;
			if (owed.has(found.name)) {
				used.add(found.name);
				return;
			}
			const where = found.layer === "outside the layers" ? found.layer : `in the layer ${found.layer}`;
			context.report({ node: source, message: `The layer ${layers[layer] ?? ""} imports only itself and the layers below it, not ${found.name}, ${where}.` });
		};

		return {
			ImportDeclaration(node) {
				check(node.source, node.source.value);
			},
			ExportNamedDeclaration(node) {
				if (node.source !== null) check(node.source, node.source.value);
			},
			ExportAllDeclaration(node) {
				check(node.source, node.source.value);
			},
			ImportExpression(node) {
				if (node.source.type === "Literal" && typeof node.source.value === "string") check(node.source, node.source.value);
			},
			"Program:exit"(node) {
				for (const name of owed) {
					if (!used.has(name)) context.report({ node, message: `${file} no longer imports ${name}; remove it from the layer debts.` });
				}
			},
		};
	},
});
