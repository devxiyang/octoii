/**
 * Markdown as the assistant and the person write it: GitHub's flavour, no raw HTML; a link to a page opening in the
 * browser, one to a path of the machine — from the thread's folder, whole, or a `file:` address — a chip that opens it
 * in the panel; a paragraph of images of the machine's files alone drawn as pictures side by side, an image among words
 * a chip of its file, one of the web a link to it, never fetched, as an address in a picture would tell a page what the
 * page holds; a page of the thread's browser that `::page` points at as its card, the other directives as they were
 * written; each code block in a well of its own, its code plain while it is still being written; and a table scrolled
 * within itself where it is wider than its column. Text that is whole is read once: what it draws is kept by the text,
 * so a block drawn again — scrolled back to, or its thread opened again — is not read anew.
 */
import { createContext, type ReactElement, type ReactNode, use } from "react";
import Markdown, { type Components, defaultUrlTransform } from "react-markdown";
import { fenceOpen } from "../../core/blocks.ts";
import remarkDirective from "remark-directive";
import remarkGfm from "remark-gfm";
import { nameOf } from "../../core/files.ts";
import { targetOf } from "../../core/links.ts";
import { picturesOfParagraph } from "../../core/pictures.ts";
import { PathLink } from "../files/path-link.tsx";
import { cn } from "../ui/cn.ts";
import { CodeBeingWritten, CodeBlock } from "./code-block.tsx";
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

const COMPONENTS: Components = {
	pre: (props) => <>{props.children}</>,
	code: (props) => {
		const language = /language-(\S+)/.exec(props.className ?? "")?.[1];
		const text = String(props.children ?? "");
		const block = language !== undefined || text.includes("\n");
		return block ? <CodeOf language={language ?? ""} code={text.replace(/\n$/, "")} /> : <code>{props.children}</code>;
	},
	table: (props) => (
		<div className="my-3 overflow-x-auto">
			<table>{props.children}</table>
		</div>
	),
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

/** Whether the code being drawn is still being written: its fence not closed yet. */
const CodeWritten = createContext(false);

/** A code block, plain while it is still being written. */
function CodeOf(props: { readonly language: string; readonly code: string }): ReactNode {
	return use(CodeWritten) ? <CodeBeingWritten language={props.language} code={props.code} /> : <CodeBlock language={props.language} code={props.code} />;
}

/** `text` as markdown, its blocks as they are, in no box of their own: what a whole text is drawn as, read once. */
export function Marked(props: { readonly text: string }): ReactNode {
	return drawnOf(props.text);
}

/**
 * A block of a reply as markdown: read once where it is whole; read anew as it grows while it is `writing` — not kept,
 * as each of its texts is drawn once — its code plain while its fence is open. Drawn as the same elements either way, so
 * a block that comes whole is not drawn anew.
 */
export function MarkedBlock(props: { readonly text: string; readonly writing: boolean }): ReactNode {
	return <CodeWritten value={props.writing && fenceOpen(props.text)}>{props.writing ? drawnAnew(props.text) : drawnOf(props.text)}</CodeWritten>;
}

/** What `text` draws as markdown, read anew. */
function drawnAnew(text: string): ReactElement {
	// Markdown reads and draws a text at once, as a function of it alone.
	return Markdown({ children: text, remarkPlugins: PLUGINS, components: COMPONENTS, urlTransform: keptUrl });
}

/** How many characters of whole text the drawings kept may hold, about: each holds some twenty bytes a character, so some ten megabytes. */
const KEPT_CHARACTERS = 500_000;

/** What each text kept draws, the one drawn least lately first. */
const drawings = new Map<string, ReactElement>();
let keptCharacters = 0;

/** What `text` draws as markdown: kept, as a text draws the same each time, the least lately drawn let go as the kept outgrow their room. */
function drawnOf(text: string): ReactElement {
	const kept = drawings.get(text);
	if (kept !== undefined) {
		drawings.delete(text);
		drawings.set(text, kept);
		return kept;
	}
	const drawn = drawnAnew(text);
	// A text too long to keep with others is drawn each time rather than letting all the others go.
	if (text.length > KEPT_CHARACTERS / 4) return drawn;
	drawings.set(text, drawn);
	keptCharacters += text.length;
	for (const [oldest] of drawings) {
		if (keptCharacters <= KEPT_CHARACTERS) break;
		drawings.delete(oldest);
		keptCharacters -= oldest.length;
	}
	return drawn;
}

/** `text` as markdown. */
export function Prose(props: { readonly text: string; readonly className?: string }): ReactNode {
	return (
		<div className={cn("prose-chat", props.className)}>
			<Marked text={props.text} />
		</div>
	);
}
