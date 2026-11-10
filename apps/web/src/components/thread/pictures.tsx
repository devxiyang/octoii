/**
 * Pictures side by side — the images the person gave a message, the image files a message names — on a strip that
 * scrolls and swipes across: each drawn small at one height, as wide as its shape makes it, between half that height
 * and three times it, what is past either cut away from its top; read fitted to a box of twice a tile's pixels, for a
 * screen of twice as many — a kept one from the node, a machine's file by the thread's machine, from the thread's
 * folder. One opened fills the view whole, with its size, the arrows — on the screen or the keyboard — going through the
 * strip's others, Esc closing it.
 */
import { type KeyboardEvent, type ReactNode, useContext, useState } from "react";
import { ChevronLeft, ChevronRight, ImageOff } from "lucide-react";
import { fileAddress } from "../../core/attachments.ts";
import { childPath, isWholePath } from "../../core/files.ts";
import { PICTURE_BOX, type Picture, pictureAddress } from "../../core/pictures.ts";
import { useOutcome } from "../effects/read.ts";
import { IconButton } from "../ui/button.tsx";
import { cn } from "../ui/cn.ts";
import { Dialog, DialogPopup, DialogTitle } from "../ui/dialog.tsx";
import { KeptImage } from "../ui/kept-image.tsx";
import { MessageThreadContext } from "./message-thread.ts";

/** A tile's look: one height, as wide as the picture's shape, within half that height and three times it, cut from its top. */
const TILE = "block h-32 w-auto max-w-96 min-w-16 object-cover object-top";

/** The strip of `pictures`, and the one opened. */
export function PictureStrip(props: { readonly pictures: readonly Picture[]; readonly className?: string }): ReactNode {
	const [opened, setOpened] = useState<number | undefined>(undefined);
	return (
		<>
			<div className={cn("flex snap-x snap-mandatory gap-2 overflow-x-auto px-1 py-1 [scrollbar-width:thin]", props.className)}>
				{props.pictures.map((picture, index) => (
					<button
						key={`${keyOf(picture)}:${String(index)}`}
						type="button"
						title={picture.name}
						onClick={() => setOpened(index)}
						className="shrink-0 snap-start overflow-hidden rounded-md border border-border bg-muted outline-none focus-visible:ring-2 focus-visible:ring-ring"
					>
						{picture.kind === "kept" ? (
							<KeptImage address={pictureAddress(picture.ref)} alt={picture.name} loading="lazy" decoding="async" className={TILE} />
						) : (
							<FilePicture path={picture.path} name={picture.name} box={PICTURE_BOX} className={TILE} />
						)}
					</button>
				))}
			</div>
			<Viewer pictures={props.pictures} opened={opened} onOpened={setOpened} />
		</>
	);
}

/** What tells a picture from the others: its reference, or its path. */
function keyOf(picture: Picture): string {
	return picture.kind === "kept" ? picture.ref : picture.path;
}

/**
 * The machine's image at `path`, from the thread's folder or whole — fitted to `box` where it is given, else whole — as
 * the thread's machine reads it now: while it is read, a tile's room; where it is no image or cannot be read, a mark of
 * that. `onSize` is told its size once it loads.
 */
function FilePicture(props: {
	readonly path: string;
	readonly name: string;
	readonly box?: { readonly width_max: number; readonly height_max: number };
	readonly className: string;
	readonly onSize?: (size: string) => void;
}): ReactNode {
	const workspace = useContext(MessageThreadContext)?.workspace;
	const whole = isWholePath(props.path) ? props.path : workspace === undefined ? undefined : childPath(workspace, props.path);
	const outcome = useOutcome("files.read", whole === undefined ? undefined : props.box === undefined ? { path: whole } : { path: whole, box: props.box });
	if (whole !== undefined && outcome === undefined) return <span className={cn(props.className, "w-24")} />;
	if (outcome === undefined || "failure" in outcome || outcome.result.type !== "image") {
		const why = outcome === undefined ? "No folder to read it from" : "failure" in outcome ? outcome.failure : "Not an image";
		return (
			<span title={`${props.path}: ${why}`} className={cn(props.className, "flex w-24 items-center justify-center text-muted-foreground")}>
				<ImageOff className="size-5" />
			</span>
		);
	}
	const page = outcome.result;
	return (
		<img
			alt={props.name}
			src={`data:${page.media_type};base64,${page.data}`}
			onLoad={(event) => props.onSize?.(sizeOf(event.currentTarget))}
			className={props.className}
		/>
	);
}

/** An image's own size, as it loaded. */
function sizeOf(image: HTMLImageElement): string {
	return `${String(image.naturalWidth)} × ${String(image.naturalHeight)}`;
}

/** The opened picture, filling the view: its words, its size and its place in the strip, the arrows going through the others. */
function Viewer(props: {
	readonly pictures: readonly Picture[];
	readonly opened: number | undefined;
	readonly onOpened: (index: number | undefined) => void;
}): ReactNode {
	const { pictures, opened } = props;
	const picture = opened === undefined ? undefined : pictures[opened];
	const go = (by: number): void => {
		if (opened !== undefined && pictures.length > 0) props.onOpened((opened + by + pictures.length) % pictures.length);
	};
	const keys = (event: KeyboardEvent): void => {
		if (event.key === "ArrowLeft") go(-1);
		else if (event.key === "ArrowRight") go(1);
	};
	return (
		<Dialog open={picture !== undefined} onOpenChange={(open) => (open ? undefined : props.onOpened(undefined))}>
			<DialogPopup className="w-auto max-w-[92vw] items-center gap-3 border-0 bg-transparent p-0 shadow-none" onKeyDown={keys}>
				{picture === undefined ? null : (
					<Whole key={`${keyOf(picture)}:${String(opened)}`} picture={picture}>
						{pictures.length > 1 ? (
							<>
								<IconButton label="The one before" size="icon-xs" onClick={() => go(-1)}>
									<ChevronLeft className="size-4" />
								</IconButton>
								<span className="text-xs text-muted-foreground tabular-nums">
									{String((opened ?? 0) + 1)} / {String(pictures.length)}
								</span>
								<IconButton label="The one after" size="icon-xs" onClick={() => go(1)}>
									<ChevronRight className="size-4" />
								</IconButton>
							</>
						) : null}
					</Whole>
				)}
			</DialogPopup>
		</Dialog>
	);
}

/** A picture whole, and under it its words, its size once it loaded, and `children`, the way through the others. */
function Whole(props: { readonly picture: Picture; readonly children: ReactNode }): ReactNode {
	const { picture } = props;
	const [size, setSize] = useState<string | undefined>(undefined);
	const look = "max-h-[78vh] max-w-[90vw] rounded-md object-contain shadow-floating";
	return (
		<>
			{picture.kind === "kept" ? (
				<KeptImage address={fileAddress(picture.ref)} alt={picture.name} onLoad={(event) => setSize(sizeOf(event.currentTarget))} className={look} />
			) : (
				<FilePicture path={picture.path} name={picture.name} onSize={setSize} className={look} />
			)}
			<div className="flex max-w-[90vw] items-center gap-2 rounded-full bg-background px-3 py-1 text-ui shadow-floating">
				<DialogTitle className="min-w-0 truncate font-normal">{picture.name}</DialogTitle>
				{size === undefined ? null : <span className="shrink-0 text-xs text-muted-foreground tabular-nums">{size}</span>}
				{props.children}
			</div>
		</>
	);
}
