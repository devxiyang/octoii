/**
 * The files a draft gives its message, over the box: an image as its picture, any other file by its name and size,
 * each with a cross that takes it away; the files on their way to the node, shown fading; why one failed; and a note
 * where the model looks at no images.
 */
import { type ReactNode, useRef } from "react";
import { FileText, LoaderCircle, Paperclip, X } from "lucide-react";
import { type Attachment, fileAddress, isImage, sizeLabel } from "../../core/attachments.ts";
import { IconButton } from "../ui/button.tsx";
import { KeptImage } from "../ui/kept-image.tsx";
import type { Attaching } from "./attaching.ts";

/** What the row is given: the draft's files, those on their way, and whether the model looks at images. */
export type AttachmentsProps = {
	readonly attachments: readonly Attachment[];
	readonly attaching: Attaching;
	readonly seesImages: boolean | undefined;
};

/** The row; nothing where there is nothing to show. */
export function Attachments(props: AttachmentsProps): ReactNode {
	const { attachments, attaching } = props;
	const images = attachments.some((each) => isImage(each.media_type));
	if (attachments.length === 0 && attaching.sending.length === 0 && attaching.failure === undefined) return null;
	return (
		<div className="flex flex-col gap-1.5 px-3 pt-3">
			<div className="flex flex-wrap gap-2">
				{attachments.map((attachment) => (
					<Chip key={attachment.ref} attachment={attachment} onRemove={() => attaching.remove(attachment.ref)} />
				))}
				{attaching.sending.map((going) => (
					<div key={going.key} className="flex h-14 items-center gap-2 rounded-md border border-border bg-muted px-2 text-xs text-muted-foreground opacity-70">
						{going.preview === undefined ? <FileText className="size-4" /> : <img src={going.preview} alt="" className="size-10 rounded-sm object-cover" />}
						<span className="max-w-32 truncate">{going.name}</span>
						<LoaderCircle className="size-3.5 animate-spin" />
					</div>
				))}
			</div>
			{attaching.failure === undefined ? null : <p className="text-xs text-error-foreground">{attaching.failure}</p>}
			{images && props.seesImages === false ? (
				<p className="text-xs text-warning-foreground">This model looks at no images: choose one that does to send them.</p>
			) : null}
		</div>
	);
}

/** A file of the draft's: an image's picture, or a file's name and size; its cross as it is pointed at or focused, and always where nothing points. */
function Chip(props: { readonly attachment: Attachment; readonly onRemove: () => void }): ReactNode {
	const { attachment } = props;
	return (
		<div className="group/chip relative">
			{isImage(attachment.media_type) ? (
				<KeptImage
					address={fileAddress(attachment.ref)}
					alt={attachment.name}
					title={attachment.name}
					className="size-14 rounded-md border border-border object-cover"
				/>
			) : (
				<div title={attachment.name} className="flex h-14 max-w-52 items-center gap-2 rounded-md border border-border bg-muted px-2.5">
					<FileText className="size-5 shrink-0 text-muted-foreground" />
					<span className="flex min-w-0 flex-col">
						<span className="truncate text-xs text-foreground">{attachment.name}</span>
						<span className="text-2xs text-muted-foreground">{sizeLabel(attachment.size)}</span>
					</span>
				</div>
			)}
			<button
				type="button"
				aria-label={`Take away ${attachment.name}`}
				onClick={props.onRemove}
				className="absolute -top-1.5 -right-1.5 flex size-5 items-center justify-center rounded-full border border-border bg-popover text-muted-foreground opacity-0 group-hover/chip:opacity-100 hover:text-foreground focus-visible:opacity-100 pointer-coarse:opacity-100"
			>
				<X className="size-3" />
			</button>
		</div>
	);
}

/** The button that picks files to attach, from the device's own picker. */
export function AttachButton(props: { readonly onFiles: (files: readonly File[]) => void }): ReactNode {
	const picker = useRef<HTMLInputElement>(null);
	return (
		<>
			<input
				ref={picker}
				type="file"
				multiple
				hidden
				onChange={(event) => {
					props.onFiles([...(event.target.files ?? [])]);
					event.target.value = "";
				}}
			/>
			<IconButton label="Attach files" onMouseDown={(event) => event.preventDefault()} onClick={() => picker.current?.click()}>
				<Paperclip className="size-4" />
			</IconButton>
		</>
	);
}
