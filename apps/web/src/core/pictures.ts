/**
 * The pictures the timeline draws: the images the person gave a message, kept by the node by their content; and the
 * image files a message names in Markdown — the model's, mostly — read from the machine as they are now. Each is drawn
 * small fitted to one box, and read whole once it is opened.
 */
import { matches } from "@octoii-works/octoii-client";
import { Type } from "typebox";
import { type Attachment, fileAddress, isImage } from "./attachments.ts";
import { nameOf } from "./files.ts";
import { targetOf } from "./links.ts";

/** A picture: a file the node keeps, by its reference, or one of the machine's, by the path a message names — with its words. */
export type Picture =
	| { readonly kind: "kept"; readonly ref: string; readonly name: string }
	| { readonly kind: "file"; readonly path: string; readonly name: string };

/** The images among the files the person gave a message, as pictures. */
export function picturesGiven(attachments: readonly Attachment[]): readonly Picture[] {
	return attachments.filter((attachment) => isImage(attachment.media_type)).map((attachment) => ({ kind: "kept", ref: attachment.ref, name: attachment.name }));
}

const ImageSchema = Type.Object({
	type: Type.Literal("element"),
	tagName: Type.Literal("img"),
	properties: Type.Object({ src: Type.Optional(Type.String()), alt: Type.Optional(Type.String()) }),
});
const TextSchema = Type.Object({ type: Type.Literal("text"), value: Type.String() });
const BreakSchema = Type.Object({ type: Type.Literal("element"), tagName: Type.Literal("br") });

/**
 * The pictures a paragraph of Markdown is, as its children are given to the page: where it holds images of the machine's
 * files alone — between them nothing but spaces and breaks — each by the path it names, as a message names one, and its
 * words, the file's name where it has none; none where it holds anything else.
 */
export function picturesOfParagraph(children: readonly unknown[]): readonly Picture[] | undefined {
	const pictures: Picture[] = [];
	for (const child of children) {
		if ((matches(TextSchema, child) && child.value.trim() === "") || matches(BreakSchema, child)) continue;
		if (!matches(ImageSchema, child)) return undefined;
		const target = targetOf(child.properties.src ?? "");
		if (!("path" in target) || target.path === "") return undefined;
		const words = child.properties.alt ?? "";
		pictures.push({ kind: "file", path: target.path, name: words === "" ? nameOf(target.path) : words });
	}
	return pictures.length === 0 ? undefined : pictures;
}

/** The box a picture is drawn small in, in pixels: twice a tile's height, and three times that across — the widest a tile goes — for a screen of twice the pixels. */
export const PICTURE_BOX = { width_max: 768, height_max: 256 } as const;

/** Where the picture of the kept image `ref` is read drawn small: fitted by the node to the box. */
export function pictureAddress(ref: string): string {
	return `${fileAddress(ref)}?width_max=${String(PICTURE_BOX.width_max)}&height_max=${String(PICTURE_BOX.height_max)}`;
}
