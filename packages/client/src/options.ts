/** What a client takes from its app: how it reaches the node, as the session it holds, and what the platform gives. */

/** What a socket gives the client: the platform's WebSocket, as a browser, Bun and Node have it, its messages text. */
export type WebSocketLike = {
	send(data: string): void;
	close(): void;
	addEventListener(type: "open" | "close", listener: () => void): void;
	addEventListener(type: "message", listener: (event: { readonly data: unknown }) => void): void;
};

/** The clock the client waits by: the time, and a timer it can cancel. */
export type Clock = { now(): number; setTimer(callback: () => void, ms: number): () => void };

/** What `createClient` takes. */
export type ClientOptions = {
	/**
	 * Opens a socket to the node, as `new WebSocket(url)` does, authenticated as the session the app holds: a browser's
	 * page by its session cookie, which the browser sends itself; a program by its bearer token, in the socket's headers.
	 */
	readonly open: () => WebSocketLike;
	/** Mints the id of an operation done once, as `crypto.randomUUID` does. */
	readonly randomUUID: () => string;
	readonly clock: Clock;
	/** What fails no caller: what the node sends that the protocol does not hold, or a thread it could not follow. */
	readonly report: (error: unknown) => void;
	/** How many of a thread's latest entries the client keeps, more only while a reader reads further back; `ENTRIES_KEPT` where none is named. */
	readonly entriesKept?: number;
	/**
	 * Sends a file's bytes to the node to keep, as a POST to its `/files` does, authenticated as `open` is: the
	 * reference a message names the file by, its size, and what an image became; none where the app sends no files.
	 */
	readonly keepFile?: (bytes: Blob) => Promise<KeptFile>;
};

/**
 * A file the node keeps: the reference a message names it by, its size in bytes, and, where it is an image, what it
 * became as it was fitted to what models read — any other file kept as it came, what it is the sender's to say.
 */
export type KeptFile = { readonly ref: string; readonly size: number; readonly media_type?: string };
