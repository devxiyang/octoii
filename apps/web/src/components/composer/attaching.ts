/**
 * Attaching files to a draft: each file the person pastes, drops or picks sent to the node at once, shown as it goes,
 * and added to the draft once the node kept it; one the node refused, or no model reads, told and let go of.
 */
import { useState } from "react";
import { useClient } from "@octoii-works/octoii-client/react";
import { type Attachment, givenTypeOf } from "../../core/attachments.ts";
import type { DraftHandle } from "../state/draft.ts";

/** A file on its way to the node: its name, and its picture while it is an image. */
export type Sending = { readonly key: string; readonly name: string; readonly preview: string | undefined };

/** What attaching offers: the files on their way, why the last one failed, adding files, and taking one away. */
export type Attaching = {
	readonly sending: readonly Sending[];
	readonly failure: string | undefined;
	readonly attach: (files: readonly File[]) => void;
	readonly remove: (ref: string) => void;
};

let sent = 0;

/** Attaching files to `draft`. */
export function useAttaching(draft: DraftHandle): Attaching {
	const client = useClient();
	const [sending, setSending] = useState<readonly Sending[]>([]);
	const [failure, setFailure] = useState<string | undefined>(undefined);
	const attach = (files: readonly File[]): void => {
		setFailure(undefined);
		for (const file of files) {
			const mediaType = givenTypeOf(file);
			if (mediaType === undefined) {
				setFailure(`${file.name}: a model reads images, PDFs and text, not this.`);
				continue;
			}
			sent += 1;
			const going: Sending = {
				key: `sending-${String(sent)}`,
				name: file.name,
				preview: file.type.startsWith("image/") ? URL.createObjectURL(file) : undefined,
			};
			setSending((before) => [...before, going]);
			const done = (): void => {
				if (going.preview !== undefined) URL.revokeObjectURL(going.preview);
				setSending((before) => before.filter((each) => each.key !== going.key));
			};
			client.keepFile(file).then(
				(made) => {
					done();
					const attachment: Attachment = { ref: made.ref, media_type: made.media_type ?? mediaType, name: file.name, size: made.size };
					draft.attach(attachment);
				},
				(error: unknown) => {
					done();
					setFailure(`${file.name}: ${error instanceof Error ? error.message : String(error)}`);
				},
			);
		}
	};
	return { sending, failure, attach, remove: draft.detach };
}

/** The files a paste or a drop carries. */
export function filesOf(data: DataTransfer | null): readonly File[] {
	return data === null ? [] : [...data.files];
}
