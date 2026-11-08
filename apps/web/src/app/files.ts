/**
 * Files sent to the node with a message: a file's bytes posted to the node's `/files`, which keeps them by their content
 * and answers with the reference the message names them by, as JSON carries bytes badly.
 */
import { type KeptFile, matches } from "@octoii-works/octoii-client";
import { Type } from "typebox";
import { jsonOf, type SendRequest, succeeded } from "../components/state/reach.ts";

/** Where the node keeps files. */
const FILES_PATH = "/files";

const KeptSchema = Type.Object({ ref: Type.String(), size: Type.Number(), media_type: Type.Optional(Type.String()) });
const RefusalSchema = Type.Object({ message: Type.String() });

/**
 * Sends `bytes` to the node to keep: its reference, its size and what an image became; rejects with the node's words
 * where it refuses them.
 */
export async function keepFile(send: SendRequest, bytes: Blob): Promise<KeptFile> {
	const answer = await send({ method: "POST", path: FILES_PATH, body: bytes });
	const told = jsonOf(answer);
	if (succeeded(answer) && matches(KeptSchema, told)) return told;
	throw new Error(matches(RefusalSchema, told) ? told.message : `The node did not keep the file (${String(answer.status)}).`);
}
