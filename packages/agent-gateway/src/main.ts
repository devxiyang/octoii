/**
 * The gateway as a program the node runs: its channel on the descriptors 3 and 4 the node gives it — what the gateway
 * or an agent prints goes to its standard output and error, which the node keeps apart — the agents behind it, and its
 * end with the channel's. `--state <folder>` names where it keeps what lasts — each agent's positions and the folder
 * it works in — and `--claude <path>` the person's own `claude`, else the one on its path.
 *
 * Claude Code runs with the variables the gateway was given, but those that would change whose account it uses or what
 * it does on its own: a key or token for Anthropic's API, its own simple mode, effort and tool timeout; and what would
 * act beside the client — its memory, CLAUDE.md files, compaction, away summaries, tool search, the advisor, fallbacks.
 */
import { mkdir } from "node:fs/promises";
import { createReadStream, createWriteStream } from "node:fs";
import { createInterface } from "node:readline";
import { join } from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";
import { serve } from "./channel.ts";
import { Claude } from "./claude.ts";
import { handlerOf } from "./gateway.ts";
import { Positions } from "./positions.ts";

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

function environmentOf(): Record<string, string> {
	const environment: Record<string, string> = {};
	for (const [name, value] of Object.entries(process.env)) if (value !== undefined && !CLEARED.includes(name)) environment[name] = value;
	return { ...environment, ...ISOLATION };
}

async function main(): Promise<void> {
	const state = argument("state");
	const claude = claudeOf();
	if (state === undefined) throw new Error("the gateway is run with --state <folder>");
	const folder = join(state, "claude", "work");
	await mkdir(folder, { recursive: true });
	const agents = {
		claude: new Claude({
			claude: claude ?? "claude",
			folder,
			positions: await Positions.open(join(state, "claude", "positions.jsonl")),
			run: query,
			environment: environmentOf(),
			idleMs: IDLE_MS,
		}),
	};
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
