import { ruleTester } from "../test/harness.ts";

const rule = ruleTester("layer-imports", {
	options: [
		{
			root: "src",
			layers: ["store", "runtime", "agent", "host"],
			packages: { "@octoii-works/octoii-ai": "agent" },
			debts: { "store/owing.ts": ["agent/turn.ts", "@octoii-works/octoii-ai"], "store/stale.ts": ["agent/turn.ts"] },
		},
	],
});
const above = (layer: string, target: string, where: string): string =>
	`The layer ${layer} imports only itself and the layers below it, not ${target}, ${where}.`;

rule.valid("an import of the same layer", 'import { a } from "./keys.ts";', "src/store/state.ts");
rule.valid("an import of a lower layer", 'import { a } from "../store/state.ts";', "src/runtime/fibers.ts");
rule.valid("an import of a lower layer from a module directory", 'import { a } from "../../runtime/fibers.ts";', "src/agent/turn/loop.ts");
rule.valid("the top layer importing outside the layers", 'import { a } from "../defaults/loop.ts";', "src/host/siphon.ts");
rule.valid("a package from its layer up", 'import type { Model } from "@octoii-works/octoii-ai/models";', "src/agent/models.ts");
rule.valid("a package the option does not name", 'import { a } from "@octoii-works/octoii-std/json";', "src/store/state.ts");
rule.valid("a file outside the layers", 'import { a } from "./host/siphon.ts";', "src/index.ts");
rule.valid("debts its file still has", 'import { a } from "../agent/turn.ts";\nimport type { M } from "@octoii-works/octoii-ai";', "src/store/owing.ts");

rule.invalid(
	"an import of a higher layer",
	'import { a } from "../agent/turn.ts";',
	above("store", "agent/turn.ts", "in the layer agent"),
	"src/store/state.ts",
);
rule.invalid(
	"an export from a higher layer",
	'export { a } from "../host/siphon.ts";',
	above("runtime", "host/siphon.ts", "in the layer host"),
	"src/runtime/kernel.ts",
);
rule.invalid(
	"a dynamic import of a higher layer",
	'await import("../agent/turn.ts");',
	above("runtime", "agent/turn.ts", "in the layer agent"),
	"src/runtime/kernel.ts",
);
rule.invalid(
	"an import outside the layers",
	'import { a } from "../defaults/loop.ts";',
	above("agent", "defaults/loop.ts", "outside the layers"),
	"src/agent/turn.ts",
);
rule.invalid(
	"a package below its layer",
	'import { a } from "@octoii-works/octoii-ai/models";',
	above("runtime", "@octoii-works/octoii-ai", "in the layer agent"),
	"src/runtime/kernel.ts",
);
rule.invalid(
	"a debt its file no longer has",
	'import { a } from "./keys.ts";',
	"store/stale.ts no longer imports agent/turn.ts; remove it from the layer debts.",
	"src/store/stale.ts",
);
