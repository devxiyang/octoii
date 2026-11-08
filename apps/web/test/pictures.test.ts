/** The pictures the timeline draws: the images a message gave, those a paragraph of Markdown names, and where a kept one is read drawn small. */
import { describe, expect, it } from "bun:test";
import type { Attachment } from "../src/core/attachments.ts";
import { pictureAddress, picturesGiven, picturesOfParagraph } from "../src/core/pictures.ts";

/** An image of a paragraph, and its words, as the page is given them. */
type Image = {
	readonly type: "element";
	readonly tagName: "img";
	readonly properties: { readonly src: string; readonly alt?: string };
	readonly children: readonly [];
};
type Text = { readonly type: "text"; readonly value: string };
const image = (src: string, alt?: string): Image => ({ type: "element", tagName: "img", properties: alt === undefined ? { src } : { src, alt }, children: [] });
const text = (value: string): Text => ({ type: "text", value });

describe("a picture", () => {
	it("is a message's image by its name, kept by the node", () => {
		const given: readonly Attachment[] = [
			{ ref: "sha256:d", media_type: "image/jpeg", name: "photo.jpg", size: 0 },
			{ ref: "sha256:e", media_type: "application/pdf", name: "spec.pdf", size: 0 },
		];
		expect(picturesGiven(given)).toEqual([{ kind: "kept", ref: "sha256:d", name: "photo.jpg" }]);
	});

	it("is each image a paragraph holds where it holds images of the machine's files alone, by its words or its file's name", () => {
		const breakLine = { type: "element", tagName: "br", properties: {}, children: [] };
		expect(picturesOfParagraph([image("shots/before.png", "Before"), text("\n"), breakLine, image("/tmp/after.png")])).toEqual([
			{ kind: "file", path: "shots/before.png", name: "Before" },
			{ kind: "file", path: "/tmp/after.png", name: "after.png" },
		]);
		expect(picturesOfParagraph([text("See "), image("a.png")])).toBeUndefined();
		expect(picturesOfParagraph([image("https://example.com/a.png")])).toBeUndefined();
		expect(picturesOfParagraph([text(" ")])).toBeUndefined();
	});

	it("kept, is read drawn small from the node, fitted to a box of twice a tile's pixels", () => {
		expect(pictureAddress("sha256:a")).toBe("/files/sha256:a?width_max=768&height_max=256");
	});
});
