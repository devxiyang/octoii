/**
 * The files a message gives its model, as the person attaches them: each kept by the node by its content, named by
 * its reference; an image, a PDF, or text — what a model reads — its type told with it, as its bytes alone may not tell
 * it. A message with files is sent as parts, its words first, then each file; read back, a message's files are those
 * parts that name a kept file.
 */
import { matches } from "@octoii-works/octoii-client";
import { Type } from "typebox";

/** A file given with a message: its reference, what it is, its name and its size in bytes. */
export type Attachment = { readonly ref: string; readonly media_type: string; readonly name: string; readonly size: number };

/** The images a model looks at. */
const IMAGE_TYPES: readonly string[] = ["image/png", "image/jpeg", "image/gif", "image/webp"];

/** The other files a model reads: a PDF, or text. */
const FILE_TYPES: readonly string[] = ["application/pdf", "text/plain", "text/markdown", "text/csv", "text/html", "application/json", "application/xml"];

/** The names of text files a browser types as nothing, or as something else, by their extension: given as plain text. */
const TEXT_EXTENSIONS: readonly string[] = [
	"txt",
	"log",
	"md",
	"zig",
	"ts",
	"tsx",
	"js",
	"jsx",
	"py",
	"rs",
	"go",
	"c",
	"h",
	"cpp",
	"java",
	"kt",
	"swift",
	"sh",
	"toml",
	"yaml",
	"yml",
	"ini",
	"sql",
	"css",
];

/** Whether a file is an image, which the timeline shows as it is. */
export function isImage(mediaType: string): boolean {
	return IMAGE_TYPES.includes(mediaType);
}

/** What a file is given to a model as: its own type where a model takes it, Markdown or plain text by its name; none where a model reads no such file. */
export function givenTypeOf(file: { readonly type: string; readonly name: string }): string | undefined {
	if (IMAGE_TYPES.includes(file.type) || FILE_TYPES.includes(file.type)) return file.type;
	const extension = file.name.includes(".") ? (file.name.split(".").at(-1)?.toLowerCase() ?? "") : "";
	if (extension === "md") return "text/markdown";
	if (file.type.startsWith("text/") || TEXT_EXTENSIONS.includes(extension)) return "text/plain";
	return undefined;
}

/** A part of a message as it is sent: its words, or a kept file. */
type Part =
	| { readonly type: "input_text"; readonly text: string }
	| { readonly type: "input_image"; readonly detail: "auto"; readonly octoii: FileExtension }
	| { readonly type: "input_file"; readonly filename: string; readonly octoii: FileExtension };

/** How a part names a kept file: its reference, what it is, and its name. */
type FileExtension = { readonly ref: string; readonly media_type: string; readonly filename: string };

/** A message's content: its words alone where it gives no file, else its words first, then each file. */
export function contentOf(text: string, attachments: readonly Attachment[]): string | Part[] {
	if (attachments.length === 0) return text;
	const files = attachments.map((attachment): Part => {
		const octoii = { ref: attachment.ref, media_type: attachment.media_type, filename: attachment.name };
		return isImage(attachment.media_type) ? { type: "input_image", detail: "auto", octoii } : { type: "input_file", filename: attachment.name, octoii };
	});
	return text.trim() === "" ? files : [{ type: "input_text", text }, ...files];
}

const KeptSchema = Type.Object({
	octoii: Type.Object({ ref: Type.String(), media_type: Type.Optional(Type.String()), filename: Type.Optional(Type.String()) }),
});
const MessagePartsSchema = Type.Object({ content: Type.Array(Type.Unknown()) });

/** The files a message gives: each part of it that names a kept file. */
export function attachmentsOf(message: unknown): readonly Attachment[] {
	if (!matches(MessagePartsSchema, message)) return [];
	return message.content.flatMap((part) => {
		if (!matches(KeptSchema, part)) return [];
		const { ref, media_type: mediaType, filename } = part.octoii;
		return [{ ref, media_type: mediaType ?? "application/octet-stream", name: filename ?? "file", size: 0 }];
	});
}

/** Where a kept file is read back from. */
export function fileAddress(ref: string): string {
	return `/files/${ref}`;
}

/** A file's size as the person reads it. */
export function sizeLabel(bytes: number): string {
	if (bytes < 1024) return `${String(bytes)} B`;
	if (bytes < 1024 * 1024) return `${String(Math.round(bytes / 1024))} KB`;
	return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}
