/**
 * A reply's words a block at a time — its paragraphs, lists, code blocks and tables — each block drawn once and kept as
 * the words grow, so a block that is whole is never drawn again; while the reply is written, the block being written
 * drawn anew as it grows, its words shown at an even pace, its code plain till its fence closes and a table's header held
 * back till the table it heads is one; each block that came after the reply was first drawn fading in, once.
 */
import { memo, type ReactNode } from "react";
import { blocksOf, showableOf } from "../../core/blocks.ts";
import { useArrived } from "../effects/arrived.ts";
import { usePaced } from "../effects/paced.ts";
import { cn } from "../ui/cn.ts";
import { MarkedBlock } from "./markdown.tsx";

/** The words `text`, a block at a time, its last still being written where it is `writing`; nothing where it holds none. */
export const Reply = memo(function Reply(props: { readonly text: string; readonly writing: boolean; readonly className?: string }): ReactNode {
	const shown = usePaced(props.text, props.writing);
	const blocks = shownBlocks(shown, props.writing);
	const arrived = useArrived(blocks.map((block) => String(block.start)));
	if (blocks.length === 0) return null;
	return (
		<div className={cn("prose-chat", props.className)}>
			{blocks.map((block) => (
				<div key={block.start} className={cn("prose-block", arrived(String(block.start)) && "animate-fade-in motion-reduce:animate-none")}>
					<Block text={block.text} writing={block.writing} />
				</div>
			))}
		</div>
	);
});

/** A block that shows: where it begins, its words, and whether it is still being written. */
type Shown = { readonly start: number; readonly text: string; readonly writing: boolean };

/** The blocks of `text` that show, each with whether it is still being written: the last, where the text is `writing`, as far as it can show as it will stand. */
function shownBlocks(text: string, writing: boolean): readonly Shown[] {
	const blocks = blocksOf(text);
	return blocks.flatMap((block, place): readonly Shown[] => {
		if (!writing || place < blocks.length - 1) return [{ ...block, writing: false }];
		const showable = showableOf(block.text);
		return showable === "" ? [] : [{ start: block.start, text: showable, writing: true }];
	});
}

/** A block, drawn again only as its words change or it comes whole. */
const Block = memo(function Block(props: { readonly text: string; readonly writing: boolean }): ReactNode {
	return <MarkedBlock text={props.text} writing={props.writing} />;
});
