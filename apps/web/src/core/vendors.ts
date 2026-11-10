/**
 * The vendors whose marks the page draws: the makers of models, and the services that serve them. A model is known by
 * its maker — the one its id leads with, as a service of many makers' models names them; the one its provider serves
 * alone; or the family its id names, as a server on the person's own machine names what it runs — and a provider by the
 * service it is, or the one an account the person added is another of.
 */
import type { Provider } from "@octoii-works/octoii-client";
import { baseProviderOf, type Directory, providerOf } from "./models.ts";

/** A vendor the page has a mark for. */
export type Vendor =
	| "anthropic"
	| "claude"
	| "cohere"
	| "deepseek"
	| "doubao"
	| "ernie"
	| "gemini"
	| "google"
	| "grok"
	| "hunyuan"
	| "kimi"
	| "lmstudio"
	| "meta"
	| "microsoft"
	| "mimo"
	| "minimax"
	| "mistral"
	| "nova"
	| "nvidia"
	| "ollama"
	| "openai"
	| "openrouter"
	| "perplexity"
	| "qwen"
	| "stepfun"
	| "xai"
	| "zai";

/** Each maker a model's id may lead with, as in "openai/gpt-6.1", and the vendor of its models. */
const MAKERS: Readonly<Record<string, Vendor>> = {
	alibaba: "qwen",
	amazon: "nova",
	anthropic: "claude",
	baidu: "ernie",
	bytedance: "doubao",
	"bytedance-seed": "doubao",
	cohere: "cohere",
	deepseek: "deepseek",
	google: "gemini",
	meta: "meta",
	"meta-llama": "meta",
	microsoft: "microsoft",
	minimax: "minimax",
	mistralai: "mistral",
	moonshotai: "kimi",
	nvidia: "nvidia",
	openai: "openai",
	perplexity: "perplexity",
	qwen: "qwen",
	"stepfun-ai": "stepfun",
	tencent: "hunyuan",
	thudm: "zai",
	"x-ai": "grok",
	xiaomi: "mimo",
	"z-ai": "zai",
};

/** Each provider that serves one maker's models, and that maker's vendor. */
const SERVES: Readonly<Record<string, Vendor>> = {
	anthropic: "claude",
	chatgpt: "openai",
	claude: "claude",
	deepseek: "deepseek",
	google: "gemini",
	meta: "meta",
	openai: "openai",
	xai: "grok",
	zai: "zai",
};

/** The families a model's id may name, each by a word of its name, and their makers' vendors: the first that names it is its maker. */
const FAMILIES: readonly (readonly [RegExp, Vendor])[] = [
	[/\bgpt|\bo\d\b/, "openai"],
	[/claude/, "claude"],
	[/gemini|gemma/, "gemini"],
	[/grok/, "grok"],
	[/deepseek/, "deepseek"],
	[/kimi/, "kimi"],
	[/qwen|qwq/, "qwen"],
	[/mistral|mixtral|codestral|devstral|magistral/, "mistral"],
	[/llama/, "meta"],
	[/glm/, "zai"],
	[/minimax/, "minimax"],
	[/mimo/, "mimo"],
	[/\bphi/, "microsoft"],
];

/** Each provider's own mark, by its id. */
const PROVIDERS: Readonly<Record<string, Vendor>> = {
	anthropic: "anthropic",
	chatgpt: "openai",
	claude: "claude",
	deepseek: "deepseek",
	google: "google",
	lmstudio: "lmstudio",
	meta: "meta",
	ollama: "ollama",
	openai: "openai",
	openrouter: "openrouter",
	xai: "xai",
	zai: "zai",
};

/** The vendor of the model `id` that the provider `provider` serves, by the id of the provider it is; none the page knows. */
export function vendorOfModel(provider: string, id: string): Vendor | undefined {
	const named = id.toLowerCase();
	const slash = named.indexOf("/");
	const maker = slash > 0 ? MAKERS[named.slice(0, slash)] : undefined;
	return maker ?? SERVES[provider] ?? FAMILIES.find(([family]) => family.test(named))?.[1];
}

/** The vendor of `provider`: the service it is, or the one an account the person added is another of; none the page knows. */
export function vendorOfProvider(provider: Provider): Vendor | undefined {
	return PROVIDERS[provider.account?.of ?? provider.id];
}

/** The vendor of the model a thread names by `reference`, its provider's own read from `directory`. */
export function vendorOfReference(directory: Directory | undefined, reference: string): Vendor | undefined {
	const provider = providerOf(reference);
	return vendorOfModel(baseProviderOf(directory, provider), reference.slice(provider.length + 1));
}
