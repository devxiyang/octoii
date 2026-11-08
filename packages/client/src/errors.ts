/** What went wrong, as the client tells the interface: the node's refusal, or the connection's. */

/** The client's own codes, beside those the node refuses with, as `not-admitted` and `no-such-thread`. */
export type ClientCode =
	/** The connection dropped before the answer came. */
	| "connection-lost"
	/** No connection is open. */
	| "not-connected"
	/** The client was closed. */
	| "closed"
	/** The app gave the client no way to do it, as one that sends no files. */
	| "unsupported"
	/** The node sent what the protocol does not hold. */
	| "invalid-answer";

/** An error of the client, by its code: the node's, or the client's own. */
export class ClientError extends Error {
	readonly code: string;

	constructor(code: string, message: string, options?: ErrorOptions) {
		super(message, options);
		this.name = "ClientError";
		this.code = code;
	}
}

/** The client's own error. */
export function clientError(code: ClientCode, message: string, options?: ErrorOptions): ClientError {
	return new ClientError(code, message, options);
}

/** The codes that say the connection, not the method, failed: what is asked again on the next connection. */
const CONNECTION_CODES: ReadonlySet<string> = new Set<ClientCode>(["connection-lost", "not-connected"]);

/** Whether an error is the connection's, so what failed is asked again. */
export function isConnectionError(error: unknown): boolean {
	return error instanceof ClientError && CONNECTION_CODES.has(error.code);
}
