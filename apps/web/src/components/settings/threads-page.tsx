/**
 * Threads: what every device of the node shares of them — the mode a new thread starts in where it is made with none;
 * the model that judges calls in auto, chosen from the models as the composer's chip opens them, or none; what the
 * person always allowed in each project, each taken back on its own — and the threads the person archived.
 */
import { type ReactNode, useState, useTransition } from "react";
import type { Action, Grants, Mode } from "@octoii-works/octoii-client";
import { useClient, useSettings } from "@octoii-works/octoii-client/react";
import { ChevronsUpDown, FilePen, FolderGit2, SquareTerminal, Wrench, X } from "lucide-react";
import { MODES, modeOffered, modeShown } from "../../core/modes.ts";
import { modelLabel, providerName, providerOf } from "../../core/models.ts";
import { folderName } from "../../core/threads.ts";
import { vendorOfReference } from "../../core/vendors.ts";
import { useDirectory } from "../composer/directory.ts";
import { ModelList } from "../composer/model-list.tsx";
import { useOutcome } from "../effects/read.ts";
import { failed } from "../state/notices.ts";
import { Button, IconButton } from "../ui/button.tsx";
import { cn } from "../ui/cn.ts";
import { VendorMark } from "../ui/vendor-mark.tsx";
import { Popover, PopoverPopup, PopoverTrigger } from "../ui/popover.tsx";
import { PICKER_TRIGGER, Select } from "../ui/select.tsx";
import { ArchiveSection } from "./archive-section.tsx";
import { Page, Row, Section } from "./layout.tsx";

/** The page: its permissions nothing until the node told of its settings. */
export function ThreadsPage(): ReactNode {
	const client = useClient();
	const settings = useSettings();
	const environment = settings?.environment;
	const choose = (next: Mode): void => {
		client.setSettings({ environment: { thread_mode: next } }).catch((error: unknown) => failed("The setting could not be kept", error));
	};
	return (
		<Page title="Threads" description="How a new thread's calls go ahead, what you always allowed, and the threads you put away.">
			{environment === undefined ? null : (
				<Section title="Permissions" description="A thread's own mode, chosen in its composer, is kept for it." anchor="setting-mode">
					<Row title="New threads start in" description={modeShown(environment.thread_mode).description}>
						<Select
							label="Mode"
							value={environment.thread_mode}
							onValueChange={choose}
							items={MODES.filter((each) => modeOffered(each, environment.review_model) || each === environment.thread_mode).map((each) => ({
								value: each,
								label: modeShown(each).label,
							}))}
						/>
					</Row>
					<Row
						title="Review model"
						description="Judges a call in Auto before it runs, where the thread would otherwise ask you. Auto is offered once one is named."
						anchor="setting-review-model"
					>
						<ReviewModel model={environment.review_model} />
					</Row>
				</Section>
			)}
			<ProjectGrants />
			<ArchiveSection />
		</Page>
	);
}

/** The review model's control: a chip naming it, or none, from which the models open; and a button that names none. */
function ReviewModel(props: { readonly model: string | undefined }): ReactNode {
	const client = useClient();
	const directory = useDirectory();
	const [open, setOpen] = useState(false);
	const keep = (model: string): void => {
		client.setSettings({ environment: { review_model: model } }).catch((error: unknown) => failed("The review model could not be kept", error));
	};
	const { model } = props;
	return (
		<>
			<Popover open={open} onOpenChange={setOpen}>
				<PopoverTrigger className={cn(PICKER_TRIGGER, "max-w-72")}>
					{model === undefined ? (
						<span className="text-muted-foreground">None</span>
					) : (
						<span className="flex min-w-0 items-center gap-1.5">
							<VendorMark vendor={vendorOfReference(directory, model)} name={providerName(directory, providerOf(model))} />
							<span className="min-w-0 truncate">{modelLabel(model, directory)}</span>
						</span>
					)}
					<ChevronsUpDown className="size-3.5 shrink-0 text-muted-foreground" />
				</PopoverTrigger>
				<PopoverPopup side="bottom" align="end" className="flex w-[min(34rem,calc(100vw-2rem))] flex-col overflow-hidden">
					<ModelList
						model={model}
						onChoose={(chosen) => {
							keep(chosen);
							setOpen(false);
						}}
						onClose={() => setOpen(false)}
					/>
				</PopoverPopup>
			</Popover>
			{model === undefined ? null : (
				<IconButton label="Name no review model" onClick={() => keep("")}>
					<X className="size-4" />
				</IconButton>
			)}
		</>
	);
}

/** Each action's icon: a pen for an edit, a terminal for a command, a wrench for a server's tool. */
const ACTION_ICONS: Readonly<Record<Action, typeof Wrench>> = { edit: FilePen, command: SquareTerminal, tool: Wrench };

/** What a grant lets go ahead, in words. */
function grantText(action: Action, pattern: string): string {
	if (action === "edit") return pattern === "*" ? "Every edit" : `Edits of ${pattern}`;
	return pattern;
}

/** What the person always allowed, a section for each project, read again once one is taken back; nothing where they allowed nothing. */
function ProjectGrants(): ReactNode {
	const client = useClient();
	const [revision, setRevision] = useState(0);
	const [revoking, startRevoking] = useTransition();
	const outcome = useOutcome("grants.list", {}, revision);
	if (outcome === undefined) return null;
	if ("failure" in outcome) return <p className="px-4 text-ui text-error-foreground">{outcome.failure}</p>;
	const projects = outcome.result.grants.filter((each) => each.allow.length > 0);
	const revoke = (grants: Grants, action: Action, pattern: string): void =>
		startRevoking(async () => {
			try {
				await client.revokeGrant(grants.folder, action, pattern);
				setRevision((count) => count + 1);
			} catch (error) {
				failed("The grant could not be taken back", error);
			}
		});
	return (
		<Section title="Always allowed" description="What you allowed always as a thread asked, kept for its project." anchor="setting-allowed">
			{projects.length === 0 ? (
				<Row title="Nothing yet" description="Choose “Always” as a thread asks, and it is kept here." />
			) : (
				projects.map((grants) => (
					<div key={grants.folder} className="flex flex-col gap-1 px-3.5 py-3">
						<p className="flex items-center gap-2 text-ui font-medium" title={grants.folder}>
							<FolderGit2 className="size-4 text-muted-foreground" />
							{folderName(grants.folder)}
							<span className="min-w-0 truncate text-xs font-normal text-muted-foreground">{grants.folder}</span>
						</p>
						<ul className="flex flex-col">
							{grants.allow.map((grant) => {
								const Icon = ACTION_ICONS[grant.action];
								return (
									<li key={`${grant.action}:${grant.pattern}`} className="flex h-control items-center gap-2 ps-6">
										<Icon className="size-3.5 shrink-0 text-muted-foreground" />
										<span className="min-w-0 flex-1 truncate font-mono text-xs">{grantText(grant.action, grant.pattern)}</span>
										<Button variant="ghost-muted" size="xs" disabled={revoking} onClick={() => revoke(grants, grant.action, grant.pattern)}>
											Take back
										</Button>
									</li>
								);
							})}
						</ul>
					</div>
				))
			)}
		</Section>
	);
}
