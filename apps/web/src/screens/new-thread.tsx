/**
 * A new thread: "What should we build in <project>?" over the composer, in the middle of the page, and under the
 * composer, joined to it, the folder the thread will work in — a menu, opening upward, of the folders threads work in,
 * none, or another chosen as a file manager chooses one — and on its right the MCP servers a thread there would use.
 * Sending makes the thread there, with the model chosen — the one the newest thread chose where none is — the mode
 * chosen, else the one the environment's settings name, and the message's first line as its title, delivers the
 * message, and goes to the thread.
 */
import { type ReactNode, useState } from "react";
import type { Effort, Mode } from "@octoii-works/octoii-client";
import { useClient, useSettings, useThreads } from "@octoii-works/octoii-client/react";
import { ChevronDown, FolderOpen, FolderPlus, FolderX } from "lucide-react";
import type { Device } from "../core/device.ts";
import { recentModelsOf } from "../core/models.ts";
import { contentOf } from "../core/attachments.ts";
import { folderName, type Project, projectsOf } from "../core/threads.ts";
import { Composer } from "../components/composer/composer.tsx";
import { FolderChooser } from "../components/files/folder-chooser.tsx";
import { go } from "../components/state/navigation.ts";
import { ChatHeader } from "../components/thread/header.tsx";
import { Menu, MenuItem, MenuItemLabel, MenuPopup, MenuRadioGroup, MenuRadioItem, MenuSeparator, MenuTrigger } from "../components/ui/menu.tsx";
import { Monogram } from "../components/ui/monogram.tsx";
import { ServersMenu } from "../components/servers/servers-menu.tsx";

/** What the new thread's page is given: the project's folder asked for, the device's settings, and the sidebar's state. */
export type NewThreadScreenProps = {
	readonly project: string | undefined;
	readonly device: Device;
	readonly sidebarHidden: boolean;
	readonly onShowSidebar: () => void;
};

/** The folder the person chose to work in, or that they chose none. */
type Chosen = { readonly folder: string | undefined };

/** The new thread's page. */
export function NewThreadScreen(props: NewThreadScreenProps): ReactNode {
	const client = useClient();
	const rows = useThreads() ?? [];
	const projects = projectsOf(rows);
	const [chosen, setChosen] = useState<Chosen | undefined>(undefined);
	const [choosing, setChoosing] = useState(false);
	const [model, setModel] = useState<string | undefined>(undefined);
	const [chosenMode, setMode] = useState<Mode | undefined>(undefined);
	const [effort, setEffort] = useState<Effort | undefined>(undefined);
	const settings = useSettings();
	const mode = chosenMode ?? settings?.environment.thread_mode;
	const folder = chosen === undefined ? (props.project ?? projects[0]?.folder) : chosen.folder;
	const running = model ?? recentModelsOf(rows)[0];
	const choose = (next: string | undefined): void => {
		setChosen({ folder: next });
		setChoosing(false);
	};
	return (
		<div className="panel relative flex min-w-0 flex-1 flex-col overflow-hidden">
			<ChatHeader
				title="New thread"
				{...(folder === undefined ? {} : { project: folderName(folder) })}
				sidebarHidden={props.sidebarHidden}
				onShowSidebar={props.onShowSidebar}
			/>
			<div className="flex flex-1 items-center justify-center px-4 pb-[12vh]">
				<div className="w-full max-w-[var(--chat-width)]">
					<h1 className="mb-6 text-center text-2xl font-normal tracking-tight sm:text-3xl">
						{folder === undefined ? "What should we work on?" : `What should we build in ${folderName(folder)}?`}
					</h1>
					{/* The composer stands over the folder's strip, which shows from under its foot. */}
					<div className="relative z-10">
						<Composer
							model={running}
							onModel={setModel}
							mode={mode}
							onMode={setMode}
							effort={effort}
							onEffort={setEffort}
							working={false}
							sendShortcut={props.device.send_shortcut}
							draft={{ project: folder }}
							folder={folder}
							onSend={async ({ text, attachments }) => {
								const thread = await client.create({
									...(folder === undefined ? {} : { workspace: folder }),
									...(running === undefined ? {} : { model: running }),
									...(chosenMode === undefined ? {} : { mode: chosenMode }),
									...(effort === undefined ? {} : { effort }),
								});
								await client.deliver(thread, { message: { role: "user", content: contentOf(text, attachments) } });
								go({ place: "thread", thread });
							}}
							onStop={() => undefined}
						/>
					</div>
					<FolderStrip folder={folder} projects={projects} onChoose={choose} onAnother={() => setChoosing(true)} />
					<FolderChooser open={choosing} onOpenChange={setChoosing} start={folder} projects={projects} onChoose={choose} />
				</div>
			</div>
		</div>
	);
}

/**
 * Under the composer, joined to it: the folder the thread will work in, by its name, and a menu of the folders threads
 * work in to choose instead — the one chosen checked — none, and another folder; on its right, the servers. Both open
 * upward, as what stands under the composer has the page's room above it.
 */
function FolderStrip(props: {
	readonly folder: string | undefined;
	readonly projects: readonly Project[];
	readonly onChoose: (folder: string | undefined) => void;
	readonly onAnother: () => void;
}): ReactNode {
	return (
		<div className="-mt-5 flex items-center justify-between gap-2 rounded-b-[20px] border border-t-0 border-black/[0.08] bg-muted/50 px-2 pt-6 pb-1.5 dark:border-white/[0.08]">
			<Menu>
				<MenuTrigger
					title={props.folder}
					className="inline-flex h-control-sm max-w-full items-center gap-1.5 rounded-md px-2 text-xs text-muted-foreground outline-none hover:bg-accent hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring/70 data-popup-open:bg-accent data-popup-open:text-foreground"
				>
					<FolderOpen className="size-3.5 shrink-0" />
					<span className="truncate">{props.folder === undefined ? "No project" : folderName(props.folder)}</span>
					<ChevronDown className="size-3.5 shrink-0 opacity-70" />
				</MenuTrigger>
				<MenuPopup side="top" align="start" sideOffset={8} className="w-64">
					<MenuRadioGroup value={props.folder ?? ""} onValueChange={(folder: string) => props.onChoose(folder === "" ? undefined : folder)}>
						{props.projects.map((project) => (
							<MenuRadioItem key={project.folder} value={project.folder}>
								<Monogram name={project.name} />
								<MenuItemLabel title={project.folder}>{project.name}</MenuItemLabel>
							</MenuRadioItem>
						))}
						<MenuRadioItem value="">
							<FolderX />
							<MenuItemLabel>No project</MenuItemLabel>
						</MenuRadioItem>
					</MenuRadioGroup>
					<MenuSeparator />
					<MenuItem onClick={props.onAnother}>
						<FolderPlus />
						<MenuItemLabel>Choose a folder…</MenuItemLabel>
					</MenuItem>
				</MenuPopup>
			</Menu>
			<ServersMenu folder={props.folder} />
		</div>
	);
}
