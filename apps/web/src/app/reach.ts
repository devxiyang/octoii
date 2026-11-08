/**
 * The page a node serves reaches it at the page's own address: the WebSocket and its requests go there with the session
 * cookie the browser holds for the node, and the browser fetches a kept file itself.
 */
import { pairingCredentialOf } from "../core/pairing.ts";
import type { Reach, SendRequest } from "../components/state/reach.ts";
import { pairBrowser } from "./pairing.ts";

/** The node's WebSocket, at the page's own address. */
function socketAddress(): string {
	return `${window.location.protocol === "https:" ? "wss" : "ws"}://${window.location.host}/ws`;
}

const send: SendRequest = async ({ method, path, contentType, body }) => {
	const answer = await fetch(path, {
		method,
		credentials: "same-origin",
		...(contentType === undefined ? {} : { headers: { "content-type": contentType } }),
		...(body === undefined ? {} : { body }),
	});
	return { status: answer.status, contentType: answer.headers.get("content-type") ?? undefined, bytes: new Uint8Array(await answer.arrayBuffer()) };
};

/** The reach of the page a node serves. */
export const sameOrigin: Reach = {
	open: () => new WebSocket(socketAddress()),
	send,
	linkExample: "http://127.0.0.1:7600/pair#token=…",
	readsLink: (text) => pairingCredentialOf(text) !== undefined,
	pair: async (text) => {
		const credential = pairingCredentialOf(text);
		if (credential === undefined) throw new Error("That is no pairing link.");
		await pairBrowser(send, credential);
	},
};
