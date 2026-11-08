/**
 * How the page reaches its node: the one thing that differs between the page a node serves, which is at the node's own
 * address, and the page at the app's address, which reaches a computer through its tunnel. The protocol's socket, the
 * requests beside it, pairing and the files it shows all go by this.
 */
import { createContext, useContext } from "react";
import type { WebSocketLike } from "@octoii-works/octoii-client";
import type { Json } from "../../core/asks.ts";

/** A request of the node's beside its socket. */
export type NodeRequest = {
	readonly method: "GET" | "POST";
	readonly path: string;
	readonly contentType?: string;
	readonly body?: string | Blob;
};

/** What the node answered a request with. */
export type NodeAnswer = { readonly status: number; readonly contentType: string | undefined; readonly bytes: Uint8Array };

/** Sends a request to the node. */
export type SendRequest = (request: NodeRequest) => Promise<NodeAnswer>;

/** How a page reaches its node. */
export type Reach = {
	/** Opens the protocol's socket. */
	readonly open: () => WebSocketLike;
	readonly send: SendRequest;
	/** What a pairing link looks like here, for the field that takes one. */
	readonly linkExample: string;
	/** Whether `text` is a pairing link or credential this page can pair by. */
	readonly readsLink: (text: string) => boolean;
	/** Pairs this browser by what `text` gives; rejects with the node's words where it refuses. */
	readonly pair: (text: string) => Promise<void>;
	/** Where the page reads a kept file at `address` from, where a browser cannot fetch it itself. */
	readonly fileSource?: (address: string) => Promise<string>;
	/** Why the node cannot be reached now, where the page knows. */
	readonly whyAway?: () => string | undefined;
	/** Where a visitor learns what this is, where the page has no node of its own. */
	readonly about?: string;
};

/** The page's reach, as the entry gives it. */
export const ReachContext = createContext<Reach | undefined>(undefined);

/** The page's reach. */
export function useReach(): Reach {
	const reach = useContext(ReachContext);
	if (reach === undefined) throw new Error("The page has no reach of its node");
	return reach;
}

/** Whether the node answered `answer` with success. */
export function succeeded(answer: NodeAnswer): boolean {
	return answer.status >= 200 && answer.status < 300;
}

/** The JSON of `answer`; none where it holds none. */
export function jsonOf(answer: NodeAnswer): Json | undefined {
	try {
		// SAFETY: what JSON.parse gives is JSON.
		return JSON.parse(new TextDecoder().decode(answer.bytes)) as Json;
	} catch {
		return undefined;
	}
}
