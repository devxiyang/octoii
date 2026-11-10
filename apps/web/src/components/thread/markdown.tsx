/**
 * Markdown as the assistant and the person write it: GitHub's flavour, no raw HTML; a link to a page opening in the
 * browser, one to a path of the machine — from the thread's folder, whole, or a `file:` address — a chip that opens it
 * in the panel; a paragraph of images of the machine's files alone drawn as pictures side by side, an image among words
 * a chip of its file, one of the web a link to it, never fetched, as an address in a picture would tell a page what the
 * page holds; a page of the thread's browser that `::page` points at as its card, the other directives as they were
 * written; and each code block on a card with its language and a copy button.
 */
import type { ReactNode } from "react";
import Markdown, { type Components, defaultUrlTransform } from "react-markdown";
import remarkDirective from "remark-directive";
import remarkGfm from "remark-gfm";
import { nameOf } from "../../core/files.ts";
import { targetOf } from "../../core/links.ts";
import { picturesOfParagraph } from "../../core/pictures.ts";
import { DiffLines } from "../diff/diff-lines.tsx";
import { PathLink } from "../files/path-link.tsx";
import { cn } from "../ui/cn.ts";
import { CopyButton } from "../ui/copy-button.tsx";
import { PAGE_ELEMENT, remarkDirectives } from "./directives.ts";
import { PageCard } from "./page-card.tsx";
import { PictureStrip } from "./pictures.tsx";

declare module "react" {
	namespace JSX {
		interface IntrinsicElements {
			/** A page of the thread's browser a message points at, by its id: what `::page` is drawn as. */
			[PAGE_ELEMENT]: { readonly page?: string };
		}
	}
}

/** A code block, in a well: its language over it, and a button that copies its text, seen as the block is pointed at. */
function CodeBlock(props: { readonly language: string; readonly code: string }): ReactNode {
	return (
		<div className="well group/code my-3 overflow-hidden">
			<div className="flex h-control items-center justify-between ps-3 pe-1 font-mono text-2xs text-muted-foreground">
				<span>{props.language === "" ? "text" : props.language}</span>
				<span className="opacity-0 transition-opacity group-hover/code:opacity-100 group-focus-within/code:opacity-100 pointer-coarse:opacity-100">
					<CopyButton text={props.code} label="Copy code" />
				</span>
			</div>
			<pre className="overflow-x-auto px-3 pt-0.5 pb-3 font-mono text-xs leading-relaxed">
				<code>{props.language === "diff" ? <DiffLines text={props.code} /> : props.code}</code>
			</pre>
		</div>
	);
}

const COMPONENTS: Components = {
	pre: (props) => <>{props.children}</>,
	code: (props) => {
		const language = /language-(\w+)/.exec(props.className ?? "")?.[1];
		const text = String(props.children ?? "");
		const block = language !== undefined || text.includes("\n");
		return block ? <CodeBlock language={language ?? ""} code={text.replace(/\n$/, "")} /> : <code>{props.children}</code>;
	},
	a: (props) => <Link href={props.href ?? ""}>{props.children}</Link>,
	p: (props) => {
		const pictures = props.node === undefined ? undefined : picturesOfParagraph(props.node.children);
		return pictures === undefined ? <p>{props.children}</p> : <PictureStrip pictures={pictures} className="my-2" />;
	},
	img: (props) => <ImageLink src={typeof props.src === "string" ? props.src : ""} words={props.alt ?? ""} />,
	[PAGE_ELEMENT]: (props) => (props.page === undefined ? null : <PageCard page={props.page} />),
};

/** An image among words: a chip of its file, to open in the panel; a link to one of the web, which is never fetched. */
function ImageLink(props: { readonly src: string; readonly words: string }): ReactNode {
	if (props.src === "") return props.words;
	const target = targetOf(props.src);
	if ("path" in target) return <PathLink path={target.path}>{props.words === "" ? nameOf(target.path) : props.words}</PathLink>;
	return (
		<a href={target.url} target="_blank" rel="noopener noreferrer">
			{props.words === "" ? target.url : props.words}
		</a>
	);
}

/** A link: to a path of the machine, a chip that opens it; to a page, opening it in the browser; to nothing, its words. */
function Link(props: { readonly href: string; readonly children: ReactNode }): ReactNode {
	if (props.href === "") return props.children;
	const target = targetOf(props.href);
	if ("path" in target) return <PathLink path={target.path}>{props.children}</PathLink>;
	return (
		<a href={target.url} target="_blank" rel="noopener noreferrer">
			{props.children}
		</a>
	);
}

/** An address as a link keeps it: a `file:` one as it is, which names a path of the machine; any other as markdown keeps it, a script's dropped. */
function keptUrl(url: string): string {
	return url.startsWith("file:") ? url : defaultUrlTransform(url);
}

/** The plugins markdown is read with: GitHub's flavour, and the directives the page knows. */
const PLUGINS = [remarkGfm, remarkDirective, remarkDirectives];

/** `text` as markdown, its blocks as they are, in no box of their own: what a text or one block of it is drawn as. */
export function Marked(props: { readonly text: string }): ReactNode {
	return (
		<Markdown remarkPlugins={PLUGINS} components={COMPONENTS} urlTransform={keptUrl}>
			{props.text}
		</Markdown>
	);
}

/** `text` as markdown. */
export function Prose(props: { readonly text: string; readonly className?: string }): ReactNode {
	return (
		<div className={cn("prose-chat", props.className)}>
			<Marked text={props.text} />
		</div>
	);
}
