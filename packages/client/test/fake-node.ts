/**
 * A node in memory, as a test speaks to it: it admits a client as the session its sockets hold, makes threads and delivers inputs once
 * for each operation's id, feeds what a client follows from where its reader stands, and drops its connections when
 * the test says. Messages go both ways a microtask later, as a socket's do; `settle` lets them all arrive.
 */
import type { Clock, Cursor, Entry, Listed, Settings, State, WebSocketLike } from "../src/index.ts";

/** A message as a client sends it. */
type Asked = { readonly id: string; readonly method: string; readonly params?: Record<string, unknown> };

/** A thread the node keeps: its title, and its log. */
type Kept = { readonly title: string | undefined; readonly entries: Entry[] };

/** Lets every message on its way arrive, and whatever each makes happen. */
export async function settle(): Promise<void> {
	for (let turn = 0; turn < 20; turn++) await Promise.resolve();
}

/** A clock the test moves: timers fire as it passes them. */
export class FakeClock implements Clock {
	#now = 1_000;
	#timers: { at: number; callback: () => void }[] = [];

	now(): number {
		return this.#now;
	}

	setTimer(callback: () => void, ms: number): () => void {
		const timer = { at: this.#now + ms, callback };
		this.#timers.push(timer);
		return () => {
			this.#timers = this.#timers.filter((each) => each !== timer);
		};
	}

	/** Moves the time on by `ms`, firing each timer it passes. */
	advance(ms: number): void {
		this.#now += ms;
		const due = this.#timers.filter((timer) => timer.at <= this.#now);
		this.#timers = this.#timers.filter((timer) => timer.at > this.#now);
		for (const timer of due) timer.callback();
	}
}

/** What a socket calls as something happens to it: an event, its data for a message alone. */
type Listener = (event: { readonly data: unknown }) => void;

/** One end of a connection: the client's socket, whose other end is the node. */
class FakeSocket implements WebSocketLike {
	readonly node: FakeNode;
	readonly #listeners = { open: new Set<Listener>(), close: new Set<Listener>(), message: new Set<Listener>() };
	closed = false;

	constructor(node: FakeNode) {
		this.node = node;
	}

	addEventListener(type: "open" | "close", listener: () => void): void;
	addEventListener(type: "message", listener: (event: { readonly data: unknown }) => void): void;
	addEventListener(type: "open" | "close" | "message", listener: Listener): void {
		this.#listeners[type].add(listener);
	}

	send(data: string): void {
		if (this.closed) return;
		queueMicrotask(() => this.node.receive(this, data));
	}

	close(): void {
		if (this.closed) return;
		this.closed = true;
		queueMicrotask(() => {
			for (const listener of this.#listeners.close) listener({ data: undefined });
		});
	}

	opened(): void {
		for (const listener of this.#listeners.open) listener({ data: undefined });
	}

	/** Gives the client `data`, a microtask later. */
	deliver(data: string): void {
		if (this.closed) return;
		queueMicrotask(() => {
			for (const listener of this.#listeners.message) listener({ data });
		});
	}
}

export class FakeNode {
	/** The session the node's sockets are opened as; none, a client that holds no session. */
	session: string | undefined = "s1";
	/** What the node answers hello with: a client admitted, or the protocol's version refused. */
	greeting: "admit" | "refuse-protocol" = "admit";
	/** A method whose message drops the connection once it is done, before its answer is sent. */
	dropAfter: string | undefined;
	/** Every message the node received, in order. */
	readonly received: Asked[] = [];
	/** Where each follow began: the thread, and the cursor it was asked from. */
	readonly follows: { readonly thread: string; readonly from: Cursor | undefined }[] = [];
	readonly #sockets: FakeSocket[] = [];
	readonly #threads = new Map<string, Kept>();
	readonly #operations = new Map<string, string>();
	readonly #following = new Map<FakeSocket, Set<string>>();
	readonly #watching = new Set<FakeSocket>();
	/** The sockets that watch the settings, and the settings: the environment's, and the one device's. */
	readonly #watchingSettings = new Set<FakeSocket>();
	#settings: Settings = { environment: { thread_mode: "default", favorite_models: [] }, device: {} };
	/** What streams of each request while it is answered, by its key: its thread, and its events in order. */
	readonly #streams = new Map<string, { readonly thread: string; readonly events: unknown[] }>();
	/** Where each terminal follow began: the terminal, the size of the view following it, and the offset it was asked from. */
	readonly terminalFollows: { readonly terminal: string; readonly rows: number; readonly cols: number; readonly from: number | undefined }[] = [];
	/** Where each page follow began: the page, and the size of the view following it. */
	readonly pageFollows: { readonly page: string; readonly width: number; readonly height: number; readonly scale: number }[] = [];
	/** What each terminal wrote, by its id, and the sockets that follow it. */
	readonly #terminals = new Map<string, { written: string; readonly followers: Set<FakeSocket> }>();
	#counter = 0;

	/** A socket for a client, opened a microtask later. */
	open(): WebSocketLike {
		const socket = new FakeSocket(this);
		this.#sockets.push(socket);
		queueMicrotask(() => socket.opened());
		return socket;
	}

	/** Drops every connection open now. */
	drop(): void {
		for (const socket of this.#sockets) socket.close();
		this.#following.clear();
		this.#watching.clear();
		for (const terminal of this.#terminals.values()) terminal.followers.clear();
		this.#watchingSettings.clear();
	}

	/** Sets the settings as another device would, sending them to who watches them. */
	setSettings(settings: Settings): void {
		this.#settings = settings;
		for (const socket of this.#watchingSettings) socket.deliver(JSON.stringify({ event: "settings", ...settings }));
	}

	/** Publishes `data` to the stream of the request `request` of the thread, sending it to who follows the thread. */
	publish(thread: string, request: string, data: unknown): void {
		const stream = this.#streams.get(request) ?? { thread, events: [] };
		this.#streams.set(request, stream);
		const offset = stream.events.push(data) - 1;
		for (const [socket, threads] of this.#following)
			if (threads.has(thread)) socket.deliver(JSON.stringify({ event: "stream", thread, request, offset, data }));
	}

	/** Makes a thread of `title`, as another client would: its id. */
	make(title: string): string {
		return this.#create({ title });
	}

	/** Sends every open connection `text` as it is. */
	sendRaw(text: string): void {
		for (const socket of this.#sockets) socket.deliver(text);
	}

	/** Appends an input of `text` to the thread, as another client's delivery would, feeding who follows it. */
	append(thread: string, text: string): void {
		this.#appendInput(thread, { role: "user", content: text });
	}

	/** The thread's log, as the node keeps it. */
	entriesOf(thread: string): readonly Entry[] {
		return this.#threads.get(thread)?.entries ?? [];
	}

	receive(socket: FakeSocket, data: string): void {
		const asked = JSON.parse(data) as Asked;
		this.received.push(asked);
		const answer = this.#answer(socket, asked);
		if (this.dropAfter === asked.method) {
			this.dropAfter = undefined;
			return socket.close();
		}
		socket.deliver(JSON.stringify({ id: asked.id, ...answer }));
	}

	#answer(socket: FakeSocket, asked: Asked): { result: unknown } | { error: { code: string; message: string } } {
		const params = asked.params ?? {};
		switch (asked.method) {
			case "hello":
				if (this.greeting === "refuse-protocol") return { error: { code: "protocol", message: "The node speaks the protocol's version 2." } };
				if (this.session === undefined) return { error: { code: "not-admitted", message: "This client holds no session of the host's." } };
				return { result: { protocol: 1, session: this.session, scopes: ["threads.read", "threads.operate"], environment: { name: "Test Mac" } } };
			case "threads.create":
				return { result: { thread: this.#once(String(params["operation"]), () => this.#create(params["manifest"] as { title?: string } | undefined)) } };
			case "threads.deliver": {
				const input = params["input"] as { message: unknown };
				return { result: { input: this.#once(String(params["operation"]), () => this.#appendInput(String(params["thread"]), input.message)) } };
			}
			case "threads.follow":
				this.#follow(socket, String(params["thread"]), params["from"] as Cursor | undefined);
				return { result: {} };
			case "browser.follow": {
				const page = String(params["page"]);
				this.pageFollows.push({ page, width: Number(params["width"]), height: Number(params["height"]), scale: Number(params["scale"]) });
				queueMicrotask(() =>
					socket.deliver(
						JSON.stringify({
							event: "page-frame",
							page,
							frame: this.pageFollows.length,
							width: Number(params["width"]),
							height: Number(params["height"]),
							data: "/9j/",
						}),
					),
				);
				return { result: {} };
			}
			case "terminals.follow":
				this.#followTerminal(
					socket,
					String(params["terminal"]),
					{ rows: Number(params["rows"]), cols: Number(params["cols"]) },
					params["from"] as number | undefined,
				);
				return { result: {} };
			case "terminals.write":
				return { result: {} };
			case "terminals.unfollow":
				this.#terminals.get(String(params["terminal"]))?.followers.delete(socket);
				return { result: {} };
			case "threads.read": {
				const entries = this.entriesOf(String(params["thread"]));
				const before = params["before"] === undefined ? entries.length : entries.findIndex((entry) => entry.id === params["before"]);
				if (before < 0) return { error: { code: "no-such-entry", message: "The thread's log holds no entry of that id." } };
				const start = Math.max(0, before - Number(params["limit"]));
				const end = entries.length === 0 ? {} : { end: { segment: "s", offset: entries.length } };
				return { result: { entries: entries.slice(start, before), ...end, complete: start === 0 } };
			}
			case "threads.list":
				return { result: { threads: this.#rows() } };
			case "threads.watch":
				this.#watching.add(socket);
				return { result: { threads: this.#rows() } };
			case "threads.unwatch":
				this.#watching.delete(socket);
				return { result: {} };
			case "settings.watch":
				this.#watchingSettings.add(socket);
				return { result: this.#settings };
			case "settings.unwatch":
				this.#watchingSettings.delete(socket);
				return { result: {} };
			case "settings.set": {
				const environment = { ...this.#settings.environment, ...(params["environment"] as Partial<Settings["environment"]> | undefined) };
				const device = { ...this.#settings.device, ...(params["device"] as Settings["device"] | undefined) };
				queueMicrotask(() => this.setSettings({ environment, device }));
				return { result: {} };
			}
			default:
				return { error: { code: "unknown-method", message: "No method has that name." } };
		}
	}

	/** What `make` gives, done once for the operation's id: the same each time it is asked again. */
	#once(operation: string, make: () => string): string {
		const done = this.#operations.get(operation);
		if (done !== undefined) return done;
		const made = make();
		this.#operations.set(operation, made);
		return made;
	}

	#create(manifest: { title?: string } | undefined): string {
		// Ids sort as they are made, as the node's do.
		const id = `t${String(++this.#counter).padStart(4, "0")}`;
		const kept: Kept = { title: manifest?.title, entries: [] };
		this.#threads.set(id, kept);
		for (const socket of this.#watching) socket.deliver(JSON.stringify({ event: "thread", thread: rowOf(id, kept) }));
		return id;
	}

	#rows(): Listed[] {
		return [...this.#threads].map(([id, kept]) => rowOf(id, kept));
	}

	#appendInput(thread: string, message: unknown): string {
		const kept = this.#threads.get(thread);
		if (kept === undefined) throw new Error(`no thread ${thread}`);
		const entry: Entry = { id: `e${kept.entries.length + 1}`, type: "input", delivery_id: `d${++this.#counter}`, actor: "person", message };
		kept.entries.push(entry);
		for (const [socket, threads] of this.#following) if (threads.has(thread)) this.#feed(socket, thread, kept.entries.length - 1);
		return entry.id;
	}

	/** Has the terminal `id` write `text`, sent to each socket that follows it. */
	terminalWrites(id: string, text: string): void {
		const terminal = this.#terminalOf(id);
		const offset = terminal.written.length;
		terminal.written += text;
		for (const socket of terminal.followers) socket.deliver(JSON.stringify({ event: "terminal-output", terminal: id, offset, data: btoa(text) }));
	}

	#terminalOf(id: string): { written: string; readonly followers: Set<FakeSocket> } {
		const kept = this.#terminals.get(id) ?? { written: "", followers: new Set<FakeSocket>() };
		this.#terminals.set(id, kept);
		return kept;
	}

	/**
	 * Follows a terminal for a view `size` big, a microtask later: what it wrote from `from`, or its screen — here, all it
	 * wrote, at the view's size — where none is given.
	 */
	#followTerminal(socket: FakeSocket, id: string, size: { readonly rows: number; readonly cols: number }, from: number | undefined): void {
		this.terminalFollows.push({ terminal: id, ...size, from });
		const terminal = this.#terminalOf(id);
		terminal.followers.add(socket);
		queueMicrotask(() => {
			const told =
				from === undefined
					? { event: "terminal-screen", terminal: id, offset: terminal.written.length, ...size, screen: btoa(terminal.written) }
					: { event: "terminal-output", terminal: id, offset: from, data: btoa(terminal.written.slice(from)) };
			socket.deliver(JSON.stringify(told));
		});
	}

	#follow(socket: FakeSocket, thread: string, from: Cursor | undefined): void {
		this.follows.push({ thread, from });
		const threads = this.#following.get(socket) ?? new Set();
		threads.add(thread);
		this.#following.set(socket, threads);
		this.#feed(socket, thread, from?.offset ?? 0);
		socket.deliver(JSON.stringify({ event: "state", thread, state: idle }));
		for (const [request, stream] of this.#streams) {
			if (stream.thread !== thread) continue;
			stream.events.forEach((data, offset) => socket.deliver(JSON.stringify({ event: "stream", thread, request, offset, data })));
		}
	}

	/** Sends the client the thread's entries from `offset` on, and where its reader then stands. */
	#feed(socket: FakeSocket, thread: string, offset: number): void {
		const entries = this.entriesOf(thread);
		if (offset >= entries.length) return;
		socket.deliver(JSON.stringify({ event: "entries", thread, entries: entries.slice(offset), cursor: { segment: "s", offset: entries.length } }));
	}
}

/** A thread's state at rest. */
const idle: State = { status: "created", inbox: [], processes: [] };

/** A thread as a list shows it. */
function rowOf(id: string, kept: Kept): Listed {
	return {
		id,
		manifest: { mode: "default", ...(kept.title === undefined ? {} : { title: kept.title }) },
		standing: { status: "created", inbox: [], asks: [], compacting: false },
	};
}
