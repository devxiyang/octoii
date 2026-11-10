/**
 * The gateway as a program the node runs: its channel on the descriptors 3 and 4 the node gives it — what the gateway
 * or an agent prints goes to its standard output and error, which the node keeps apart — the agents behind it, and its
 * end with the channel's. `--state <folder>` names where it keeps what lasts — each agent's positions and the folder
 * it works in — and `--claude <path>` the person's own `claude`, else the one on its path. `--logins <folder>` names
 * where the agents keep the logins of the account the gateway answers for, one the person added: Claude Code's
 * configuration in its `claude`, which it is signed out of as the person removes the account; without it, the agents
 * are signed in as the person signed them in, and never signed out here.
 *
 * Claude Code runs with the variables the gateway was given, but those that would change whose account it uses or what
 * it does on its own: a key or token for Anthropic's API, its own simple mode, effort and tool timeout; and what would
 * act beside the client — its memory, CLAUDE.md files, compaction, away summaries, tool search, the advisor, fallbacks.
 */
import { execFile } from "node:child_process";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { createReadStream, createWriteStream } from "node:fs";
import { createInterface } from "node:readline";
import { join } from "node:path";
import { deleteSession, getSessionInfo, listSessions, query } from "@anthropic-ai/claude-agent-sdk";
import { serve } from "./channel.ts";
import { Claude, KeptWindowsSchema, type Sessions, type WindowsStore } from "./claude.ts";
import { handlerOf } from "./gateway.ts";
import { Holds } from "./holds.ts";
import { Positions } from "./positions.ts";
import { matches } from "./schema.ts";

/** The variables that would make Claude Code use another account than the person's own login, or act on its own. */
const CLEARED = [
	"ANTHROPIC_API_KEY",
	"ANTHROPIC_AUTH_TOKEN",
	"ANTHROPIC_BASE_URL",
	"CLAUDE_CODE_OAUTH_TOKEN",
	"CLAUDE_CODE_SIMPLE",
	"CLAUDE_CODE_EFFORT_LEVEL",
	"MCP_TOOL_TIMEOUT",
	"CLAUDECODE",
];

/** What Claude Code does beside the client, turned off: the client keeps its own of each. */
const ISOLATION: Readonly<Record<string, string>> = {
	CLAUDE_CODE_DISABLE_CLAUDE_MDS: "1",
	CLAUDE_CODE_DISABLE_AUTO_MEMORY: "1",
	DISABLE_AUTO_COMPACT: "1",
	CLAUDE_CODE_ENABLE_AWAY_SUMMARY: "0",
	ENABLE_TOOL_SEARCH: "false",
	CLAUDE_CODE_DISABLE_ADVISOR_TOOL: "1",
	CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK: "1",
	CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK: "1",
	// The client bounds what its tools give; Claude Code's own bound would cut it again.
	MAX_MCP_OUTPUT_TOKENS: "200000",
};

/** How long a live session of Claude Code may stand unasked before its process is closed. */
const IDLE_MS = 10 * 60 * 1000;

/** The value of the argument `--name`; none where it is not given. */
function argument(name: string): string | undefined {
	const at = process.argv.indexOf(`--${name}`);
	return at < 0 ? undefined : process.argv[at + 1];
}

/** The person's own `claude`: the one named, else the first on the path. */
function claudeOf(): string | undefined {
	return argument("claude") ?? Bun.which("claude") ?? undefined;
}

/** `path` as a person types it at a shell: under their home folder from `~`, as one word, quoted where it must be. */
function shellPath(path: string): string {
	const home = process.env["HOME"];
	const under = home !== undefined && path.startsWith(`${home}/`) ? path.slice(home.length + 1) : undefined;
	if (under !== undefined && /^[\w./-]+$/.test(under)) return `~/${under}`;
	return `'${path.replaceAll("'", "'\\''")}'`;
}

/** Claude Code's sessions in `folder`, as the SDK finds and removes them. */
function sessionsIn(folder: string): Sessions {
	return {
		has: async (id) => (await getSessionInfo(id, { dir: folder })) !== undefined,
		remove: (id) => deleteSession(id, { dir: folder }),
		list: async () => (await listSessions({ dir: folder })).map((session) => ({ id: session.sessionId, changedAt: session.lastModified })),
	};
}

function environmentOf(): Record<string, string> {
	const environment: Record<string, string> = {};
	for (const [name, value] of Object.entries(process.env)) if (value !== undefined && !CLEARED.includes(name)) environment[name] = value;
	return { ...environment, ...ISOLATION };
}

/** The windows Claude Code gave its models, kept in the file at `path`: read whole, none where it holds none; written whole, by a file of their own put in its place. */
function windowsIn(path: string): WindowsStore {
	return {
		read: async () => {
			const kept: unknown = JSON.parse(await readFile(path, "utf8").catch(() => "null"));
			return matches(KeptWindowsSchema, kept) ? kept : undefined;
		},
		write: async (kept) => {
			const fresh = `${path}.new`;
			await writeFile(fresh, JSON.stringify(kept));
			await rename(fresh, path);
		},
	};
}

/** How long signing Claude Code out may take. */
const SIGN_OUT_MS = 60_000;

/**
 * Signs `claude` out of the login its configuration in `environment` keeps — its own, an added account's, whose
 * keychain entry Claude Code names by the configuration's folder — failing as it ends otherwise.
 */
function signOut(claude: string, environment: Readonly<Record<string, string>>): Promise<void> {
	return new Promise((resolve, reject) => {
		execFile(claude, ["auth", "logout"], { env: environment, timeout: SIGN_OUT_MS }, (error) =>
			error === null ? resolve() : reject(new Error(`\`claude auth logout\` failed: ${error.message}`)),
		);
	});
}

async function main(): Promise<void> {
	const state = argument("state");
	const claude = claudeOf() ?? "claude";
	const logins = argument("logins");
	if (state === undefined) throw new Error("the gateway is run with --state <folder>");
	const folder = join(state, "claude", "work");
	await mkdir(folder, { recursive: true });
	// An added account's Claude Code keeps its configuration, and its login, apart; the SDK reads it from the gateway's.
	const configuration = logins === undefined ? undefined : join(logins, "claude");
	if (configuration !== undefined) process.env["CLAUDE_CONFIG_DIR"] = configuration;
	const environment = environmentOf();
	const agents = {
		claude: new Claude({
			claude,
			folder,
			positions: await Positions.open(join(state, "claude", "positions.jsonl")),
			run: query,
			environment,
			signIn: `${configuration === undefined ? "" : `CLAUDE_CONFIG_DIR=${shellPath(configuration)} `}${argument("claude") ?? "claude"} auth login`,
			signOut: configuration === undefined ? undefined : () => signOut(claude, environment),
			idleMs: IDLE_MS,
			holds: await Holds.open(join(state, "claude", "holds.jsonl")),
			sessions: sessionsIn(folder),
			now: Date.now,
			windows: windowsIn(join(state, "claude", "windows.json")),
		}),
	};
	void agents.claude.collect().catch((error: unknown) => console.error(error instanceof Error ? error.message : String(error)));
	const out = createWriteStream("", { fd: 4 });
	const lines = createInterface({ input: createReadStream("", { fd: 3 }), crlfDelay: Number.POSITIVE_INFINITY });
	try {
		await serve(lines, (line) => void out.write(line), handlerOf(agents));
	} finally {
		agents.claude.close();
		await new Promise<void>((resolve) => out.end(resolve));
	}
}

await main().catch((error: unknown) => {
	console.error(error instanceof Error ? error.message : String(error));
	process.exitCode = 1;
});
process.exit();
