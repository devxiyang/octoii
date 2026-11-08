/**
 * Pairing this browser with the node: a link's credential sent once to the node, which keeps a session for the browser —
 * in a cookie the page cannot read, at the node's own address; by the device's key, through a tunnel.
 */
import { matches } from "@octoii-works/octoii-client";
import { Type } from "typebox";
import { jsonOf, type SendRequest, succeeded } from "../components/state/reach.ts";

/** Where the node redeems a link for a browser's session. */
const SESSION_PATH = "/api/auth/session";

const RefusalSchema = Type.Object({ message: Type.String() });

/** Pairs this browser with the node by `credential`; rejects with the node's words where it refuses. */
export async function pairBrowser(send: SendRequest, credential: string): Promise<void> {
	const answer = await send({ method: "POST", path: SESSION_PATH, contentType: "application/json", body: JSON.stringify({ credential }) });
	if (succeeded(answer)) return;
	const refusal = jsonOf(answer);
	throw new Error(matches(RefusalSchema, refusal) ? refusal.message : `The node refused the pairing (${String(answer.status)}).`);
}
