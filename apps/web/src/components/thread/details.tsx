/**
 * A thread's details, on a card at the chat's top right where the chat has room for it beside its column, or in a
 * popover from the header's button where it has not: the machine the thread works on and its folder, which opens in
 * the Files view; the folder's repository — its branch, how far ahead of its upstream and behind, and the lines the
 * changes the Diff view shows gained and lost, which open it; the thread it came from and those it delegated to; how
 * full its window is, which opens what fills it and compacts it; and what its model's requests read, wrote and cost,
 * which opens where it went, request by request.
 */
import type { ReactNode } from "react";
import type { Conversation, Listed, Repository, Turn, Usage } from "@octoii-works/octoii-client";
import { useConnection, useThreads } from "@octoii-works/octoii-client/react";
import { Coins, CornerLeftUp, FileDiff, Folder, FolderX, Gauge, GitBranch, Laptop, SquareMenu } from "lucide-react";
import { cachedShare, type Context, contextOf, fullnessOf } from "../../core/details.ts";
import { defaultScope, scopeName, shortCount, totalsOf } from "../../core/diff.ts";
import { modelOf } from "../../core/models.ts";
import { dollarsFormat, tokens, TOKENS_FORMAT } from "../../core/numbers.ts";
import { standingOf, workedOf } from "../../core/sub-threads.ts";
import { folderName, subThreadsOf, threadTitle } from "../../core/threads.ts";
import { useDirectory } from "../composer/directory.ts";
import { useOutcome } from "../effects/read.ts";
import { showDetails, useDetailsShown } from "../state/details.ts";
import { go } from "../state/navigation.ts";
import { showSurface, useThreadPanel } from "../state/panel.ts";
import { IconButton, ToggleButton } from "../ui/button.tsx";
import { cn } from "../ui/cn.ts";
import { Meter } from "../ui/meter.tsx";
import { Popover, PopoverPopup, PopoverTrigger } from "../ui/popover.tsx";
import { RollingNumber } from "../ui/rolling-number.tsx";
import { SpendingCard } from "./spending.tsx";
import { ContextCard } from "./context-card.tsx";
import { isCompacting } from "../../core/context.ts";
import { SubThreadAvatar, WorkedFor } from "./sub-thread.tsx";

/** What the card tells of: the thread, as it is listed, its turns, and where its turns stand, which its repository is read again at. */
export type DetailsProps = {
	readonly thread: string;
	readonly row: Listed | undefined;
	readonly turns: readonly Turn[];
	/** The thread's compactions, whose requests' spending its card tells among the turns'. */
	readonly compactions: Conversation["compactions"];
	readonly revision: string;
};

/**
 * The header's buttons of the card: where the chat has room, one that shows the card beside the column or hides it;
 * where it has not, one that opens it as a popover.
 */
export function DetailsButtons(props: DetailsProps): ReactNode {
	const shown = useDetailsShown();
	return (
		<>
			<ToggleButton label="Thread details" pressed={shown} onPressedChange={showDetails} className="hidden details-inline:inline-flex">
				<SquareMenu className="size-4" />
			</ToggleButton>
			<Popover>
				<PopoverTrigger render={<IconButton label="Thread details" className="details-inline:hidden" />}>
					<SquareMenu className="size-4" />
				</PopoverTrigger>
				<PopoverPopup side="bottom" align="end" className="w-(--details-width) max-w-[calc(100vw-1rem)]">
					<DetailsCard {...props} />
				</PopoverPopup>
			</Popover>
		</>
	);
}

/** The card beside the chat's column, at its top right, where the chat has room for it and the person shows it; fading in as it comes. */
export function InlineDetails(props: DetailsProps): ReactNode {
	if (!useDetailsShown()) return null;
	return (
		<aside
			aria-label="Thread details"
			className="floating absolute top-[calc(var(--topbar-height)+0.25rem)] right-3 z-20 hidden max-h-[calc(100%-var(--topbar-height)-1rem)] w-(--details-width) overflow-y-auto rounded-md transition-[opacity,scale] duration-150 details-inline:block starting:scale-98 starting:opacity-0 motion-reduce:transition-none"
		>
			<DetailsCard {...props} />
		</aside>
	);
}

/** The card's sections, a line between each two. */
function DetailsCard(props: DetailsProps): ReactNode {
	const folder = props.row?.manifest.workspace;
	return (
		<div className="flex flex-col divide-y divide-border text-ui">
			<Workspace thread={props.thread} folder={folder} />
			{folder === undefined ? null : <VersionControl thread={props.thread} folder={folder} revision={props.revision} />}
			<Lineage thread={props.thread} row={props.row} />
			<Spending thread={props.thread} row={props.row} turns={props.turns} compactions={props.compactions} />
		</div>
	);
}

/** A row of the card: its icon, its words and what it says at its end; a button where it opens something. */
function DetailRow(props: {
	readonly icon: ReactNode;
	readonly label: ReactNode;
	readonly aside?: ReactNode;
	readonly title?: string | undefined;
	readonly onOpen?: () => void;
}): ReactNode {
	const content = <RowContent icon={props.icon} label={props.label} aside={props.aside} />;
	if (props.onOpen === undefined) {
		return (
			<div title={props.title} className={ROW}>
				{content}
			</div>
		);
	}
	return (
		<button type="button" title={props.title} onClick={props.onOpen} className={cn(ROW, OPENING)}>
			{content}
		</button>
	);
}

/** A row's look, and that of one that opens something. */
const ROW = "flex h-control w-full min-w-0 items-center gap-2.5 rounded-md px-2 text-left [&>svg]:size-4 [&>svg]:shrink-0 [&>svg]:text-muted-foreground";
const OPENING =
	"cursor-pointer hover:bg-accent focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none focus-visible:ring-inset data-popup-open:bg-accent";

/** A row's icon, its words, and what stands beside them. */
function RowContent(props: { readonly icon: ReactNode; readonly label: ReactNode; readonly aside?: ReactNode }): ReactNode {
	return (
		<>
			{props.icon}
			<span className="min-w-0 flex-1 truncate">{props.label}</span>
			{props.aside === undefined ? null : <span className="flex shrink-0 items-center gap-1.5 text-xs text-muted-foreground tabular-nums">{props.aside}</span>}
		</>
	);
}

/** The machine the thread works on, by the name it goes by; and its folder, opened in the Files view, or that it works in none. */
function Workspace(props: { readonly thread: string; readonly folder: string | undefined }): ReactNode {
	const connection = useConnection();
	const machine = connection.status === "open" ? connection.environment : undefined;
	const { folder } = props;
	return (
		<section className="p-1.5">
			<DetailRow icon={<Laptop />} label={machine ?? "This machine"} />
			{folder === undefined ? (
				<DetailRow icon={<FolderX />} label="Works in no folder" />
			) : (
				<DetailRow icon={<Folder />} label={folderName(folder)} title={folder} onOpen={() => showSurface(props.thread, "files")} />
			)}
		</section>
	);
}

/** The repository the thread's folder is in: its branch and how it stands against its upstream, and its changes; or that it is in none. */
function VersionControl(props: { readonly thread: string; readonly folder: string; readonly revision: string }): ReactNode {
	const outcome = useOutcome("git.repository", { path: props.folder }, props.revision);
	if (outcome === undefined) return null;
	if ("failure" in outcome) {
		return (
			<section className="p-1.5">
				<DetailRow icon={<GitBranch />} label={outcome.failure} title={outcome.failure} />
			</section>
		);
	}
	const repository = outcome.result.repository;
	if (repository === undefined) {
		return (
			<section className="p-1.5">
				<DetailRow icon={<GitBranch />} label="Not a git repository" />
			</section>
		);
	}
	const tracking = [repository.ahead > 0 ? `↑${String(repository.ahead)}` : "", repository.behind > 0 ? `↓${String(repository.behind)}` : ""].join(" ").trim();
	return (
		<section className="p-1.5">
			<DetailRow
				icon={<GitBranch />}
				label={repository.branch ?? `Detached at ${repository.head?.slice(0, 7) ?? "no commit"}`}
				title={repository.upstream === undefined ? repository.branch : `${repository.branch ?? "HEAD"} → ${repository.upstream}`}
				{...(tracking === "" ? {} : { aside: tracking })}
			/>
			<Changes thread={props.thread} folder={props.folder} repository={repository} revision={props.revision} />
		</section>
	);
}

/** The changes the thread's Diff view shows — the branch's where the person chose none — by the lines they gained and lost, which open the view. */
function Changes(props: { readonly thread: string; readonly folder: string; readonly repository: Repository; readonly revision: string }): ReactNode {
	const scope = useThreadPanel(props.thread).scope ?? defaultScope(props.repository);
	const outcome = useOutcome("git.changes", { path: props.folder, scope }, props.revision);
	const totals = outcome !== undefined && "result" in outcome ? totalsOf(outcome.result.files) : undefined;
	return (
		<DetailRow
			icon={<FileDiff />}
			label={scopeName(scope, [])}
			onOpen={() => showSurface(props.thread, "diff")}
			{...(totals === undefined
				? {}
				: {
						aside: (
							<span className="font-mono">
								<span className="text-diff-add">+{shortCount(totals.additions)}</span> <span className="text-diff-remove">−{shortCount(totals.deletions)}</span>
							</span>
						),
					})}
		/>
	);
}

/** The thread the thread came from, and those it delegated to, each opened from its row; nothing where it has none of either. */
function Lineage(props: { readonly thread: string; readonly row: Listed | undefined }): ReactNode {
	const rows = useThreads() ?? [];
	const parent = props.row?.manifest.parent?.thread;
	const children = subThreadsOf(rows, props.thread);
	if (parent === undefined && children.length === 0) return null;
	const parentRow = rows.find((each) => each.id === parent);
	return (
		<section className="p-1.5">
			{parent === undefined ? null : (
				<DetailRow
					icon={<CornerLeftUp />}
					label={parentRow === undefined ? "The thread it came from" : threadTitle(parentRow)}
					aside="Parent"
					onOpen={() => go({ place: "thread", thread: parent })}
				/>
			)}
			{children.map((child) => {
				const worked = workedOf([child]);
				return (
					<DetailRow
						key={child.id}
						icon={<SubThreadAvatar standing={standingOf(child)} />}
						label={threadTitle(child)}
						{...(worked === undefined ? {} : { aside: <WorkedFor worked={worked} /> })}
						onOpen={() => go({ place: "thread", thread: child.id })}
					/>
				);
			})}
		</section>
	);
}

/** How full the thread's window is, and what its model's requests used; nothing before any request told of either. */
function Spending(props: {
	readonly thread: string;
	readonly row: Listed | undefined;
	readonly turns: readonly Turn[];
	readonly compactions: Conversation["compactions"];
}): ReactNode {
	const window = modelOf(useDirectory(), props.row?.manifest.model)?.context_length;
	const context = contextOf(props.turns, window);
	const usage = props.row?.standing.usage;
	if (context === undefined && usage === undefined) return null;
	return (
		<section className="p-1.5">
			{context === undefined ? null : <ContextRow thread={props.thread} context={context} compacting={isCompacting(props.row)} />}
			{usage === undefined ? null : <UsageRow usage={usage} turns={props.turns} compactions={props.compactions} />}
		</section>
	);
}

/** Each fullness's tone. */
const TONES = { room: "default", filling: "warning", full: "error" } as const;

/** How full the window is: the tokens it holds of the most its model takes, and a meter of it, opening what fills it; while it compacts, so told. */
function ContextRow(props: { readonly thread: string; readonly context: Context; readonly compacting: boolean }): ReactNode {
	const { used, window } = props.context;
	const words = `${tokens(used)} of ${tokens(window)} tokens`;
	return (
		<Popover>
			<PopoverTrigger render={<button type="button" className={cn("flex w-full flex-col gap-1.5 rounded-md px-2 pt-1.5 pb-2 text-left", OPENING)} />}>
				<span className="flex w-full items-center gap-2.5 [&>svg]:size-4 [&>svg]:shrink-0 [&>svg]:text-muted-foreground">
					<Gauge />
					<span className="flex-1">{props.compacting ? <span className="shimmer">Compacting</span> : "Context"}</span>
					<span className="text-xs text-muted-foreground tabular-nums">
						<RollingNumber value={used} format={TOKENS_FORMAT} /> / {tokens(window)}
					</span>
				</span>
				<Meter value={used} max={window} label="Context" valueText={words} tone={TONES[fullnessOf(props.context)]} />
			</PopoverTrigger>
			<PopoverPopup side="left" align="start" sideOffset={12} className="w-[min(22rem,calc(100vw-2rem))] p-0">
				<ContextCard thread={props.thread} window={window} compacting={props.compacting} />
			</PopoverPopup>
		</Popover>
	);
}

/** What the thread's requests read and wrote — how much of it came from the cache — and what they cost, opening where it went. */
function UsageRow(props: { readonly usage: Usage; readonly turns: readonly Turn[]; readonly compactions: Conversation["compactions"] }): ReactNode {
	const { usage } = props;
	const cached = cachedShare(usage);
	const read = `${tokens(usage.input_tokens)} in · ${tokens(usage.output_tokens)} out`;
	const dollars = usage.cost_nanodollars / 1e9;
	return (
		<Popover>
			<PopoverTrigger
				render={
					<button type="button" title={cached === undefined ? read : `${read}, ${String(cached)}% of what was read cached`} className={cn(ROW, OPENING)} />
				}
			>
				<RowContent
					icon={<Coins />}
					label={usage.cost_nanodollars > 0 ? <RollingNumber value={dollars} format={dollarsFormat(dollars)} /> : "Usage"}
					aside={
						<span>
							<RollingNumber value={usage.input_tokens} format={TOKENS_FORMAT} /> in · <RollingNumber value={usage.output_tokens} format={TOKENS_FORMAT} /> out
						</span>
					}
				/>
			</PopoverTrigger>
			<PopoverPopup side="left" align="start" sideOffset={12} className="w-[min(40rem,calc(100vw-2rem))] p-0">
				<SpendingCard usage={usage} turns={props.turns} compactions={props.compactions} />
			</PopoverPopup>
		</Popover>
	);
}
