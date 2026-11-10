/**
 * `/react`: the client's hooks. Each follows what it reads as React's external store, shared by every component that
 * reads it and released after the last one goes, with no effect.
 */
import { createContext, createElement, type ReactNode, useContext, useSyncExternalStore } from "react";
import type { Client } from "../client.ts";
import type { ConnectionStatus } from "../connection.ts";
import type { Settings } from "../protocol.ts";
import { type Conversation, conversationOf } from "../conversation.ts";
import type { Followable, Followed } from "../followed.ts";
import type { ThreadView } from "../thread.ts";
import type { ThreadsView } from "../threads.ts";
import { type Frame, Shelf } from "./shelf.ts";

export type { Frame } from "./shelf.ts";

/** The client and its shelf, as the provider gives them. */
type Provided = { readonly client: Client; readonly shelf: Shelf };

const ClientContext = createContext<Provided | undefined>(undefined);

/** Each client's shelf, made once, so a provider that renders again keeps what its hooks follow. */
const shelves = new WeakMap<Client, Shelf>();

/**
 * Gives the components below it a client, what it follows told them once a frame: `frame` runs a callback as the page
 * next draws.
 */
export function ClientProvider(props: { readonly client: Client; readonly frame: Frame; readonly children: ReactNode }): ReactNode {
	let shelf = shelves.get(props.client);
	if (shelf === undefined) {
		shelf = new Shelf(props.client.clock, props.frame);
		shelves.set(props.client, shelf);
	}
	return createElement(ClientContext.Provider, { value: { client: props.client, shelf } }, props.children);
}

/** The client, for what a component changes: `create`, `deliver`, `stop`, `answer`. */
export function useClient(): Client {
	return useProvided().client;
}

/** Where the connection stands. */
export function useConnection(): ConnectionStatus {
	return useFollowed("status", (client) => followedValue(client.status));
}

/** A thread, as far as the client has read it, followed while a component reads it. */
export function useThread(thread: string): ThreadView {
	return useFollowed(`thread ${thread}`, (client) => client.follow(thread));
}

/** A thread as the interface shows it: its turns, their steps and calls, and what waits on the person, by their ids. */
export function useConversation(thread: string): Conversation {
	return conversationOf(useThread(thread));
}

/** The threads, newest first, watched while a component reads them: none until the node answered. */
export function useThreads(): ThreadsView {
	return useFollowed("threads", (client) => client.watchThreads());
}

/** The settings — the environment's and this device's — watched while a component reads them: none until the node answered. */
export function useSettings(): Settings | undefined {
	return useFollowed("settings", (client) => client.watchSettings());
}

function useProvided(): Provided {
	const value = useContext(ClientContext);
	if (value === undefined) throw new Error("A client hook is used outside ClientProvider");
	return value;
}

/** Follows the key's followable as React's external store, taking it with `take` when the shelf does not hold it. */
function useFollowed<View>(key: string, take: (client: Client) => Followable<View>): View {
	const { client, shelf } = useProvided();
	const binding = shelf.binding(key, () => take(client));
	return useSyncExternalStore(binding.subscribe, binding.snapshot, binding.snapshot);
}

/** A followed value, which its owner keeps: nothing to release. */
function followedValue<T>(followed: Followed<T>): Followable<T> {
	return { view: () => followed.value, subscribe: (listener) => followed.subscribe(listener), release: () => undefined };
}
