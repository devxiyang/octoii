/**
 * The MCP servers a new thread would use, on the right of the strip under the composer: a chip of how many run, marked
 * where a project's wait on the person's trust, opening a card of them — the person's own, and the project's — each by
 * its name, the program it runs and how it stands: connected with its tools, started as a thread first needs it, or not
 * run, as a project's the person does not trust.
 * The project's stand with what the person decided on them, decided there — trusted, or not — as a thread would ask
 * it; a group of none says which file names them. Nothing is started for the showing.
 */
import { type ReactNode, useState } from "react";
import type { ServerShown, ServersListed } from "@octoii-works/octoii-client";
import { useClient } from "@octoii-works/octoii-client/react";
import { ChevronDown, Plug, ShieldQuestion, TriangleAlert } from "lucide-react";
import { countOf, groupsOf, type ProjectGroup } from "../../core/servers.ts";
import { nameOf } from "../../core/files.ts";
import { useOutcome } from "../effects/read.ts";
import { failed } from "../state/notices.ts";
import { Button } from "../ui/button.tsx";
import { Monogram } from "../ui/monogram.tsx";
import { Popover, PopoverPopup, PopoverTrigger } from "../ui/popover.tsx";

/** The chip and its card, for a thread that would work in `folder`, none where it works in none. */
export function ServersMenu(props: { readonly folder: string | undefined }): ReactNode {
	const client = useClient();
	// Read again as the person decides, so the card shows what they decided.
	const [decided, setDecided] = useState(0);
	const outcome = useOutcome("servers.list", props.folder === undefined ? {} : { workspace: props.folder }, decided);
	if (outcome === undefined || "failure" in outcome) return null;
	const listed = outcome.result;
	const decide = (project: ProjectGroup, trusted: boolean): void => {
		client.call("trust.decide", { folder: project.folder, digest: project.digest, trusted }).then(
			() => setDecided(decided + 1),
			(error: unknown) => failed("What you decided could not be kept", error),
		);
	};
	return (
		<Popover>
			<PopoverTrigger className="inline-flex h-control-sm items-center gap-1.5 rounded-md px-2 text-xs text-muted-foreground outline-none hover:bg-accent hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring/70 data-popup-open:bg-accent data-popup-open:text-foreground">
				<Chip listed={listed} />
				<ChevronDown className="size-3.5 shrink-0 opacity-70" />
			</PopoverTrigger>
			<PopoverPopup side="top" align="end" sideOffset={8} className="flex w-[min(24rem,calc(100vw-2rem))] flex-col gap-3 p-3">
				<Card listed={listed} onDecide={decide} />
			</PopoverPopup>
		</Popover>
	);
}

/** What the chip says: how many servers run, and a mark where a project's wait on the person. */
function Chip(props: { readonly listed: ServersListed }): ReactNode {
	const { running, awaiting } = countOf(props.listed);
	return (
		<>
			<Plug className="size-3.5 shrink-0" />
			<span>{running === 0 ? "No MCP servers" : `${String(running)} MCP server${running === 1 ? "" : "s"}`}</span>
			{awaiting ? <ShieldQuestion aria-label="A project's servers wait on your trust" className="size-3.5 shrink-0 text-warning-foreground" /> : null}
		</>
	);
}

/** The card: the person's servers, the project's as the person stands on them, and what could not be taken. */
function Card(props: { readonly listed: ServersListed; readonly onDecide: (project: ProjectGroup, trusted: boolean) => void }): ReactNode {
	const { yours, project } = groupsOf(props.listed);
	return (
		<>
			<div className="flex flex-col gap-0.5 px-0.5">
				<p className="text-sm font-medium">MCP servers</p>
				<p className="text-xs text-muted-foreground">Their tools are what a thread here calls beyond its own.</p>
			</div>
			<Group title="Yours" file={props.listed.person} servers={yours} waiting="a thread" />
			{project === undefined ? null : <ProjectServers project={project} onDecide={props.onDecide} />}
			{props.listed.problems.map((problem) => (
				<p key={problem} className="flex gap-1.5 px-0.5 text-xs text-muted-foreground">
					<TriangleAlert className="mt-0.5 size-3.5 shrink-0 text-warning-foreground" />
					<span className="min-w-0 [overflow-wrap:anywhere]">{problem}</span>
				</p>
			))}
		</>
	);
}

/** What a server not connected waits for: a thread's first need of it, where it runs; else nothing, as it is not run. */
type Waiting = "a thread" | "nothing";

/**
 * A group: its title and the file that names its servers, what is said of them, then each server — where it has none,
 * the file to name them in — and what may be done with them.
 */
function Group(props: {
	readonly title: string;
	readonly file: string | undefined;
	readonly servers: readonly ServerShown[];
	readonly waiting: Waiting;
	readonly note?: ReactNode;
	readonly actions?: ReactNode;
}): ReactNode {
	return (
		<section className="flex flex-col gap-1 border-t border-border/60 pt-2.5">
			<h3 className="flex items-baseline justify-between gap-2 px-0.5">
				<span className="label-caps">{props.title}</span>
				{props.file === undefined ? null : (
					<span title={props.file} className="truncate font-mono text-2xs text-muted-foreground">
						{nameOf(props.file)}
					</span>
				)}
			</h3>
			{props.note}
			{props.servers.length === 0 ? (
				<p className="px-0.5 text-xs text-muted-foreground">{props.file === undefined ? "None." : `None — name them in ${props.file}.`}</p>
			) : (
				<ul className="flex flex-col">
					{props.servers.map((server) => (
						<ServerRow key={server.name} server={server} waiting={props.waiting} />
					))}
				</ul>
			)}
			{props.actions === undefined ? null : <div className="flex justify-end gap-1.5 pt-1">{props.actions}</div>}
		</section>
	);
}

/** A server: its monogram and name, the program it runs with its arguments — the whole command its tip — and how it stands. */
function ServerRow(props: { readonly server: ServerShown; readonly waiting: Waiting }): ReactNode {
	const { server } = props;
	const command = [server.command, ...server.args].join(" ");
	const program = [nameOf(server.command), ...server.args].join(" ");
	return (
		<li className="flex min-w-0 items-center gap-2.5 rounded-lg px-0.5 py-1.5">
			<Monogram name={server.name} size="md" />
			<span className="flex min-w-0 flex-1 flex-col">
				<span className="truncate text-ui font-medium">{server.name}</span>
				<span title={command} className="truncate font-mono text-2xs text-muted-foreground">
					{program}
				</span>
			</span>
			{server.connected ? (
				<span title={server.tools.join("\n")} className="flex shrink-0 items-center gap-1.5 text-xs text-muted-foreground tabular-nums">
					<span className="size-1.5 rounded-full bg-success" />
					{`${String(server.tools.length)} tool${server.tools.length === 1 ? "" : "s"}`}
				</span>
			) : (
				<span className="shrink-0 text-xs text-muted-foreground/80">{props.waiting === "a thread" ? "Starts with a thread" : "Not run"}</span>
			)}
		</li>
	);
}

/** The project's servers, with what the person decided on them and the way to decide again. */
function ProjectServers(props: { readonly project: ProjectGroup; readonly onDecide: (project: ProjectGroup, trusted: boolean) => void }): ReactNode {
	const { project, onDecide } = props;
	const decision = (trusted: boolean, words: string, variant: "default" | "outline"): ReactNode => (
		<Button size="xs" variant={variant} onClick={() => onDecide(project, trusted)}>
			{words}
		</Button>
	);
	return (
		<Group
			title={`${project.name}'s`}
			file={project.path}
			servers={project.servers}
			waiting={project.trusted === true ? "a thread" : "nothing"}
			note={
				project.trusted === true ? undefined : (
					<p className="px-0.5 text-xs text-muted-foreground">
						{project.trusted === undefined
							? "The project's own code: its servers run once you trust them. A thread here asks as it starts."
							: "You chose not to run them."}
					</p>
				)
			}
			actions={
				<>
					{project.trusted === true ? decision(false, "Stop trusting", "outline") : null}
					{project.trusted === undefined ? decision(false, "Don't trust", "outline") : null}
					{project.trusted === true ? null : decision(true, "Trust", "default")}
				</>
			}
		/>
	);
}
