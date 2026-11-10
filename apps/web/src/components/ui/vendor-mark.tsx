/**
 * A vendor's mark: its logo — a model's maker's, or a provider's — in its own colours where its logo has colours of
 * its own that read on either scheme, else in the ink of the words beside it; where the page has no mark for it, the
 * monogram of its name.
 */
import type { ReactNode } from "react";
import anthropic from "@lobehub/icons-static-svg/icons/anthropic.svg";
import claude from "@lobehub/icons-static-svg/icons/claude-color.svg";
import cohere from "@lobehub/icons-static-svg/icons/cohere.svg";
import deepseek from "@lobehub/icons-static-svg/icons/deepseek-color.svg";
import doubao from "@lobehub/icons-static-svg/icons/doubao-color.svg";
import gemini from "@lobehub/icons-static-svg/icons/gemini-color.svg";
import google from "@lobehub/icons-static-svg/icons/google-color.svg";
import grok from "@lobehub/icons-static-svg/icons/grok.svg";
import hunyuan from "@lobehub/icons-static-svg/icons/hunyuan.svg";
import kimi from "@lobehub/icons-static-svg/icons/kimi.svg";
import lmstudio from "@lobehub/icons-static-svg/icons/lmstudio.svg";
import meta from "@lobehub/icons-static-svg/icons/meta-color.svg";
import microsoft from "@lobehub/icons-static-svg/icons/microsoft-color.svg";
import minimax from "@lobehub/icons-static-svg/icons/minimax-color.svg";
import mistral from "@lobehub/icons-static-svg/icons/mistral-color.svg";
import nova from "@lobehub/icons-static-svg/icons/nova-color.svg";
import nvidia from "@lobehub/icons-static-svg/icons/nvidia-color.svg";
import ollama from "@lobehub/icons-static-svg/icons/ollama.svg";
import openai from "@lobehub/icons-static-svg/icons/openai.svg";
import openrouter from "@lobehub/icons-static-svg/icons/openrouter.svg";
import perplexity from "@lobehub/icons-static-svg/icons/perplexity-color.svg";
import qwen from "@lobehub/icons-static-svg/icons/qwen-color.svg";
import stepfun from "@lobehub/icons-static-svg/icons/stepfun-color.svg";
import ernie from "@lobehub/icons-static-svg/icons/wenxin.svg";
import xai from "@lobehub/icons-static-svg/icons/xai.svg";
import mimo from "@lobehub/icons-static-svg/icons/xiaomimimo.svg";
import zai from "@lobehub/icons-static-svg/icons/zai.svg";
import type { Vendor } from "../../core/vendors.ts";
import { cn } from "./cn.ts";
import { Monogram } from "./monogram.tsx";

declare module "react" {
	interface CSSProperties {
		/** The image a mark drawn in the ink beside it takes its shape from. */
		"--mark"?: string;
	}
}

/** A vendor's logo, by the address it is served at, and whether it is drawn in the ink beside it rather than its own colours. */
type Logo = { readonly address: string; readonly inked: boolean };

/** Each vendor's logo. */
const LOGOS: Readonly<Record<Vendor, Logo>> = {
	anthropic: { address: anthropic, inked: true },
	claude: { address: claude, inked: false },
	cohere: { address: cohere, inked: true },
	deepseek: { address: deepseek, inked: false },
	doubao: { address: doubao, inked: false },
	ernie: { address: ernie, inked: true },
	gemini: { address: gemini, inked: false },
	google: { address: google, inked: false },
	grok: { address: grok, inked: true },
	hunyuan: { address: hunyuan, inked: true },
	kimi: { address: kimi, inked: true },
	lmstudio: { address: lmstudio, inked: true },
	meta: { address: meta, inked: false },
	microsoft: { address: microsoft, inked: false },
	mimo: { address: mimo, inked: true },
	minimax: { address: minimax, inked: false },
	mistral: { address: mistral, inked: false },
	nova: { address: nova, inked: false },
	nvidia: { address: nvidia, inked: false },
	ollama: { address: ollama, inked: true },
	openai: { address: openai, inked: true },
	openrouter: { address: openrouter, inked: true },
	perplexity: { address: perplexity, inked: false },
	qwen: { address: qwen, inked: false },
	stepfun: { address: stepfun, inked: false },
	xai: { address: xai, inked: true },
	zai: { address: zai, inked: true },
};

/** How large a mark stands: as a monogram of the same size does. */
const SIZES = { sm: "size-4", md: "size-5" } as const;

/** The mark of `vendor`, or, where there is none the page knows, the monogram of `name`. */
export function VendorMark(props: { readonly vendor: Vendor | undefined; readonly name: string; readonly size?: "sm" | "md" }): ReactNode {
	const size = props.size ?? "sm";
	if (props.vendor === undefined) return <Monogram name={props.name} size={size} />;
	const logo = LOGOS[props.vendor];
	if (logo.inked) return <span aria-hidden style={{ "--mark": `url("${logo.address}")` }} className={cn("mark-ink shrink-0", SIZES[size])} />;
	return <img src={logo.address} alt="" aria-hidden className={cn("shrink-0", SIZES[size])} />;
}
