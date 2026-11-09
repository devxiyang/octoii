/**
 * Octoii's protocol, as the node speaks it over a WebSocket: messages of JSON shaped as JSON-RPC's — a client's each its
 * id, its method and the method's params; each answered once by its id, with its result or the error it was refused
 * with — and the events of the threads a client follows, sent as they come: the entries appended to a thread's log,
 * each change of its state, and what streams while its model answers. What the node sends is described by schemas that
 * are its types too, so a client takes nothing it has not checked; what the log holds in `ai`'s vocabulary is kept as
 * it came, for the interface to read.
 */
import { type Static, Type } from "typebox";

/** The protocol's version, which `hello` names. */
export const PROTOCOL_VERSION = 1;

/** What a session lets its client do: each scope opens some of the protocol's methods. */
export const ScopeSchema = Type.Union([
	Type.Literal("threads.read"),
	Type.Literal("threads.operate"),
	Type.Literal("files.read"),
	Type.Literal("terminals.operate"),
	Type.Literal("browser.operate"),
	Type.Literal("providers.manage"),
	Type.Literal("access.read"),
	Type.Literal("access.write"),
]);
export type Scope = Static<typeof ScopeSchema>;

/** Where a reader stands in a thread's log: the segment, and how far into it. */
export const CursorSchema = Type.Object({ segment: Type.String(), offset: Type.Number() });
export type Cursor = Static<typeof CursorSchema>;

/**
 * How a thread's calls go ahead: in `default`, edits within the workspace and commands within a sandbox that writes the
 * workspace and the temporary folders alone, what goes beyond asking the person; in `auto`, what would ask judged by a
 * second model, the person asked where it doubts; in `full-access`, everything. In each, nothing reaches what the node
 * keeps for itself.
 */
export const ModeSchema = Type.Union([Type.Literal("default"), Type.Literal("auto"), Type.Literal("full-access")]);
export type Mode = Static<typeof ModeSchema>;

/** What a thread runs with and how it is shown: its project, the model its turns ask, its folder, its title, its mode. */
/** How hard a model reasons, from `none` to `max`. */
export const EffortSchema = Type.Union([
	Type.Literal("max"),
	Type.Literal("xhigh"),
	Type.Literal("high"),
	Type.Literal("medium"),
	Type.Literal("low"),
	Type.Literal("minimal"),
	Type.Literal("none"),
]);
export type Effort = Static<typeof EffortSchema>;

export const ManifestSchema = Type.Object({
	/** Its project's folder: the repository its workspace is in, by its root, else the workspace; none for a thread of no folder. */
	project: Type.Optional(Type.String()),
	model: Type.Optional(Type.String()),
	workspace: Type.Optional(Type.String()),
	title: Type.Optional(Type.String()),
	mode: ModeSchema,
	/** How hard its model reasons; none, as the model does where it is not told. */
	effort: Type.Optional(EffortSchema),
	/** Whether the person pinned it, which keeps it atop their threads. */
	pinned: Type.Optional(Type.Boolean()),
	/** Whether the person archived it, which keeps it out of their threads. */
	archived: Type.Optional(Type.Boolean()),
	/** Till when the person snoozed it, in ms since the epoch; a time past, or none, not snoozed. */
	snoozed_until: Type.Optional(Type.Number()),
	/** Till when the person has seen what it brought them, in ms since the epoch by its own times; what came after is new. */
	seen_until: Type.Optional(Type.Number()),
	/** The thread that delegated it, and Siphon's id of the call that did, where it is a sub-thread. */
	parent: Type.Optional(Type.Object({ thread: Type.String(), call: Type.String() })),
	/** The version of `ai`'s vocabulary its log is kept in. */
	vocabulary: Type.Number(),
});
export type Manifest = Static<typeof ManifestSchema>;

/** What of a thread's manifest the person changes as it goes, each left out kept. */
export const ConfiguredSchema = Type.Object({
	model: Type.Optional(Type.String()),
	title: Type.Optional(Type.String()),
	mode: Type.Optional(ModeSchema),
	effort: Type.Optional(EffortSchema),
	pinned: Type.Optional(Type.Boolean()),
	archived: Type.Optional(Type.Boolean()),
	snoozed_until: Type.Optional(Type.Number()),
	seen_until: Type.Optional(Type.Number()),
});
export type Configured = Static<typeof ConfiguredSchema>;

/**
 * The environment's settings, which every client of the node shares: the mode a thread starts in where it is made with
 * none, the models the person starred, and the model that judges calls in auto — none where none is named, and with
 * none every call auto would judge asks the person; a change gives it empty to name none.
 */
export const EnvironmentSettingsSchema = Type.Object({
	thread_mode: ModeSchema,
	favorite_models: Type.Array(Type.String()),
	review_model: Type.Optional(Type.String()),
});
export type EnvironmentSettings = Static<typeof EnvironmentSettingsSchema>;

/** A device's settings: its client's own names and values, which the node keeps for the device's session and reads none of. */
export const DeviceSettingsSchema = Type.Record(Type.String(), Type.Unknown());
export type DeviceSettings = Static<typeof DeviceSettingsSchema>;

/** The settings as a client is told of them: the environment's, and its device's. */
export const SettingsSchema = Type.Object({ environment: EnvironmentSettingsSchema, device: DeviceSettingsSchema });
export type Settings = Static<typeof SettingsSchema>;

/**
 * A change of the settings: each of the environment's given in place of the one it had; each of the device's names
 * given its value, or let go where it is given null.
 */
export const SettingsChangeSchema = Type.Object({
	environment: Type.Optional(Type.Partial(EnvironmentSettingsSchema)),
	device: Type.Optional(DeviceSettingsSchema),
});
export type SettingsChange = Static<typeof SettingsChangeSchema>;

/**
 * A manifest as a thread is made with: the vocabulary is the node's to name, its project the one its workspace is in,
 * and the mode the environment's settings name where none is given.
 */
export const ManifestGivenSchema = Type.Object({
	model: Type.Optional(Type.String()),
	workspace: Type.Optional(Type.String()),
	title: Type.Optional(Type.String()),
	mode: Type.Optional(ModeSchema),
	effort: Type.Optional(EffortSchema),
});
export type ManifestGiven = Static<typeof ManifestGivenSchema>;

/** What a call does, as its permission weighs it: edits files, runs commands, or acts through a server's tool. */
export const ActionSchema = Type.Union([Type.Literal("edit"), Type.Literal("command"), Type.Literal("tool")]);
export type Action = Static<typeof ActionSchema>;

/** What the person granted a project, by its folder: the patterns of each action its threads' later calls go ahead by. */
export const GrantsSchema = Type.Object({
	folder: Type.String(),
	allow: Type.Array(Type.Object({ action: ActionSchema, pattern: Type.String() })),
});
export type Grants = Static<typeof GrantsSchema>;

/**
 * An MCP server as a client is shown it: its name, the configuration it comes from, by its path — the person's own
 * `mcp.json`, or a project's `.mcp.json` — the command it is run as, whether it is connected now, and its tools' names
 * where it is; one not connected is started as a thread first needs it.
 */
export const ServerShownSchema = Type.Object({
	name: Type.String(),
	source: Type.String(),
	command: Type.String(),
	args: Type.Array(Type.String()),
	connected: Type.Boolean(),
	tools: Type.Array(Type.String()),
});
export type ServerShown = Static<typeof ServerShownSchema>;

/**
 * A project's configuration of servers, as the person decides on it: its folder, its file and the digest of its bytes,
 * the servers it names as they would be run, and whether the person trusts it — none where they decided nothing on it
 * as it is.
 */
export const ProjectServersSchema = Type.Object({
	named: Type.Object({
		folder: Type.String(),
		path: Type.String(),
		digest: Type.String(),
		servers: Type.Array(Type.Object({ name: Type.String(), command: Type.String(), args: Type.Array(Type.String()) })),
	}),
	trusted: Type.Optional(Type.Boolean()),
});
export type ProjectServers = Static<typeof ProjectServersSchema>;

/**
 * The MCP servers a thread working in a folder would use: those that run, each as it stands; what of their
 * configurations could not be taken; the person's own configuration, by its path, where the node names one; and the
 * project's configuration, with what the person decided on it.
 */
export const ServersListedSchema = Type.Object({
	servers: Type.Array(ServerShownSchema),
	problems: Type.Array(Type.String()),
	person: Type.Optional(Type.String()),
	project: Type.Optional(ProjectServersSchema),
});
export type ServersListed = Static<typeof ServersListedSchema>;

/** An input as it is delivered: a message of `ai`'s vocabulary, and whose it is — the person's where none is named. */
export const InputGivenSchema = Type.Object({
	message: Type.Object({ role: Type.String(), content: Type.Union([Type.String(), Type.Array(Type.Unknown())]) }),
	actor: Type.Optional(Type.String()),
});
export type InputGiven = Static<typeof InputGivenSchema>;

/** How a thread's turns stand: none run yet, one running, or how the last ended. */
export const StatusSchema = Type.Union([
	Type.Literal("created"),
	Type.Literal("running"),
	Type.Literal("replied"),
	Type.Literal("failed"),
	Type.Literal("stopped"),
]);
export type Status = Static<typeof StatusSchema>;

/**
 * A request a fiber made that waits for its answer: its key, its name, what it was made with, and — for one a person
 * answers — the JSON Schema their answer fits.
 */
export const OpenRequestSchema = Type.Object({
	key: Type.String(),
	name: Type.String(),
	payload: Type.Optional(Type.Unknown()),
	answer: Type.Optional(Type.Unknown()),
});
export type OpenRequest = Static<typeof OpenRequestSchema>;

/**
 * A fiber of a thread, as `ps` shows a process: its key and its parent's, its program, how it stands, what it was
 * started with, the requests it waits on, the time it sleeps until, and why it is asked to stop.
 */
export const ProcessSchema = Type.Object({
	key: Type.String(),
	parent: Type.Optional(Type.String()),
	program: Type.String(),
	state: Type.Union([Type.Literal("runnable"), Type.Literal("running"), Type.Literal("sleeping"), Type.Literal("exiting"), Type.Literal("zombie")]),
	input: Type.Optional(Type.Unknown()),
	requests: Type.Array(OpenRequestSchema),
	until: Type.Optional(Type.Number()),
	stopping: Type.Optional(Type.String()),
});
export type Process = Static<typeof ProcessSchema>;

/** An input waiting in a thread's inbox for its next turn: its id, by which it is withdrawn, whose it is, its message. */
export const InboundSchema = Type.Object({ id: Type.String(), actor: Type.String(), message: InputGivenSchema.properties.message });
export type Inbound = Static<typeof InboundSchema>;

/**
 * What a thread's model requests used: tokens read — of them those read from the prompt cache — tokens written — of
 * them those spent reasoning — and what they cost, in billionths of a US dollar, where the providers said.
 */
export const UsageSchema = Type.Object({
	input_tokens: Type.Number(),
	cached_tokens: Type.Number(),
	output_tokens: Type.Number(),
	reasoning_tokens: Type.Number(),
	cost_nanodollars: Type.Number(),
});
export type Usage = Static<typeof UsageSchema>;

/**
 * What a thread is doing: its status; when its latest turn began and ended, in ms since the epoch — none before its
 * first, no end while it runs; what its model requests used, none before its first; the inputs that wait in its inbox,
 * in the order they came; and its fibers.
 */
export const StateSchema = Type.Object({
	status: StatusSchema,
	began_at: Type.Optional(Type.Number()),
	ended_at: Type.Optional(Type.Number()),
	usage: Type.Optional(UsageSchema),
	inbox: Type.Array(InboundSchema),
	processes: Type.Array(ProcessSchema),
});
export type State = Static<typeof StateSchema>;

/** The programs of a thread's fibers, as its process table names them: its main fiber, a turn, a call, a script. */
export const PROGRAMS = { thread: "siphon.thread", turn: "siphon.turn", call: "siphon.call", script: "siphon.script" } as const;

/** The name of a model's request, as a turn's fiber waits on it. */
export const MODEL_REQUEST = "model";

/** The name of a tool's request, as a call's fiber waits on it: what it tells as it runs streams on it. */
export const TOOL_REQUEST = "tool";

/**
 * What holds a share of a thread's window: what Octoii tells the model of itself, the machine and the thread; the
 * instructions; the skills; the MCP servers' catalog; the tools' declarations; the recap of what came before; the
 * person's messages; the model's replies; and what its calls gave.
 */
export const ContextPartSchema = Type.Union([
	Type.Literal("system"),
	Type.Literal("instructions"),
	Type.Literal("skills"),
	Type.Literal("catalog"),
	Type.Literal("tools"),
	Type.Literal("recap"),
	Type.Literal("messages"),
	Type.Literal("replies"),
	Type.Literal("results"),
]);
export type ContextPart = Static<typeof ContextPartSchema>;

/** What fills a thread's window: the tokens its next request takes, near, and each part's share of them, estimated. */
export const CompositionSchema = Type.Object({
	tokens: Type.Number(),
	parts: Type.Array(Type.Object({ part: ContextPartSchema, tokens: Type.Number() })),
});
export type Composition = Static<typeof CompositionSchema>;

/** The program of a thread's compaction, as its process table names it: one at a time, beside its main fiber. */
export const COMPACT_PROGRAM = "siphon.compact";

/** A thread as a list of them shows it. */
export const ListedSchema = Type.Object({ id: Type.String(), manifest: ManifestSchema, state: StateSchema });
export type Listed = Static<typeof ListedSchema>;

/** How a call of a tool came out. */
export const CallStatusSchema = Type.Union([
	Type.Literal("ok"),
	Type.Literal("unavailable"),
	Type.Literal("invalid-arguments"),
	Type.Literal("tool-error"),
	Type.Literal("interrupted"),
	Type.Literal("stopped"),
	Type.Literal("rejected"),
]);

/** A call as the vocabulary has it: the id its result settles it by, its tool, and its arguments as JSON text. */
export const FunctionCallSchema = Type.Object({ type: Type.Literal("function_call"), call_id: Type.String(), name: Type.String(), arguments: Type.String() });

/**
 * An entry of a thread's log, by its type: what the model is told of itself, how hard it reasons from there on, an
 * input, a reply, calls made under a call — as a script makes them — a call's result, an answer that came to nothing,
 * a compaction, and the end of a turn. Each names what it is of: the request it answers, the call it is made under or
 * settles, the turn it ends.
 */
export const EntrySchema = Type.Union([
	Type.Object({
		id: Type.String(),
		type: Type.Literal("system"),
		request: Type.String(),
		sections: Type.Array(Type.Object({ name: Type.String(), text: Type.Optional(Type.String()) })),
		tools: Type.Array(Type.Unknown()),
	}),
	Type.Object({ id: Type.String(), type: Type.Literal("configuration"), effort: EffortSchema }),
	Type.Object({ id: Type.String(), type: Type.Literal("input"), delivery_id: Type.String(), actor: Type.String(), message: Type.Unknown() }),
	Type.Object({ id: Type.String(), type: Type.Literal("reply"), request: Type.String(), response: Type.Unknown(), cancelled: Type.Optional(Type.Boolean()) }),
	Type.Object({ id: Type.String(), type: Type.Literal("calls"), under: Type.String(), calls: Type.Array(FunctionCallSchema) }),
	Type.Object({
		id: Type.String(),
		type: Type.Literal("result"),
		call: Type.Optional(Type.String()),
		under: Type.Optional(Type.String()),
		status: CallStatusSchema,
		call_output: Type.Unknown(),
	}),
	Type.Object({ id: Type.String(), type: Type.Literal("failure"), request: Type.String(), response: Type.Unknown() }),
	Type.Object({
		id: Type.String(),
		type: Type.Literal("compaction"),
		request: Type.String(),
		response: Type.Unknown(),
		kept: Type.String(),
		from: Type.String(),
	}),
	Type.Object({
		id: Type.String(),
		type: Type.Literal("turn-end"),
		turn: Type.Optional(Type.String()),
		outcome: Type.Union([Type.Literal("replied"), Type.Literal("failed"), Type.Literal("stopped")]),
		reason: Type.Optional(Type.String()),
	}),
]);
export type Entry = Static<typeof EntrySchema>;

/**
 * How a provider is connected: by an API key the person gives; by a sign-in in a browser; or as a server of the
 * person's, which takes a key or none and says itself how it stands.
 */
export const ConnectsSchema = Type.Union([Type.Literal("api_key"), Type.Literal("sign_in"), Type.Literal("server")]);
export type Connects = Static<typeof ConnectsSchema>;

/** A provider: its id and its name, how it is connected, and the kind of credential the node keeps for it — `api_key`, `oauth` or `none` — none where it keeps none, never the credential. */
export const ProviderSchema = Type.Object({ id: Type.String(), name: Type.String(), connects: ConnectsSchema, credential: Type.Optional(Type.String()) });
export type Provider = Static<typeof ProviderSchema>;

/** How a provider stands, as it was asked: whether a request may reach it, who it is connected as, and what is wrong. */
export const ProviderStatusSchema = Type.Object({ connected: Type.Boolean(), account: Type.Optional(Type.String()), problem: Type.Optional(Type.String()) });
export type ProviderStatus = Static<typeof ProviderStatusSchema>;

/**
 * A model a thread may run with, as `ai`'s catalogue describes it: its id at its provider, its name, its window in
 * tokens, what it takes in, the parameters it takes, how it reasons — the efforts it takes, highest first — its provider
 * and when it came out — what the node sends beside these is kept as it came.
 */
export const ModelSchema = Type.Object({
	id: Type.String(),
	name: Type.String(),
	context_length: Type.Optional(Type.Number()),
	architecture: Type.Optional(Type.Object({ input_modalities: Type.Optional(Type.Array(Type.String())) })),
	supported_parameters: Type.Optional(Type.Array(Type.String())),
	reasoning: Type.Optional(
		Type.Object({
			supported_efforts: Type.Optional(Type.Array(EffortSchema)),
			default_effort: Type.Optional(EffortSchema),
			mandatory: Type.Optional(Type.Boolean()),
		}),
	),
	octoii: Type.Object({ provider: Type.String(), release_date: Type.Optional(Type.String()) }),
});
export type Model = Static<typeof ModelSchema>;

/**
 * A session of the node's, as its access shows it: its id, how its client holds it — a browser's cookie, a program's
 * bearer token, or the key a device's tunnel session shows — its scopes, its client's label, when it was issued and expires, in ms since the epoch, and whether a
 * client connected now holds it, and whether it is this client's.
 */
export const AccessSessionSchema = Type.Object({
	id: Type.String(),
	method: Type.Union([Type.Literal("cookie"), Type.Literal("bearer"), Type.Literal("key")]),
	scopes: Type.Array(ScopeSchema),
	label: Type.Optional(Type.String()),
	issued_at: Type.Number(),
	expires_at: Type.Number(),
	connected: Type.Boolean(),
	current: Type.Boolean(),
});
export type AccessSession = Static<typeof AccessSessionSchema>;

/** A link that pairs one client while it lasts, shown without its secret. */
export const AccessLinkSchema = Type.Object({
	id: Type.String(),
	scopes: Type.Array(ScopeSchema),
	label: Type.Optional(Type.String()),
	created_at: Type.Number(),
	expires_at: Type.Number(),
});
export type AccessLink = Static<typeof AccessLinkSchema>;

/** What a name in a folder of the machine's names. */
export const FileKindSchema = Type.Union([Type.Literal("directory"), Type.Literal("file"), Type.Literal("link")]);
export type FileKind = Static<typeof FileKindSchema>;

/** A name in a folder of the machine's: what it names, and whether its repository's ignore files leave it out. */
export const FolderEntrySchema = Type.Object({ name: Type.String(), kind: FileKindSchema, ignored: Type.Boolean() });
export type FolderEntry = Static<typeof FolderEntrySchema>;

/** A page of a folder's names: the folder, whole and clean; its names in the order of their bytes; whether more follow the last. */
export const FolderPageSchema = Type.Object({ path: Type.String(), entries: Type.Array(FolderEntrySchema), more: Type.Boolean() });
export type FolderPage = Static<typeof FolderPageSchema>;

/**
 * A page of what a file holds, with the file, whole and clean, and its length in bytes: lines of text, from the first
 * given, and whether more follow — with how many lines it has where the page reached its end; an image, its size in
 * pixels, or a PDF, each its bytes in base64; or that it is binary.
 */
export const FilePageSchema = Type.Union([
	Type.Object({
		type: Type.Literal("text"),
		path: Type.String(),
		size: Type.Number(),
		from: Type.Number(),
		lines: Type.Array(Type.String()),
		more: Type.Boolean(),
		line_count: Type.Optional(Type.Number()),
	}),
	Type.Object({
		type: Type.Literal("image"),
		path: Type.String(),
		size: Type.Number(),
		media_type: Type.String(),
		data: Type.String(),
	}),
	Type.Object({ type: Type.Literal("pdf"), path: Type.String(), size: Type.Number(), data: Type.String() }),
	Type.Object({ type: Type.Literal("binary"), path: Type.String(), size: Type.Number() }),
]);
export type FilePage = Static<typeof FilePageSchema>;

/** A file or a folder found under a folder, by its path from it. */
export const FoundPathSchema = Type.Object({ path: Type.String(), kind: Type.Union([Type.Literal("file"), Type.Literal("directory")]) });
export type FoundPath = Static<typeof FoundPathSchema>;

/** A dialog that holds a page till it is answered: its kind — alert, confirm, prompt, beforeunload — its message, and the text a prompt offers. */
export const PageDialogSchema = Type.Object({ kind: Type.String(), message: Type.String(), offered: Type.String() });
export type PageDialog = Static<typeof PageDialogSchema>;

/** A page of a thread's in the browser: its id, where it is and what it is called, whether it loads, whether it can go back and forward, and the dialog that holds it. */
export const PageListedSchema = Type.Object({
	id: Type.String(),
	url: Type.String(),
	title: Type.String(),
	loading: Type.Boolean(),
	back: Type.Boolean(),
	forward: Type.Boolean(),
	dialog: Type.Optional(PageDialogSchema),
});
export type PageListed = Static<typeof PageListedSchema>;

/** The mouse pressed, let go, moved or its wheel turned over a page, at a point of its CSS pixels: the button pressed or let go, and the buttons held, as the DOM counts them. */
export const PageMouseSchema = Type.Object({
	type: Type.Union([Type.Literal("down"), Type.Literal("up"), Type.Literal("move"), Type.Literal("wheel")]),
	x: Type.Number(),
	y: Type.Number(),
	button: Type.Optional(Type.Union([Type.Literal("none"), Type.Literal("left"), Type.Literal("middle"), Type.Literal("right")])),
	buttons: Type.Optional(Type.Number()),
	clicks: Type.Optional(Type.Number()),
	modifiers: Type.Optional(Type.Number()),
	delta_x: Type.Optional(Type.Number()),
	delta_y: Type.Optional(Type.Number()),
});
export type PageMouse = Static<typeof PageMouseSchema>;

/** A key pressed or let go on a page: its name and the key it is on, as the DOM names them, the text it types, the modifiers held, its key code, and the editing commands it stands for as the person's platform binds its shortcuts. */
export const PageKeySchema = Type.Object({
	type: Type.Union([Type.Literal("down"), Type.Literal("up")]),
	key: Type.String(),
	code: Type.String(),
	text: Type.Optional(Type.String()),
	modifiers: Type.Optional(Type.Number()),
	key_code: Type.Optional(Type.Number()),
	commands: Type.Optional(Type.Array(Type.String())),
});
export type PageKey = Static<typeof PageKeySchema>;

/** A terminal of a thread's: its id, its number in the thread, and the title its program set, where it set one. */
export const TerminalListedSchema = Type.Object({ id: Type.String(), number: Type.Number(), title: Type.Optional(Type.String()) });
export type TerminalListed = Static<typeof TerminalListedSchema>;

/**
 * A repository, as a folder in it is: where its work tree begins, its branch — none where its head is detached — its
 * head's commit — none before the first — its upstream, how far ahead of it and behind, and the branch its work was
 * taken from, as its changes are told against unless one is asked for.
 */
export const RepositorySchema = Type.Object({
	root: Type.String(),
	branch: Type.Optional(Type.String()),
	head: Type.Optional(Type.String()),
	upstream: Type.Optional(Type.String()),
	ahead: Type.Number(),
	behind: Type.Number(),
	base: Type.Optional(Type.String()),
});
export type Repository = Static<typeof RepositorySchema>;

/**
 * Which changes are asked for: those not yet committed; a branch's against where it parted from its base, the working
 * tree's own included; or one commit's.
 */
export const ChangesScopeSchema = Type.Union([
	Type.Object({ type: Type.Literal("uncommitted") }),
	Type.Object({ type: Type.Literal("branch"), base: Type.Optional(Type.String()) }),
	Type.Object({ type: Type.Literal("commit"), commit: Type.String() }),
]);
export type ChangesScope = Static<typeof ChangesScopeSchema>;

/**
 * The two trees changes are told between: the older, by its object's id; the newer, a commit's, or the working tree's
 * where none.
 */
export const ComparisonSchema = Type.Object({ old: Type.String(), new: Type.Optional(Type.String()) });
export type Comparison = Static<typeof ComparisonSchema>;

/** What became of a file between two trees; untracked, one in the working tree git does not keep. */
export const ChangeStatusSchema = Type.Union([
	Type.Literal("added"),
	Type.Literal("deleted"),
	Type.Literal("modified"),
	Type.Literal("renamed"),
	Type.Literal("copied"),
	Type.Literal("type-changed"),
	Type.Literal("untracked"),
]);
export type ChangeStatus = Static<typeof ChangeStatusSchema>;

/** A file as changes name it: its path from the repository's root, the one it had, and what became of it. */
export const ChangedFileSchema = Type.Object({ path: Type.String(), old_path: Type.Optional(Type.String()), status: ChangeStatusSchema });
export type ChangedFile = Static<typeof ChangedFileSchema>;

/** A file changed, with the lines it gained and lost — none where they were not counted — and whether it is binary. */
export const ChangedSchema = Type.Object({
	path: Type.String(),
	old_path: Type.Optional(Type.String()),
	status: ChangeStatusSchema,
	additions: Type.Optional(Type.Number()),
	deletions: Type.Optional(Type.Number()),
	binary: Type.Boolean(),
});
export type Changed = Static<typeof ChangedSchema>;

/**
 * The changes asked for: the repository's root, the trees they are between, the branch they are told against, and the
 * files changed.
 */
export const ChangesSchema = Type.Object({
	root: Type.String(),
	comparison: ComparisonSchema,
	base: Type.Optional(Type.String()),
	files: Type.Array(ChangedSchema),
});
export type Changes = Static<typeof ChangesSchema>;

/** A commit of a branch: its id, when it was committed, in seconds since the epoch, and its subject. */
export const CommitSchema = Type.Object({ commit: Type.String(), time: Type.Number(), subject: Type.String() });
export type Commit = Static<typeof CommitSchema>;

/** Why the node refused a message, or could not do what it asked. */
export const ErrorSchema = Type.Object({ code: Type.String(), message: Type.String() });

/** An answer: its message's id and the method's result, or the error it was refused with — by a null id where the id did not read. */
export const AnswerSchema = Type.Union([
	Type.Object({ id: Type.String(), result: Type.Unknown() }),
	Type.Object({ id: Type.Union([Type.String(), Type.Null()]), error: ErrorSchema }),
]);

/**
 * An event of what a client follows: of a thread followed, entries appended with where the reader then stands, its
 * state, what streams of a request by its offset in the request's stream — from the stream's start on following — that
 * it could not be fed, or its terminals and its pages in the browser as they came, changed and went; of the list of
 * threads watched, a thread's row as it changed; of a terminal followed, its screen drawn anew at its size, or the bytes
 * it wrote from an offset, both in base64; of a page followed, the newest frame the browser painted of it.
 */
export const EventSchema = Type.Union([
	Type.Object({ event: Type.Literal("entries"), thread: Type.String(), entries: Type.Array(EntrySchema), cursor: Type.Optional(CursorSchema) }),
	Type.Object({ event: Type.Literal("state"), thread: Type.String(), state: StateSchema }),
	Type.Object({ event: Type.Literal("stream"), thread: Type.String(), request: Type.String(), offset: Type.Number(), data: Type.Unknown() }),
	Type.Object({ event: Type.Literal("failed"), thread: Type.String(), error: ErrorSchema }),
	Type.Object({ event: Type.Literal("thread"), thread: ListedSchema }),
	Type.Object({ event: Type.Literal("thread-gone"), thread: Type.String() }),
	Type.Object({ event: Type.Literal("settings"), environment: EnvironmentSettingsSchema, device: DeviceSettingsSchema }),
	Type.Object({ event: Type.Literal("terminals"), thread: Type.String(), terminals: Type.Array(TerminalListedSchema) }),
	Type.Object({ event: Type.Literal("pages"), thread: Type.String(), pages: Type.Array(PageListedSchema) }),
	Type.Object({
		event: Type.Literal("page-frame"),
		page: Type.String(),
		frame: Type.Number(),
		width: Type.Number(),
		height: Type.Number(),
		data: Type.String(),
	}),
	Type.Object({
		event: Type.Literal("terminal-screen"),
		terminal: Type.String(),
		offset: Type.Number(),
		rows: Type.Number(),
		cols: Type.Number(),
		screen: Type.String(),
	}),
	Type.Object({ event: Type.Literal("terminal-output"), terminal: Type.String(), offset: Type.Number(), data: Type.String() }),
]);
export type Event = Static<typeof EventSchema>;

/** A message the node sends: an answer, or an event. */
export const ReceivedSchema = Type.Union([AnswerSchema, EventSchema]);

const Nothing = Type.Object({});
const OfThread = Type.Object({ thread: Type.String() });

/** The protocol's methods, each by its name: the params it takes, and the result it answers with. */
export const METHODS = {
	hello: {
		params: Type.Object({ protocol: Type.Number() }),
		result: Type.Object({
			protocol: Type.Number(),
			session: Type.String(),
			scopes: Type.Array(ScopeSchema),
			/** The environment the client reached: the machine the node runs on, by its name. */
			environment: Type.Optional(Type.Object({ name: Type.String() })),
		}),
	},
	"threads.list": { params: Nothing, result: Type.Object({ threads: Type.Array(ListedSchema) }) },
	"threads.create": {
		params: Type.Object({ manifest: Type.Optional(ManifestGivenSchema), operation: Type.String() }),
		result: Type.Object({ thread: Type.String() }),
	},
	"threads.configure": { params: Type.Object({ thread: Type.String(), changes: ConfiguredSchema }), result: Nothing },
	"threads.delete": { params: Type.Object({ thread: Type.String() }), result: Nothing },
	"threads.deliver": {
		params: Type.Object({ thread: Type.String(), input: InputGivenSchema, operation: Type.String() }),
		result: Type.Object({ input: Type.String() }),
	},
	"threads.withdraw": { params: Type.Object({ thread: Type.String(), input_id: Type.String() }), result: Type.Object({ withdrawn: Type.Boolean() }) },
	"threads.stop": { params: OfThread, result: Nothing },
	"threads.state": { params: OfThread, result: StateSchema },
	"threads.context": { params: Type.Object({ thread: Type.String() }), result: CompositionSchema },
	"threads.compact": { params: Type.Object({ thread: Type.String() }), result: Type.Object({ started: Type.Boolean() }) },
	"threads.answer": { params: Type.Object({ thread: Type.String(), request: Type.String(), answer: Type.Unknown() }), result: Nothing },
	"threads.read": {
		params: Type.Object({ thread: Type.String(), before: Type.Optional(Type.String()), limit: Type.Number() }),
		result: Type.Object({ entries: Type.Array(EntrySchema), end: Type.Optional(CursorSchema), complete: Type.Boolean() }),
	},
	"threads.follow": { params: Type.Object({ thread: Type.String(), from: Type.Optional(CursorSchema) }), result: Nothing },
	"threads.unfollow": { params: OfThread, result: Nothing },
	"threads.watch": { params: Nothing, result: Type.Object({ threads: Type.Array(ListedSchema) }) },
	"threads.unwatch": { params: Nothing, result: Nothing },
	"settings.watch": { params: Nothing, result: SettingsSchema },
	"settings.unwatch": { params: Nothing, result: Nothing },
	"settings.set": { params: SettingsChangeSchema, result: Nothing },
	"grants.list": { params: Nothing, result: Type.Object({ grants: Type.Array(GrantsSchema) }) },
	"grants.revoke": { params: Type.Object({ folder: Type.String(), action: ActionSchema, pattern: Type.String() }), result: Nothing },
	"servers.list": { params: Type.Object({ workspace: Type.Optional(Type.String()) }), result: ServersListedSchema },
	"trust.decide": { params: Type.Object({ folder: Type.String(), digest: Type.String(), trusted: Type.Boolean() }), result: Nothing },
	"providers.list": { params: Nothing, result: Type.Object({ providers: Type.Array(ProviderSchema) }) },
	"providers.status": { params: Type.Object({ provider: Type.String() }), result: ProviderStatusSchema },
	"providers.sign-in": { params: Type.Object({ provider: Type.String() }), result: Type.Object({ url: Type.String() }) },
	"providers.finish-sign-in": { params: Type.Object({ redirect: Type.String() }), result: Type.Object({ provider: Type.String() }) },
	"credentials.set": { params: Type.Object({ provider: Type.String(), api_key: Type.String() }), result: Nothing },
	"credentials.remove": { params: Type.Object({ provider: Type.String() }), result: Nothing },
	"models.list": { params: Nothing, result: Type.Object({ models: Type.Array(ModelSchema) }) },
	"models.refresh": { params: Nothing, result: Nothing },
	"files.list": {
		params: Type.Object({
			path: Type.String(),
			prefix: Type.Optional(Type.String()),
			after: Type.Optional(Type.String()),
			hidden: Type.Optional(Type.Boolean()),
		}),
		result: FolderPageSchema,
	},
	"files.read": {
		/** The file; where a page of its lines begins and how many it holds; and the box an image is fitted to, its shape kept, as a picture of it is drawn small — whole where none is given. */
		params: Type.Object({
			path: Type.String(),
			offset: Type.Optional(Type.Number()),
			limit: Type.Optional(Type.Number()),
			box: Type.Optional(Type.Object({ width_max: Type.Number(), height_max: Type.Number() })),
		}),
		result: FilePageSchema,
	},
	"terminals.open": {
		params: Type.Object({ thread: Type.String(), rows: Type.Number(), cols: Type.Number() }),
		result: Type.Object({ terminal: Type.String() }),
	},
	"terminals.follow": {
		params: Type.Object({ terminal: Type.String(), rows: Type.Number(), cols: Type.Number(), from: Type.Optional(Type.Number()) }),
		result: Nothing,
	},
	"terminals.unfollow": { params: Type.Object({ terminal: Type.String() }), result: Nothing },
	"terminals.write": { params: Type.Object({ terminal: Type.String(), data: Type.String() }), result: Nothing },
	"terminals.resize": { params: Type.Object({ terminal: Type.String(), rows: Type.Number(), cols: Type.Number() }), result: Nothing },
	"terminals.close": { params: Type.Object({ terminal: Type.String() }), result: Nothing },
	"browser.open": {
		params: Type.Object({
			thread: Type.String(),
			url: Type.Optional(Type.String()),
			width: Type.Number(),
			height: Type.Number(),
			scale: Type.Optional(Type.Number()),
		}),
		result: Type.Object({ page: Type.String() }),
	},
	"browser.navigate": { params: Type.Object({ page: Type.String(), url: Type.String() }), result: Nothing },
	"browser.back": { params: Type.Object({ page: Type.String() }), result: Nothing },
	"browser.forward": { params: Type.Object({ page: Type.String() }), result: Nothing },
	"browser.reload": { params: Type.Object({ page: Type.String(), bypass_cache: Type.Optional(Type.Boolean()) }), result: Nothing },
	"browser.dialog": { params: Type.Object({ page: Type.String(), accept: Type.Boolean(), text: Type.Optional(Type.String()) }), result: Nothing },
	"browser.close": { params: Type.Object({ page: Type.String() }), result: Nothing },
	"browser.follow": {
		params: Type.Object({ page: Type.String(), width: Type.Number(), height: Type.Number(), scale: Type.Optional(Type.Number()) }),
		result: Nothing,
	},
	"browser.resize": {
		params: Type.Object({ page: Type.String(), width: Type.Number(), height: Type.Number(), scale: Type.Optional(Type.Number()) }),
		result: Nothing,
	},
	"browser.unfollow": { params: Type.Object({ page: Type.String() }), result: Nothing },
	"browser.mouse": { params: Type.Object({ page: Type.String(), event: PageMouseSchema }), result: Nothing },
	"browser.key": { params: Type.Object({ page: Type.String(), event: PageKeySchema }), result: Nothing },
	"browser.text": { params: Type.Object({ page: Type.String(), text: Type.String() }), result: Nothing },
	"git.repository": { params: Type.Object({ path: Type.String() }), result: Type.Object({ repository: Type.Optional(RepositorySchema) }) },
	"git.changes": { params: Type.Object({ path: Type.String(), scope: ChangesScopeSchema }), result: ChangesSchema },
	"git.patch": {
		params: Type.Object({ path: Type.String(), comparison: ComparisonSchema, file: ChangedFileSchema, context: Type.Optional(Type.Number()) }),
		result: Type.Object({ patch: Type.String() }),
	},
	"git.versions": {
		params: Type.Object({ path: Type.String(), comparison: ComparisonSchema, file: ChangedFileSchema }),
		result: Type.Object({ old: Type.Optional(Type.String()), new: Type.Optional(Type.String()) }),
	},
	"git.commits": {
		params: Type.Object({ path: Type.String(), base: Type.Optional(Type.String()) }),
		result: Type.Object({ commits: Type.Array(CommitSchema), truncated: Type.Boolean() }),
	},
	"files.search": {
		params: Type.Object({ path: Type.String(), query: Type.String(), limit: Type.Optional(Type.Number()) }),
		result: Type.Object({ path: Type.String(), entries: Type.Array(FoundPathSchema), truncated: Type.Boolean() }),
	},
	"access.list": { params: Nothing, result: Type.Object({ sessions: Type.Array(AccessSessionSchema), links: Type.Array(AccessLinkSchema) }) },
	"access.pair": {
		params: Type.Object({ label: Type.Optional(Type.String()), scopes: Type.Optional(Type.Array(ScopeSchema)) }),
		result: Type.Object({ id: Type.String(), credential: Type.String(), expires_at: Type.Number() }),
	},
	"access.revoke": {
		params: Type.Object({ id: Type.String() }),
		result: Type.Object({ revoked: Type.Union([Type.Literal("session"), Type.Literal("link")]) }),
	},
} as const;

export type MethodName = keyof typeof METHODS;
export type ParamsOf<Name extends MethodName> = Static<(typeof METHODS)[Name]["params"]>;
export type ResultOf<Name extends MethodName> = Static<(typeof METHODS)[Name]["result"]>;
