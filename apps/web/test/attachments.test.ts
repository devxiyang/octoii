/** The files a message gives its model: what each is given as, how a message holds them, and how they are read back. */
import { describe, expect, it } from "bun:test";
import { type Attachment, attachmentsOf, contentOf, givenTypeOf, sizeLabel } from "../src/core/attachments.ts";

const image: Attachment = { ref: "sha256:aa", media_type: "image/png", name: "shot.png", size: 2048 };
const pdf: Attachment = { ref: "sha256:bb", media_type: "application/pdf", name: "spec.pdf", size: 3 * 1024 * 1024 };

describe("a file attached", () => {
	it("is given as what a model reads: its own type, Markdown or plain text by its name, else refused", () => {
		expect(givenTypeOf({ type: "image/png", name: "a.png" })).toBe("image/png");
		expect(givenTypeOf({ type: "application/pdf", name: "a.pdf" })).toBe("application/pdf");
		expect(givenTypeOf({ type: "", name: "README.md" })).toBe("text/markdown");
		expect(givenTypeOf({ type: "", name: "main.zig" })).toBe("text/plain");
		expect(givenTypeOf({ type: "text/x-python", name: "a.py" })).toBe("text/plain");
		expect(givenTypeOf({ type: "application/zip", name: "a.zip" })).toBeUndefined();
		expect(sizeLabel(2048)).toBe("2 KB");
		expect(sizeLabel(pdf.size)).toBe("3.0 MB");
	});
});

describe("a message with files", () => {
	it("is sent as its words, then each file by its reference; read back, its files are those it names", () => {
		expect(contentOf("hi", [])).toBe("hi");
		const content = contentOf("look", [image, pdf]);
		expect(content).toEqual([
			{ type: "input_text", text: "look" },
			{ type: "input_image", detail: "auto", octoii: { ref: "sha256:aa", media_type: "image/png", filename: "shot.png" } },
			{ type: "input_file", filename: "spec.pdf", octoii: { ref: "sha256:bb", media_type: "application/pdf", filename: "spec.pdf" } },
		]);
		expect(contentOf("", [image])).toEqual([
			{ type: "input_image", detail: "auto", octoii: { ref: "sha256:aa", media_type: "image/png", filename: "shot.png" } },
		]);
		expect(attachmentsOf({ role: "user", content }).map((each) => [each.ref, each.media_type, each.name])).toEqual([
			["sha256:aa", "image/png", "shot.png"],
			["sha256:bb", "application/pdf", "spec.pdf"],
		]);
		expect(attachmentsOf({ role: "user", content: "words alone" })).toEqual([]);
	});
});
