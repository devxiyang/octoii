/**
 * Octoii's client: one connection to a node, what it follows — threads, the list of them, terminals and the browser's
 * pages — and the protocol's methods. A thread followed is read first, its latest entries alone, then followed on from
 * where the log ended as it was read; older entries are read back only as a reader asks. What it follows is followed
 * again on each connection that opens: a thread from where its reader stood, the list from the list as it then stands.
 * A method that makes or adds to a thread is done once for an operation's id the client mints, and asked again on the
 * next connection where one drops before its answer, so a person's message is neither lost nor taken twice.
 */
import { Connection, type ConnectionStatus } from "./connection.ts";
import { ENTRIES_KEPT } from "./constants.ts";
import { ClientError, clientError, isConnectionError } from "./errors.ts";
import { type Followable, type Followed, Value } from "./followed.ts";
import { Follows } from "./follows.ts";
import type { Clock, ClientOptions, KeptFile } from "./options.ts";
import type {
	Action,
	Configured,
	Event,
	Grants,
	InputGiven,
	Listed,
	ManifestGiven,
	MethodName,
	Model,
	ParamsOf,
	Provider,
	ProviderStatus,
	ResultOf,
	Settings,
	SettingsChange,
	State,
} from "./protocol.ts";
import { type TerminalHandlers, TerminalFollows, type TerminalSize, type TerminalView } from "./terminals.ts";
import { type PageHandlers, PageFollows, type PageSize, type PageView } from "./pages.ts";
import type { ThreadView } from "./thread.ts";
import { type ThreadsView, WatchedThreads } from "./threads.ts";
import { Watch } from "./watch.ts";

/** What a client gives its app. */
export type Client = {
	readonly status: Followed<ConnectionStatus>;
	readonly clock: Clock;
	/** Calls a method as it is, on the open connection. */
	call<Name extends MethodName>(method: Name, params: ParamsOf<Name>): Promise<ResultOf<Name>>;
	/** The threads, each with its manifest and its state, as they stand. */
	threads(): Promise<readonly Listed[]>;
	/** Makes a thread of `manifest`, once: its id. */
	create(manifest: ManifestGiven): Promise<string>;
	/** Changes the thread's manifest: its model or how hard it reasons, from its next request on; its title or its mode; whether it is pinned or archived, and till when it is snoozed — each given in place of the one it had. */
	configure(thread: string, changes: Configured): Promise<void>;
	/** Delivers `input` to the thread, once: the input's id. */
	deliver(thread: string, input: InputGiven): Promise<string>;
	/** Takes back an input while it waits in the thread's inbox: whether it was still there. */
	withdraw(thread: string, input: string): Promise<boolean>;
	/** Deletes the thread, whatever it was doing: its log, its fibers, its terminals and its pages gone for good. */
	delete(thread: string): Promise<void>;
	/** Stops the thread for the person: their inputs that wait withdrawn, its turn asked to stop. */
	stop(thread: string): Promise<void>;
	/** What the thread is doing. */
	state(thread: string): Promise<State>;
	/** Gives the person's answer to a request a fiber of the thread waits on. */
	answer(thread: string, request: string, answer: unknown): Promise<void>;
	/** Follows the thread: one followed for all who read it, its latest entries first, let go after the last. */
	follow(thread: string): Followable<ThreadView>;
	/** Reads a page further back of a thread followed, before the entries it holds: it keeps them too. */
	readOlder(thread: string): Promise<void>;
	/** Watches the list of threads: one watch for all who read it, let go after the last. */
	watchThreads(): Followable<ThreadsView>;
	/** Watches the settings — the environment's and this device's — none until the node answered: one watch for all who read them. */
	watchSettings(): Followable<Settings | undefined>;
	/** Changes the settings as `change` says. */
	setSettings(change: SettingsChange): Promise<void>;
	/** What the person granted each project. */
	grants(): Promise<readonly Grants[]>;
	/** Takes back from the project at `folder` its grant of `pattern` to `action`. */
	revokeGrant(folder: string, action: Action, pattern: string): Promise<void>;
	/** The node's providers: how each is connected, and the kind of credential the node keeps for it. */
	providers(): Promise<readonly Provider[]>;
	/** How the provider `id` stands, as it is asked. */
	providerStatus(id: string): Promise<ProviderStatus>;
	/** Begins a sign-in to the provider `id`: where the person signs in. */
	signIn(id: string): Promise<string>;
	/** Finishes the sign-in that waits, from the address the browser was sent back to: the provider signed in to. */
	finishSignIn(redirect: string): Promise<string>;
	/** Lists the providers' models again. */
	refreshModels(): Promise<void>;
	setKey(provider: string, key: string): Promise<void>;
	removeKey(provider: string): Promise<void>;
	/** Adds an account of the node's provider `provider`, named `name`: the id it is a provider by. */
	addAccount(provider: string, name: string): Promise<string>;
	/** Gives the account `account` the name `name`. */
	renameAccount(account: string, name: string): Promise<void>;
	/** Removes the account `account`, and the credential the node kept for it. */
	removeAccount(account: string): Promise<void>;
	/** Has the thread go on at `at`, in milliseconds since the epoch, unless the person goes on first; at no time, where `at` is none. */
	resume(thread: string, at: number | undefined): Promise<void>;
	/** The models a thread may run with. */
	models(): Promise<readonly Model[]>;
	/** Opens a terminal for the thread, at the size of the view that opens it: its id, the thread's terminals told first. */
	openTerminal(thread: string, size: TerminalSize): Promise<string>;
	/** Follows the terminal `id` for a view `size` big, told through `handlers`, which types into it, resizes it and lets it go. */
	terminal(id: string, size: TerminalSize, handlers: TerminalHandlers): TerminalView;
	/** Closes the terminal `id`: its program hung up on, and the terminal gone from its thread. */
	closeTerminal(id: string): Promise<void>;
	/** Opens a page in the browser for the thread, at `url` or blank, the size of the view that opens it: its id, the thread's pages told first. */
	openPage(thread: string, url: string | undefined, size: PageSize): Promise<string>;
	/** Follows the page `id` for a view `size` big, told through `handlers`, which clicks it, types into it, resizes it and lets it go. */
	page(id: string, size: PageSize, handlers: PageHandlers): PageView;
	/** Closes the page `id`: gone from its thread. */
	closePage(id: string): Promise<void>;
	/** Has the node keep a file a message gives its model: its reference and size; rejects where the app sends no files. */
	keepFile(bytes: Blob): Promise<KeptFile>;
	close(): void;
};

/** Connects to the node, as `options` says how, and keeps on connecting until it is closed. */
export function createClient(options: ClientOptions): Client {
	// What a lost or closed connection cuts off is followed again as the next one opens: only another failure is told.
	const told = (error: unknown): void => {
		if (!isConnectionError(error) && !(error instanceof ClientError && error.code === "closed")) options.report(error);
	};
	const connection: Connection = new Connection(options, {
		opened: () => {
			follows.again();
			terminals.again();
			pages.again();
			threadsWatch.again();
			settingsWatch.again();
		},
		event: (event: Event) => {
			if (event.event === "thread") return threadsWatch.thing?.take(event.thread);
			if (event.event === "thread-gone") return threadsWatch.thing?.forget(event.thread);
			if (event.event === "settings") return settingsWatch.thing?.set({ environment: event.environment, device: event.device });
			if ("terminal" in event) return terminals.take(event);
			if (event.event === "page-frame") return pages.take(event);
			follows.take(event);
		},
	});
	const follows = new Follows(connection, options.entriesKept ?? ENTRIES_KEPT, told);
	const terminals = new TerminalFollows(connection, told);
	const pages = new PageFollows(connection, told);
	const isOpen = (): boolean => connection.status.value.status === "open";
	const threadsWatch = new Watch<WatchedThreads, ThreadsView>(
		{
			make: () => new WatchedThreads(),
			view: (list) => list.view,
			subscribe: (list, listener) => list.subscribe(listener),
			begin: (list) => void connection.call("threads.watch", {}).then((answer) => list.reset(answer.threads), told),
			end: () => void connection.call("threads.unwatch", {}).catch(told),
		},
		isOpen,
	);
	const settingsWatch = new Watch<Value<Settings | undefined>, Settings | undefined>(
		{
			make: () => new Value<Settings | undefined>(undefined),
			view: (value) => value.value,
			subscribe: (value, listener) => value.subscribe(listener),
			begin: (value) => void connection.call("settings.watch", {}).then((answer) => value.set(answer), told),
			end: () => void connection.call("settings.unwatch", {}).catch(told),
		},
		isOpen,
	);
	connection.start();
	return {
		status: connection.status,
		clock: options.clock,
		call: (method, params) => connection.call(method, params),
		threads: async () => (await connection.call("threads.list", {})).threads,
		create: async (manifest) => (await connection.callOpen("threads.create", { manifest, operation: options.randomUUID() })).thread,
		configure: async (thread, changes) => {
			await connection.call("threads.configure", { thread, changes });
		},
		deliver: async (thread, input) => (await connection.callOpen("threads.deliver", { thread, input, operation: options.randomUUID() })).input,
		withdraw: async (thread, input) => (await connection.call("threads.withdraw", { thread, input_id: input })).withdrawn,
		stop: async (thread) => {
			await connection.call("threads.stop", { thread });
		},
		state: (thread) => connection.call("threads.state", { thread }),
		answer: async (thread, request, answer) => {
			await connection.call("threads.answer", { thread, request, answer });
		},
		follow: (id) => follows.follow(id),
		readOlder: (id) => follows.readOlder(id),
		watchThreads: () => threadsWatch.hold(),
		watchSettings: () => settingsWatch.hold(),
		setSettings: async (change) => {
			await connection.call("settings.set", change);
		},
		grants: async () => (await connection.call("grants.list", {})).grants,
		revokeGrant: async (folder, action, pattern) => {
			await connection.call("grants.revoke", { folder, action, pattern });
		},
		providers: async () => (await connection.call("providers.list", {})).providers,
		providerStatus: (id) => connection.call("providers.status", { provider: id }),
		signIn: async (id) => (await connection.call("providers.sign-in", { provider: id })).url,
		finishSignIn: async (redirect) => (await connection.call("providers.finish-sign-in", { redirect })).provider,
		refreshModels: async () => {
			await connection.call("models.refresh", {});
		},
		setKey: async (provider, key) => {
			await connection.call("credentials.set", { provider, api_key: key });
		},
		removeKey: async (provider) => {
			await connection.call("credentials.remove", { provider });
		},
		addAccount: async (provider, name) => (await connection.callOpen("accounts.add", { provider, name, operation: options.randomUUID() })).account,
		renameAccount: async (account, name) => {
			await connection.call("accounts.rename", { account, name });
		},
		removeAccount: async (account) => {
			await connection.call("accounts.remove", { account });
		},
		resume: async (thread, at) => {
			await connection.call("threads.resume", { thread, ...(at === undefined ? {} : { at }) });
		},
		models: async () => (await connection.call("models.list", {})).models,
		openTerminal: async (thread, size) => (await connection.call("terminals.open", { thread, ...size })).terminal,
		terminal: (id, size, handlers) => terminals.follow(id, size, handlers),
		closeTerminal: async (id) => {
			await connection.call("terminals.close", { terminal: id });
		},
		openPage: async (thread, url, size) => (await connection.call("browser.open", { thread, ...(url === undefined ? {} : { url }), ...size })).page,
		page: (id, size, handlers) => pages.follow(id, size, handlers),
		delete: async (thread) => {
			await connection.call("threads.delete", { thread });
		},
		closePage: async (id) => {
			await connection.call("browser.close", { page: id });
		},
		keepFile: async (bytes) => {
			if (options.keepFile === undefined) throw clientError("unsupported", "This client sends the node no files.");
			return options.keepFile(bytes);
		},
		close: () => connection.close(),
	};
}
