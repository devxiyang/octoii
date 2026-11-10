/**
 * The person's words on a bubble at the right, as markdown — their lines kept as they broke them, each file or folder
 * they mention a link shown by its name — over it the files they gave: the images on a strip of pictures, as the
 * pictures a call shows are, opened whole in the view; any other file by its name, opened whole in a tab; and, for a
 * sub-thread's task, a way to the thread it came from; and a button that copies the words as they were written, shown
 * as the message is pointed at or focused, and always where nothing points.
 */
import type { ReactNode } from "react";
import { useThreads } from "@octoii-works/octoii-client/react";
import { CornerLeftUp, FileText } from "lucide-react";
import { type Attachment, fileAddress, isImage } from "../../core/attachments.ts";
import { picturesGiven } from "../../core/pictures.ts";
import type { Said } from "../../core/timeline.ts";
import { useFileSource } from "../effects/file-source.ts";
import { go } from "../state/navigation.ts";
import { CopyButton } from "../ui/copy-button.tsx";
import { Prose } from "./markdown.tsx";
import { PictureStrip } from "./pictures.tsx";

/** The person's words, or a task the thread's parent gave it. */
export function UserMessage(props: { readonly said: Said }): ReactNode {
	const { said } = props;
	return (
		<div className="group/message flex flex-col items-end gap-1">
			{said.from === undefined ? null : <From thread={said.from} />}
			{said.attachments.length === 0 ? null : <Given attachments={said.attachments} />}
			{said.text === "" ? null : (
				// The copy stands beside the bubble's foot, taking no room of its own, so the message keeps near its reply.
				<div className="relative flex max-w-[80%] justify-end">
					<div className="rounded-lg bg-muted px-4 py-2.5 text-foreground [&_:is(p,li)]:whitespace-pre-wrap">
						<Prose text={said.text} className="text-body" />
					</div>
					<div className="absolute end-full bottom-0 me-1 opacity-0 transition-opacity group-focus-within/message:opacity-100 group-hover/message:opacity-100 pointer-coarse:opacity-100">
						<CopyButton text={said.text} label="Copy message" />
					</div>
				</div>
			)}
		</div>
	);
}

/** Where a task came from: the thread that gave it, opened from its title. */
function From(props: { readonly thread: string }): ReactNode {
	const title = useThreads()?.find((row) => row.id === props.thread)?.manifest.title ?? "its thread";
	return (
		<button
			type="button"
			onClick={() => go({ place: "thread", thread: props.thread })}
			className="flex max-w-[80%] items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
		>
			<CornerLeftUp className="size-3.5 shrink-0" />
			<span className="truncate">{`From ${title}`}</span>
		</button>
	);
}

/** The files the person gave: the images as pictures side by side, each other file by its name, opened whole in a tab of its own. */
function Given(props: { readonly attachments: readonly Attachment[] }): ReactNode {
	const pictures = picturesGiven(props.attachments);
	const others = props.attachments.filter((attachment) => !isImage(attachment.media_type));
	return (
		<>
			{pictures.length === 0 ? null : <PictureStrip pictures={pictures} className="max-w-[80%]" />}
			{others.length === 0 ? null : (
				<div className="flex max-w-[80%] flex-wrap justify-end gap-2">
					{others.map((attachment) => (
						<GivenFile key={attachment.ref} attachment={attachment} />
					))}
				</div>
			)}
		</>
	);
}

/** A file the person gave, by its name, opened whole in a tab of its own. */
function GivenFile(props: { readonly attachment: Attachment }): ReactNode {
	const { attachment } = props;
	return (
		<a href={useFileSource(fileAddress(attachment.ref))} target="_blank" rel="noreferrer" title={attachment.name} className="block">
			<span className="flex h-12 max-w-56 items-center gap-2 rounded-md border border-border bg-muted px-3 text-ui text-foreground">
				<FileText className="size-4 shrink-0" />
				<span className="truncate">{attachment.name}</span>
			</span>
		</a>
	);
}
