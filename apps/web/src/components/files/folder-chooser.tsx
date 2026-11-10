/**
 * A folder of the machine's chosen as a file manager's "choose a folder" chooses one: places on the left — the home
 * folder, the machine's root, and the projects threads work in — and on the right the folders of the one open, the way
 * to it over them, each step opening it, those between its first and its last three folded into a menu where the way is
 * long. The folders hold the focus as it opens. A folder is picked by a click and opened by a double click or Enter; the one
 * above by its button or Backspace; the arrows walk the folders; hidden ones show as asked; a path may be typed instead,
 * Enter going there. Choose takes the folder picked, else the one open, by its path whole and clean.
 */
import { type KeyboardEvent, type ReactNode, type Ref, useRef, useState } from "react";
import { useClient } from "@octoii-works/octoii-client/react";
import { ArrowUp, Ellipsis, Folder, FolderSymlink, HardDrive, House, TextCursorInput } from "lucide-react";
import { childPath, type Crumb, foldersAmong, wayTo } from "../../core/files.ts";
import type { Project } from "../../core/threads.ts";
import { useFolder } from "../effects/folder.ts";
import { failureOf, useRead } from "../effects/read.ts";
import { Button, IconButton } from "../ui/button.tsx";
import { cn } from "../ui/cn.ts";
import { Dialog, DialogClose, DialogPopup, DialogTitle } from "../ui/dialog.tsx";
import { Input } from "../ui/input.tsx";
import { Menu, MenuItem, MenuItemLabel, MenuPopup, MenuTrigger } from "../ui/menu.tsx";
import { ProjectMark } from "./project-mark.tsx";
import { Switch } from "../ui/switch.tsx";

/** What the chooser is given: whether it is open, where it opens — the home folder where nowhere — the projects it offers, and what is told of the folder chosen. */
export type FolderChooserProps = {
	readonly open: boolean;
	readonly onOpenChange: (open: boolean) => void;
	readonly start: string | undefined;
	readonly projects: readonly Project[];
	readonly onChoose: (folder: string) => void;
};

/** The chooser, made anew each time it opens, so it opens where it is asked to, the folders holding the focus. */
export function FolderChooser(props: FolderChooserProps): ReactNode {
	const list = useRef<HTMLUListElement>(null);
	return (
		<Dialog open={props.open} onOpenChange={props.onOpenChange}>
			<DialogPopup initialFocus={list} className="h-[min(34rem,calc(100vh-4rem))] w-[46rem] max-w-[calc(100vw-2rem)] overflow-hidden">
				<DialogTitle className="sr-only">Choose a folder</DialogTitle>
				{props.open ? <Chooser {...props} ref={list} /> : null}
			</DialogPopup>
		</Dialog>
	);
}

/** The places and the folder open, with what the person does in it; `ref` the folders' list, which holds the focus as it opens. */
function Chooser({ ref, ...props }: FolderChooserProps & { readonly ref: Ref<HTMLUListElement> }): ReactNode {
	const [at, setAt] = useState(props.start ?? HOME);
	const [picked, setPicked] = useState<string | undefined>(undefined);
	const [hidden, setHidden] = useState(false);
	const home = useRead("files.list", { path: HOME })?.path;
	const folder = useFolder(at);
	const open = folder !== undefined && "path" in folder ? folder.path : undefined;
	const go = (path: string): void => {
		setAt(path);
		setPicked(undefined);
	};
	const up = open === undefined || open === "/" ? undefined : (): void => go(open.slice(0, open.lastIndexOf("/")) || "/");
	const chosen = picked ?? open;
	return (
		<div className="flex min-h-0 flex-1">
			<Places home={home} at={open} projects={props.projects} onGo={go} />
			<div className="flex min-w-0 flex-1 flex-col">
				<WayBar open={open} home={home} up={up} onGo={go} />
				<Folders
					ref={ref}
					folder={folder}
					hidden={hidden}
					picked={picked}
					onPick={setPicked}
					onOpen={go}
					onUp={up}
					onChoose={() => (chosen === undefined ? undefined : props.onChoose(chosen))}
				/>
				<footer className="flex items-center gap-3 border-t border-border px-3 py-2.5">
					<label className="flex items-center gap-2 text-xs text-muted-foreground">
						<Switch aria-label="Show hidden folders" checked={hidden} onCheckedChange={setHidden} />
						Hidden folders
					</label>
					<span title={chosen} className="min-w-0 flex-1 truncate text-right font-mono text-2xs text-muted-foreground">
						{chosen}
					</span>
					<DialogClose render={<Button variant="outline" size="sm" />}>Cancel</DialogClose>
					<Button size="sm" disabled={chosen === undefined} onClick={() => (chosen === undefined ? undefined : props.onChoose(chosen))}>
						Choose
					</Button>
				</footer>
			</div>
		</div>
	);
}

/** Where the chooser opens where it is asked to open nowhere, and the home place: the home folder. */
const HOME = "~";

/** The places: the home folder, the machine's root, and the projects threads work in — the one open marked. */
function Places(props: {
	readonly home: string | undefined;
	readonly at: string | undefined;
	readonly projects: readonly Project[];
	readonly onGo: (path: string) => void;
}): ReactNode {
	return (
		<nav aria-label="Places" className="flex w-48 shrink-0 flex-col gap-px overflow-y-auto border-r border-border bg-sidebar p-2">
			<Place label="Home" icon={<House />} current={props.at !== undefined && props.at === props.home} onGo={() => props.onGo(HOME)} />
			<Place label="Computer" icon={<HardDrive />} current={props.at === "/"} onGo={() => props.onGo("/")} />
			{props.projects.length === 0 ? null : <p className="label-caps px-2 pt-3 pb-1">Projects</p>}
			{props.projects.map((project) => (
				<Place
					key={project.folder}
					label={project.name}
					title={project.folder}
					icon={<ProjectMark project={project} />}
					current={props.at === project.folder}
					onGo={() => props.onGo(project.folder)}
				/>
			))}
		</nav>
	);
}

/** A place: its icon and name, marked where it is the folder open. */
function Place(props: {
	readonly label: string;
	readonly title?: string;
	readonly icon: ReactNode;
	readonly current: boolean;
	readonly onGo: () => void;
}): ReactNode {
	return (
		<button
			type="button"
			title={props.title}
			aria-current={props.current ? "true" : undefined}
			onClick={props.onGo}
			className="flex h-control-sm w-full min-w-0 shrink-0 items-center gap-2 rounded-md px-2 text-left text-ui text-muted-foreground hover:bg-accent aria-[current=true]:bg-selected aria-[current=true]:text-foreground [&>svg]:size-3.5 [&>svg]:shrink-0 [&>svg]:text-muted-foreground"
		>
			{props.icon}
			<span className="truncate">{props.label}</span>
		</button>
	);
}

/** Over the folders: the folder above, the way to the one open, each step opening it — or the path typed in its place. */
function WayBar(props: {
	readonly open: string | undefined;
	readonly home: string | undefined;
	readonly up: (() => void) | undefined;
	readonly onGo: (path: string) => void;
}): ReactNode {
	const [typing, setTyping] = useState(false);
	return (
		<div className="flex h-11 shrink-0 items-center gap-1 border-b border-border px-2">
			<IconButton label="The folder above" disabled={props.up === undefined} onClick={props.up}>
				<ArrowUp className="size-4" />
			</IconButton>
			{typing ? (
				<PathField
					start={props.open ?? ""}
					onGo={(path) => {
						setTyping(false);
						props.onGo(path);
					}}
					onCancel={() => setTyping(false)}
				/>
			) : (
				<>
					{props.open === undefined ? <span className="flex-1" /> : <Way way={wayTo(props.open, props.home)} onGo={props.onGo} />}
					<IconButton label="Type a path" onClick={() => setTyping(true)}>
						<TextCursorInput className="size-4" />
					</IconButton>
				</>
			)}
		</div>
	);
}

/** How many of a way's last steps stand in it, after its first, where it is longer: those between them fold into a menu. */
const WAY_KEPT = 3;

/** The way to the folder open, each step opening it, its own last; those between its first and its last few in a menu where it is long. */
function Way(props: { readonly way: readonly Crumb[]; readonly onGo: (path: string) => void }): ReactNode {
	const { way } = props;
	const [first, ...rest] = way;
	const folded = rest.length > WAY_KEPT ? rest.slice(0, -WAY_KEPT) : [];
	const kept = rest.slice(folded.length);
	const last = way.at(-1);
	const step = (crumb: Crumb): ReactNode => (
		<li key={crumb.path} className="flex min-w-0 items-center gap-0.5">
			{crumb === first ? null : <span className="text-faint-foreground">›</span>}
			<button
				type="button"
				title={crumb.path}
				onClick={() => props.onGo(crumb.path)}
				className={cn("truncate rounded-md px-1.5 py-0.5 hover:bg-accent", crumb === last ? "text-foreground" : "text-muted-foreground")}
			>
				{crumb.name}
			</button>
		</li>
	);
	return (
		<ol className="flex min-w-0 flex-1 items-center gap-0.5 overflow-hidden text-ui">
			{first === undefined ? null : step(first)}
			{folded.length === 0 ? null : (
				<li className="flex shrink-0 items-center gap-0.5">
					<span className="text-faint-foreground">›</span>
					<Menu>
						<MenuTrigger render={<IconButton label="The folders between" size="icon-xs" />}>
							<Ellipsis />
						</MenuTrigger>
						<MenuPopup className="w-56">
							{folded.map((crumb) => (
								<MenuItem key={crumb.path} onClick={() => props.onGo(crumb.path)}>
									<Folder />
									<MenuItemLabel title={crumb.path}>{crumb.name}</MenuItemLabel>
								</MenuItem>
							))}
						</MenuPopup>
					</Menu>
				</li>
			)}
			{kept.map(step)}
		</ol>
	);
}

/** A path typed: Enter goes to the folder it names, as the node finds it; Escape gives the way back. */
function PathField(props: { readonly start: string; readonly onGo: (path: string) => void; readonly onCancel: () => void }): ReactNode {
	const client = useClient();
	const [typed, setTyped] = useState(props.start);
	const [refused, setRefused] = useState<string | undefined>(undefined);
	const keyDown = (event: KeyboardEvent<HTMLInputElement>): void => {
		if (event.key === "Escape") {
			event.preventDefault();
			event.stopPropagation();
			props.onCancel();
		} else if (event.key === "Enter") {
			event.preventDefault();
			client.call("files.list", { path: typed.trim() }).then(
				(page) => props.onGo(page.path),
				(error: unknown) => setRefused(failureOf(error)),
			);
		}
	};
	return (
		<div className="flex min-w-0 flex-1 items-center gap-2">
			<Input
				autoFocus
				aria-label="Path"
				aria-invalid={refused !== undefined}
				placeholder="~/path/to/a/folder"
				value={typed}
				onValueChange={(value) => {
					setTyped(value);
					setRefused(undefined);
				}}
				onKeyDown={keyDown}
				className="h-control-sm min-w-0 flex-1 font-mono text-xs"
			/>
			{refused === undefined ? null : (
				<span title={refused} className="max-w-1/2 shrink-0 truncate text-xs text-error-foreground">
					{refused}
				</span>
			)}
		</div>
	);
}

/**
 * The folders of the one open, hidden ones as asked: picked by a click, opened by a double click; the arrows walk them,
 * Enter opens the one picked, ⌘Enter chooses, Backspace goes to the folder above.
 */
function Folders({
	ref,
	...props
}: {
	readonly ref: Ref<HTMLUListElement>;
	readonly folder: ReturnType<typeof useFolder>;
	readonly hidden: boolean;
	readonly picked: string | undefined;
	readonly onPick: (path: string) => void;
	readonly onOpen: (path: string) => void;
	readonly onUp: (() => void) | undefined;
	readonly onChoose: () => void;
}): ReactNode {
	const { folder } = props;
	const read = folder !== undefined && "path" in folder ? folder : undefined;
	const paths = read === undefined ? [] : foldersAmong(read.entries, props.hidden).map((entry) => ({ entry, path: childPath(read.path, entry.name) }));
	const index = paths.findIndex((each) => each.path === props.picked);
	const keyDown = (event: KeyboardEvent<HTMLUListElement>): void => {
		const step = event.key === "ArrowDown" ? 1 : event.key === "ArrowUp" ? -1 : 0;
		const next = paths[Math.max(0, Math.min(paths.length - 1, index + step))];
		if (step !== 0 && next !== undefined) {
			event.preventDefault();
			props.onPick(next.path);
			// The folder picked is kept in view as the arrows walk past the list's edge.
			event.currentTarget.querySelector(`[data-path="${CSS.escape(next.path)}"]`)?.scrollIntoView({ block: "nearest" });
		} else if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
			event.preventDefault();
			props.onChoose();
		} else if (event.key === "Enter" && props.picked !== undefined) {
			event.preventDefault();
			props.onOpen(props.picked);
		} else if (event.key === "Backspace" && props.onUp !== undefined) {
			event.preventDefault();
			props.onUp();
		}
	};
	return (
		<ul ref={ref} role="listbox" aria-label="Folders" tabIndex={0} onKeyDown={keyDown} className="min-h-0 flex-1 overflow-y-auto p-1.5 outline-none">
			{folder === undefined ? (
				<Note>Reading…</Note>
			) : read === undefined ? (
				<Note>{folder.failure}</Note>
			) : paths.length === 0 ? (
				<Note>No folders here.</Note>
			) : null}
			{paths.map(({ entry, path }) => (
				<li
					key={entry.name}
					role="option"
					data-path={path}
					aria-selected={path === props.picked}
					onClick={() => props.onPick(path)}
					onDoubleClick={() => props.onOpen(path)}
					className="flex h-control-sm cursor-default items-center gap-2 rounded-md px-2 text-ui select-none hover:bg-accent aria-selected:bg-accent aria-selected:text-foreground [&>svg]:size-3.5 [&>svg]:shrink-0 [&>svg]:text-muted-foreground"
				>
					{entry.kind === "link" ? <FolderSymlink /> : <Folder />}
					<span className="truncate">{entry.name}</span>
				</li>
			))}
			{read?.readMore === undefined ? null : (
				<li>
					<button type="button" onClick={read.readMore} className="px-2 py-1 text-xs text-muted-foreground hover:text-foreground">
						Show more
					</button>
				</li>
			)}
			{read?.failure === undefined ? null : <Note>{read.failure}</Note>}
		</ul>
	);
}

/** A line of the chooser's own words, where it shows no folders. */
function Note(props: { readonly children: ReactNode }): ReactNode {
	return <p className="px-3 py-6 text-center text-xs text-muted-foreground">{props.children}</p>;
}
