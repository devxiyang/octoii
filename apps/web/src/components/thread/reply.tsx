/**
 * A reply's words a block at a time — its paragraphs, lists, code blocks and tables — each drawn once and kept as the
 * words grow, so what was drawn is never drawn again; each block that came after the reply was first drawn fading in,
 * as it is whole.
 */
import { memo, type ReactNode } from "react";
import { blocksOf } from "../../core/blocks.ts";
import { useArrived } from "../effects/arrived.ts";
import { cn } from "../ui/cn.ts";
import { Marked } from "./markdown.tsx";

/** The words `text`, a block at a time; nothing where it holds none. */
export const Reply = memo(function Reply(props: { readonly text: string; readonly className?: string }): ReactNode {
	const blocks = blocksOf(props.text);
	const arrived = useArrived(blocks.map((block) => String(block.start)));
	if (blocks.length === 0) return null;
	return (
		<div className={cn("prose-chat", props.className)}>
			{blocks.map((block) => (
				<Block key={block.start} text={block.text} fades={arrived(String(block.start))} />
			))}
		</div>
	);
});

/** A block of a reply, in a box of its own, fading in where it came while the reply was shown. */
const Block = memo(function Block(props: { readonly text: string; readonly fades: boolean }): ReactNode {
	return (
		<div className={cn("prose-block", props.fades && "animate-fade-in motion-reduce:animate-none")}>
			<Marked text={props.text} />
		</div>
	);
});
