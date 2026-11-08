/**
 * The chat's header: the sidebar's button where the sidebar is hidden — always where the page is narrow, the sidebar
 * a drawer over it there — the project and the thread's title as a
 * breadcrumb, a pill of how the thread stands while it works, waits on the person or failed, and on its right what the
 * page puts there — a thread's details' buttons — and the right panel's button where the panel is hidden.
 */
import type { ReactNode } from "react";
import { PanelLeft, PanelRight } from "lucide-react";
import type { ThreadStatus } from "../../core/threads.ts";
import { IconButton } from "../ui/button.tsx";
import { Monogram } from "../ui/monogram.tsx";
import { Pill } from "../ui/pill.tsx";
import { StatusMark } from "./status-mark.tsx";

/** What the header shows and does: what stands on its right, and what shows the right panel, where it is hidden. */
export type HeaderProps = {
	readonly project?: string;
	readonly title: string;
	readonly status?: ThreadStatus | undefined;
	readonly sidebarHidden: boolean;
	readonly onShowSidebar: () => void;
	readonly actions?: ReactNode;
	readonly onShowPanel?: () => void;
};

/** The header. */
export function ChatHeader(props: HeaderProps): ReactNode {
	return (
		<header className="flex h-[var(--topbar-height)] shrink-0 items-center gap-2 bg-background px-3 sm:px-5">
			{props.sidebarHidden ? (
				<IconButton label="Show sidebar" shortcut="⌘B" onClick={props.onShowSidebar} className="-ml-1">
					<PanelLeft className="size-4" />
				</IconButton>
			) : (
				<IconButton label="Show sidebar" onClick={props.onShowSidebar} className="-ml-1 md:hidden">
					<PanelLeft className="size-4" />
				</IconButton>
			)}
			<div className="flex min-w-0 flex-1 items-center gap-1.5 text-sm">
				{props.project === undefined ? null : (
					<>
						<Monogram name={props.project} />
						<span className="max-w-40 truncate text-muted-foreground">{props.project}</span>
						<span className="text-muted-foreground/60">/</span>
					</>
				)}
				<h2 className="min-w-0 truncate font-medium text-foreground">{props.title}</h2>
				{props.status === undefined ? null : <StatusPill status={props.status} />}
			</div>
			{props.actions}
			{props.onShowPanel === undefined ? null : (
				<IconButton label="Show the panel" shortcut="⌘⌥B" onClick={props.onShowPanel} className="-mr-1">
					<PanelRight className="size-4" />
				</IconButton>
			)}
		</header>
	);
}

/** How the thread stands, as a pill: waiting on the person, working, or failed; nothing at rest. */
function StatusPill(props: { readonly status: ThreadStatus }): ReactNode {
	switch (props.status) {
		case "asks":
			return (
				<Pill tone="waiting" icon={<StatusMark status="asks" />}>
					Needs you
				</Pill>
			);
		case "working":
			return (
				<Pill tone="running" icon={<StatusMark status="working" />}>
					Running
				</Pill>
			);
		case "failed":
			return (
				<Pill tone="failed" icon={<StatusMark status="failed" />}>
					Failed
				</Pill>
			);
		case "ready":
			return null;
	}
}
