/**
 * The channel the node holds the gateway by: JSON-RPC 2.0, a message a line, read from one descriptor and written to
 * another — 3 and 4, as a browser's DevTools pipe is — so what the gateway or an agent prints never enters it. An `http`
 * request carries an HTTP request whole: its method, path, headers and body. What answers it comes back by its id:
 * `http/head` with the status and headers, an `http/body` for each piece of the body as it comes, then the request's
 * result — or its error, where no response could be made at all. `notifications/cancelled` ends a request: its handler's
 * signal is aborted and nothing more is said of it. The channel's end — its input closed, as the node closes it or ends
 * — ends the gateway, as a coprocess ends with its host.
 */
import { type Static, Type } from "typebox";
import type { Json } from "./anthropic.ts";
import { matches } from "./schema.ts";

/** What answers a request: the gateway's own fetch handler, on the request as HTTP. */
export type Handler = (request: Request) => Promise<Response>;

const IdSchema = Type.Union([Type.Number(), Type.String()]);

/** A request's id, as JSON-RPC's are. */
type Id = Static<typeof IdSchema>;

const HttpSchema = Type.Object({ id: IdSchema, method: Type.Literal("http"), params: Type.Unknown() });

/** An HTTP request, as the channel carries it. */
const CarriedSchema = Type.Object({
	method: Type.String(),
	path: Type.String({ pattern: "^/" }),
	headers: Type.Optional(Type.Array(Type.Tuple([Type.String(), Type.String()]))),
	body: Type.Optional(Type.String()),
});

type Carried = Static<typeof CarriedSchema>;

const CancelledSchema = Type.Object({ method: Type.Literal("notifications/cancelled"), params: Type.Object({ requestId: IdSchema }) });

/** JSON-RPC's codes for params that are not what the method takes, and for an error inside the handler. */
const INVALID_PARAMS = -32_602;
const INTERNAL_ERROR = -32_603;

/** The address a carried request's path is read against: the gateway's own, which no network reaches. */
const ORIGIN = "http://gateway";

/**
 * Serves each request of `lines` with `handler`, many at once, writing what answers each with `write`, a line each;
 * ends once the lines end, every request still answering cancelled.
 */
export async function serve(lines: AsyncIterable<string>, write: (line: string) => void, handler: Handler): Promise<void> {
	const running = new Map<string, AbortController>();
	const say = (message: object): void => write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
	for await (const line of lines) {
		const message = jsonOf(line);
		if (matches(CancelledSchema, message)) {
			running.get(keyOf(message.params.requestId))?.abort();
			continue;
		}
		if (!matches(HttpSchema, message)) continue;
		if (!matches(CarriedSchema, message.params)) {
			say({ id: message.id, error: { code: INVALID_PARAMS, message: "an http request names its method and path" } });
			continue;
		}
		const key = keyOf(message.id);
		const controller = new AbortController();
		running.set(key, controller);
		void answer(message.id, message.params, controller.signal, say, handler).finally(() => running.delete(key));
	}
	for (const controller of running.values()) controller.abort();
}

/** Answers the request `id`: its head, its body piece by piece, then its result; nothing more once it is cancelled. */
async function answer(id: Id, carried: Carried, signal: AbortSignal, say: (message: object) => void, handler: Handler): Promise<void> {
	try {
		const request = new Request(`${ORIGIN}${carried.path}`, {
			method: carried.method,
			headers: carried.headers ?? [],
			signal,
			...(carried.body === undefined ? {} : { body: carried.body }),
		});
		const response = await handler(request);
		if (signal.aborted) {
			await response.body?.cancel();
			return;
		}
		say({ method: "http/head", params: { id, status: response.status, headers: [...response.headers] } });
		if (response.body !== null) await pass(id, response.body, signal, say);
		if (!signal.aborted) say({ id, result: {} });
	} catch (error) {
		if (!signal.aborted) say({ id, error: { code: INTERNAL_ERROR, message: error instanceof Error ? error.message : String(error) } });
	}
}

/** Passes on the body of the response to `id` piece by piece, as text, till it ends or the request is cancelled. */
async function pass(id: Id, body: ReadableStream<Uint8Array>, signal: AbortSignal, say: (message: object) => void): Promise<void> {
	const reader = body.getReader();
	const decoder = new TextDecoder();
	const onAbort = (): void => {
		reader.cancel().catch(() => undefined);
	};
	signal.addEventListener("abort", onAbort, { once: true });
	try {
		for (;;) {
			const read = await reader.read();
			if (read.done || signal.aborted) break;
			const data = decoder.decode(read.value, { stream: true });
			if (data.length > 0) say({ method: "http/body", params: { id, data } });
		}
	} finally {
		signal.removeEventListener("abort", onAbort);
	}
	const rest = decoder.decode();
	if (rest.length > 0 && !signal.aborted) say({ method: "http/body", params: { id, data: rest } });
}

/** The JSON a line holds; null for one that holds none, which no message matches. */
function jsonOf(line: string): Json {
	try {
		return JSON.parse(line);
	} catch {
		return null;
	}
}

/** A request's id as a key of the requests running: its kind with it, as 7 and "7" are two ids. */
function keyOf(id: Id): string {
	return `${typeof id}:${String(id)}`;
}
