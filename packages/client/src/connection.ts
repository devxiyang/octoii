/**
 * The connection: one WebSocket to the node, opened as the client starts and again after it drops, waiting longer after
 * each drop up to a bound, the socket authenticated as the app opens it; `hello` first, which names the protocol's
 * version and is answered with the session the node knows the client by and its scopes. What comes is read in order: an
 * answer settles the call of its id, checked against the method's result; an event goes to the client, which follows
 * its threads again on each connection that opens.
 */
import { RECONNECT_MAX_MS, RECONNECT_MIN_MS } from "./constants.ts";
import { ClientError, clientError, isConnectionError } from "./errors.ts";
import { Value } from "./followed.ts";
import type { ClientOptions, WebSocketLike } from "./options.ts";
import { type Event, METHODS, type MethodName, type ParamsOf, PROTOCOL_VERSION, ReceivedSchema, type ResultOf, type Scope } from "./protocol.ts";
import { parsed } from "./std/schema.ts";

/** Where the connection stands. */
export type ConnectionStatus =
	| { readonly status: "connecting"; readonly attempt: number }
	| { readonly status: "open"; readonly session: string; readonly scopes: readonly Scope[]; readonly environment: string | undefined }
	| { readonly status: "waiting"; readonly until: number; readonly error?: ClientError }
	| { readonly status: "stopped"; readonly error: ClientError };

/** What the connection tells its client: each time one opens, and each event the node sends. */
export type ConnectionHandlers = { readonly opened: () => void; readonly event: (event: Event) => void };

/** What settles a call: the result the node answered with, or why there is none. */
type Settle = (answer: { readonly result: unknown } | { readonly error: ClientError }) => void;

/** One connection, opened again after it drops, until it is stopped. */
export class Connection {
	readonly status = new Value<ConnectionStatus>({ status: "connecting", attempt: 1 });
	readonly #options: ClientOptions;
	readonly #handlers: ConnectionHandlers;
	readonly #pending = new Map<string, Settle>();
	#socket: WebSocketLike | undefined;
	#cancelWait: (() => void) | undefined;
	/** The drops since a connection last opened: the next wait doubles with each. */
	#drops = 0;
	#counter = 0;
	/** Why the last attempt did not open, told while the connection waits. */
	#lastError: ClientError | undefined;

	constructor(options: ClientOptions, handlers: ConnectionHandlers) {
		this.#options = options;
		this.#handlers = handlers;
	}

	start(): void {
		this.#connect();
	}

	/** Calls a method on the open connection: its result; rejects with `not-connected` where none is open. */
	call<Name extends MethodName>(method: Name, params: ParamsOf<Name>): Promise<ResultOf<Name>> {
		if (this.status.value.status !== "open") return Promise.reject(clientError("not-connected", "No connection to the node is open."));
		return this.#ask(method, params);
	}

	/**
	 * Calls a method once a connection is open, and again on the next where it drops before the answer: for a method done
	 * once however often it is asked, as an operation's id makes it. Rejects where the client stopped, or with the node's
	 * error.
	 */
	async callOpen<Name extends MethodName>(method: Name, params: ParamsOf<Name>): Promise<ResultOf<Name>> {
		for (;;) {
			await this.#ready();
			try {
				return await this.call(method, params);
			} catch (error) {
				if (!isConnectionError(error)) throw error;
			}
		}
	}

	/** Stops connecting for good: the client is closed. */
	close(): void {
		this.#stop(clientError("closed", "The client was closed."));
	}

	/** Sends a method on the socket that is now the connection's; its answer, read in order, settles it. */
	#ask<Name extends MethodName>(method: Name, params: ParamsOf<Name>): Promise<ResultOf<Name>> {
		return new Promise((resolve, reject) => {
			const id = String(++this.#counter);
			this.#pending.set(id, (answer) => {
				if ("error" in answer) return reject(answer.error);
				try {
					resolve(parsed<(typeof METHODS)[Name]["result"]>(METHODS[method].result, answer.result, `${method}'s result`));
				} catch (error) {
					reject(clientError("invalid-answer", `The node answered ${method} with what the protocol does not hold.`, { cause: error }));
				}
			});
			this.#socket?.send(JSON.stringify({ id, method, params }));
		});
	}

	#ready(): Promise<void> {
		return new Promise((resolve, reject) => {
			const settled = (): boolean => {
				const now = this.status.value;
				if (now.status === "open") resolve();
				else if (now.status === "stopped") reject(now.error);
				else return false;
				return true;
			};
			if (settled()) return;
			const stop = this.status.subscribe(() => {
				if (settled()) stop();
			});
		});
	}

	#connect(): void {
		this.status.set({ status: "connecting", attempt: this.#drops + 1 });
		const socket = this.#options.open();
		this.#socket = socket;
		socket.addEventListener("open", () => {
			if (this.#socket === socket) this.#hello();
		});
		socket.addEventListener("message", (event) => {
			if (this.#socket === socket) this.#receive(event.data);
		});
		socket.addEventListener("close", () => this.#dropped(socket));
	}

	/** Says hello; its answer, read in order, opens the connection as the session it names, or says why it did not. */
	#hello(): void {
		this.#ask("hello", { protocol: PROTOCOL_VERSION }).then(
			(greeted) => this.#welcomed(greeted),
			(error: unknown) => this.#refused(error),
		);
	}

	#welcomed(greeted: ResultOf<"hello">): void {
		this.#drops = 0;
		this.#lastError = undefined;
		this.status.set({ status: "open", session: greeted.session, scopes: greeted.scopes, environment: greeted.environment?.name });
		this.#handlers.opened();
	}

	/** `hello` refused: a version the node does not speak stops the client; anything else closes, and the wait says why. */
	#refused(error: unknown): void {
		const refusal =
			error instanceof ClientError ? error : clientError("invalid-answer", "The node answered hello with what the protocol does not hold.", { cause: error });
		if (refusal.code === "protocol") return this.#stop(refusal);
		this.#lastError = refusal;
		this.#socket?.close();
	}

	/** Takes one message the node sent: an answer settles its call, an event goes to the client. */
	#receive(data: unknown): void {
		let received;
		try {
			received = parsed(ReceivedSchema, JSON.parse(String(data)), "a message of the node's");
		} catch (error) {
			return this.#options.report(error);
		}
		if ("event" in received) return this.#handlers.event(received);
		const refused = "error" in received ? new ClientError(received.error.code, received.error.message) : undefined;
		// A message whose id the node could not read is answered by none, and fails no call.
		if (received.id === null) return this.#options.report(refused);
		const settle = this.#pending.get(received.id);
		if (settle === undefined) return this.#options.report(clientError("invalid-answer", `An answer came for no call of this connection: ${received.id}.`));
		this.#pending.delete(received.id);
		settle(refused === undefined ? { result: "result" in received ? received.result : undefined } : { error: refused });
	}

	/** The socket closed: each call waiting on it fails as lost, and the connection waits, longer after each drop, to connect again. */
	#dropped(socket: WebSocketLike): void {
		if (this.#socket !== socket) return;
		this.#socket = undefined;
		this.#failPending(clientError("connection-lost", "The connection to the node dropped before the answer came."));
		if (this.status.value.status === "stopped") return;
		const wait = Math.min(RECONNECT_MAX_MS, RECONNECT_MIN_MS * 2 ** this.#drops);
		this.#drops += 1;
		const until = this.#options.clock.now() + wait;
		this.status.set(this.#lastError === undefined ? { status: "waiting", until } : { status: "waiting", until, error: this.#lastError });
		this.#cancelWait = this.#options.clock.setTimer(() => {
			this.#cancelWait = undefined;
			this.#connect();
		}, wait);
	}

	#stop(error: ClientError): void {
		if (this.status.value.status === "stopped") return;
		this.status.set({ status: "stopped", error });
		this.#cancelWait?.();
		this.#cancelWait = undefined;
		const socket = this.#socket;
		this.#socket = undefined;
		this.#failPending(error);
		socket?.close();
	}

	#failPending(error: ClientError): void {
		const pending = [...this.#pending.values()];
		this.#pending.clear();
		for (const settle of pending) settle({ error });
	}
}
