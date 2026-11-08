/**
 * The page at the app's address reaches a computer through a tunnel: this browser's key and the computer it is paired
 * with kept in its storage, one session to that computer at a time, lasting as long as the WebSocket on it.
 */
import { matches, type WebSocketLike } from "@octoii-works/octoii-client";
import { Type } from "typebox";
import { pairBrowser } from "../app/pairing.ts";
import type { Reach, SendRequest } from "../components/state/reach.ts";
import { type RemoteMachine, remotePairingOf } from "../core/pairing.ts";
import { Tunnel, type TunnelSocket } from "../../vendor/tunnel/tunnel.js";
import tunnelModule from "../../vendor/tunnel/tunnel.wasm";
import { createFileSources } from "./file-sources.ts";

const SEED_ITEM = "octoii.device-seed";
const MACHINE_ITEM = "octoii.machine";
const SEED_BYTES = 32;

const MachineSchema = Type.Object({ relay: Type.String(), key: Type.String() });

/** Why the computer cannot be reached, whichever it was: the relay does not tell a computer off from one that left. */
const AWAY = "Can't reach your computer. It may be off or asleep, or Octoii is not running on it. Trying again…";

/** The hex of `bytes`. */
function hexOf(bytes: Uint8Array): string {
	return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** The bytes of `hex`. */
function bytesOf(hex: string): Uint8Array {
	return Uint8Array.from(hex.match(/../g) ?? [], (pair) => Number.parseInt(pair, 16));
}

/** The seed of this browser's key, made the first time it is asked for. */
function deviceSeed(): Uint8Array {
	const kept = localStorage.getItem(SEED_ITEM);
	if (kept !== null && kept.length === SEED_BYTES * 2) return bytesOf(kept);
	const made = crypto.getRandomValues(new Uint8Array(SEED_BYTES));
	localStorage.setItem(SEED_ITEM, hexOf(made));
	return made;
}

/** The computer this browser is paired with; none where it has none. */
function pairedMachine(): RemoteMachine | undefined {
	const kept = localStorage.getItem(MACHINE_ITEM);
	if (kept === null) return undefined;
	try {
		const told: unknown = JSON.parse(kept);
		return matches(MachineSchema, told) ? told : undefined;
	} catch {
		return undefined;
	}
}

/** The compiled session, compiled once. */
let compiled: Promise<WebAssembly.Module> | undefined;

function compiledModule(): Promise<WebAssembly.Module> {
	compiled ??= WebAssembly.compileStreaming(fetch(new URL(tunnelModule, import.meta.url)));
	return compiled;
}

/** A listener of a socket. */
type SocketListener = (event: { readonly data: unknown }) => void;

/** The protocol's socket as the client takes it, until the tunnel's WebSocket is open behind it. */
class PageSocket implements WebSocketLike {
	readonly #listeners = { open: new Set<SocketListener>(), close: new Set<SocketListener>(), message: new Set<SocketListener>() };
	#socket: TunnelSocket | undefined;
	#closed = false;

	addEventListener(type: "open" | "close", listener: () => void): void;
	addEventListener(type: "message", listener: SocketListener): void;
	addEventListener(type: "open" | "close" | "message", listener: SocketListener): void {
		this.#listeners[type].add(listener);
	}

	send(data: string): void {
		this.#socket?.send(data);
	}

	close(): void {
		if (this.#closed) return;
		this.#socket?.close();
		this.dropped();
	}

	/** The tunnel's WebSocket is open behind this one. */
	joined(socket: TunnelSocket): void {
		if (this.#closed) return socket.close();
		this.#socket = socket;
		socket.onmessage = (data) => this.#tell("message", data);
		socket.onclose = () => this.dropped();
		this.#tell("open", undefined);
	}

	/** This socket is over: closed, or no tunnel's WebSocket opened behind it. */
	dropped(): void {
		if (this.#closed) return;
		this.#closed = true;
		this.#tell("close", undefined);
	}

	#tell(type: "open" | "close" | "message", data: unknown): void {
		for (const listener of this.#listeners[type]) listener({ data });
	}
}

/** The reach of the page at the app's address, and whether this browser has a computer to reach. */
export function tunnelReach(about: string): { readonly reach: Reach; readonly paired: () => boolean } {
	let machine = pairedMachine();
	let session: Promise<Tunnel> | undefined;
	let away: string | undefined;
	const letGo = (): void => {
		const going = session;
		session = undefined;
		void going?.then(
			(tunnel) => tunnel.close(),
			() => undefined,
		);
	};
	const tunnel = (): Promise<Tunnel> => {
		const target = machine;
		if (target === undefined) return Promise.reject(new Error("This browser is paired with no computer."));
		if (session !== undefined) return session;
		const opening = compiledModule().then((module) => Tunnel.open({ module, relay: target.relay, machine: target.key, seed: deviceSeed() }));
		session = opening;
		void opening.catch(() => {
			if (session === opening) session = undefined;
		});
		return opening;
	};
	const client = { "user-agent": navigator.userAgent };
	const send: SendRequest = async ({ method, path, contentType, body }) => {
		const reached = await tunnel();
		const given = body === undefined ? {} : { body: typeof body === "string" ? body : new Uint8Array(await body.arrayBuffer()) };
		const answer = await reached.request(method, path, {
			headers: { ...client, ...(contentType === undefined ? {} : { "content-type": contentType }) },
			...given,
		});
		return { status: answer.status, contentType: answer.headers.get("content-type") ?? undefined, bytes: answer.body };
	};
	const open = (): WebSocketLike => {
		const page = new PageSocket();
		page.addEventListener("close", letGo);
		tunnel()
			.then((reached) => reached.socket("/ws", { headers: client }))
			.then(
				(socket) => {
					away = undefined;
					page.joined(socket);
				},
				() => {
					away = AWAY;
					page.dropped();
				},
			);
		return page;
	};
	const pair = async (text: string): Promise<void> => {
		const given = remotePairingOf(text);
		if (given === undefined) throw new Error("That is no pairing link.");
		const before = machine;
		machine = given.machine;
		letGo();
		try {
			await pairBrowser(send, given.credential);
		} catch (error) {
			machine = before;
			letGo();
			throw error;
		}
		localStorage.setItem(MACHINE_ITEM, JSON.stringify(given.machine));
		// Kept through the browser's clearing of storage, where it agrees to, as a lost key means pairing again.
		void navigator.storage.persist().catch(() => false);
	};
	const reach: Reach = {
		open,
		send,
		linkExample: "https://app.octoii.com/pair#relay=…",
		readsLink: (text) => remotePairingOf(text) !== undefined,
		pair,
		fileSource: createFileSources((address) => send({ method: "GET", path: address })),
		whyAway: () => away,
		about,
	};
	return { reach, paired: () => machine !== undefined };
}
