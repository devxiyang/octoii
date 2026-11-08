/**
 * The MCP servers as the new thread's page shows them: the person's own that run, and the project's — those that run
 * where the person trusts it, else those it names, as they would be run — with how the person stands on it; and what
 * the menu's chip counts.
 */
import type { ServerShown, ServersListed } from "@octoii-works/octoii-client";
import { folderName } from "./threads.ts";

/** A project's servers, as the person decides on them: its folder, its name, its file and its digest, what they decided — none where nothing — and its servers. */
export type ProjectGroup = {
	readonly folder: string;
	readonly name: string;
	readonly path: string;
	readonly digest: string;
	readonly trusted: boolean | undefined;
	readonly servers: readonly ServerShown[];
};

/** The servers in their groups: the person's own that run, and the project's, where it names any. */
export type ServerGroups = { readonly yours: readonly ServerShown[]; readonly project: ProjectGroup | undefined };

/** The groups of `listed`: a project's server that runs stands among the project's, one it names that does not as it would be run, never connected. */
export function groupsOf(listed: ServersListed): ServerGroups {
	const project = listed.project;
	if (project === undefined) return { yours: listed.servers, project: undefined };
	const { named, trusted } = project;
	const ours = (server: ServerShown): boolean => server.source === named.path;
	const servers =
		trusted === true
			? listed.servers.filter(ours)
			: named.servers.map((server): ServerShown => ({ ...server, source: named.path, connected: false, tools: [] }));
	return {
		yours: listed.servers.filter((server) => !ours(server)),
		project: { folder: named.folder, name: folderName(named.folder), path: named.path, digest: named.digest, trusted, servers },
	};
}

/** How many servers a thread would run, and whether a project's wait on the person's trust. */
export function countOf(listed: ServersListed): { readonly running: number; readonly awaiting: boolean } {
	return { running: listed.servers.length, awaiting: listed.project !== undefined && listed.project.trusted === undefined };
}
