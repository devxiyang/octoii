/** The MCP servers as the new thread's page groups them: the person's own, and the project's as the person stands on it. */
import { describe, expect, it } from "bun:test";
import type { ServerShown, ServersListed } from "@octoii-works/octoii-client";
import { countOf, groupsOf } from "../src/core/servers.ts";

const PERSON = "/home/me/.octoii/mcp.json";
const PROJECT = "/work/app/.mcp.json";

/** A server shown as running from `source`, its tools those named. */
const running = (name: string, source: string, tools: readonly string[] = []): ServerShown => ({
	name,
	source,
	command: "npx",
	args: [name],
	connected: tools.length > 0,
	tools: [...tools],
});

/** A listing of `servers`, the project naming `named` and standing as `trusted` says. */
const listing = (servers: readonly ServerShown[], named: readonly string[], trusted?: boolean): ServersListed => ({
	servers: [...servers],
	problems: [],
	project: {
		named: { folder: "/work/app", path: PROJECT, digest: "d1", servers: named.map((name) => ({ name, command: "node", args: [`${name}.js`] })) },
		...(trusted === undefined ? {} : { trusted }),
	},
});

describe("the servers", () => {
	it("are the person's alone where the folder's project names none", () => {
		const listed: ServersListed = { servers: [running("search", PERSON, ["find"])], problems: [] };
		expect(groupsOf(listed)).toEqual({ yours: listed.servers, project: undefined });
		expect(countOf(listed)).toEqual({ running: 1, awaiting: false });
	});

	it("hold a project's that run where it is trusted, standing for the person's of their name", () => {
		const groups = groupsOf(listing([running("search", PERSON), running("db", PROJECT, ["query"])], ["db"], true));
		expect(groups.yours.map((server) => server.name)).toEqual(["search"]);
		expect(groups.project).toMatchObject({ name: "app", trusted: true, servers: [{ name: "db", connected: true, tools: ["query"] }] });
	});

	it("hold a project's it names as they would be run where it is undecided or declined, the person's running in their stead", () => {
		const undecided = listing([running("db", PERSON)], ["db"]);
		const groups = groupsOf(undecided);
		expect(groups.yours.map((server) => server.source)).toEqual([PERSON]);
		expect(groups.project).toMatchObject({
			trusted: undefined,
			digest: "d1",
			servers: [{ name: "db", command: "node", source: PROJECT, connected: false, tools: [] }],
		});
		expect(countOf(undecided)).toEqual({ running: 1, awaiting: true });
		expect(countOf(listing([], ["db"], false))).toEqual({ running: 0, awaiting: false });
	});
});
