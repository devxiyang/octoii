/**
 * The page's header: the frame's button that shows the sidebar, where it is not beside the page; the project and the
 * thread's title as a breadcrumb, the project by its mark alone where the page's column is narrow, so that the title
 * has the room; a pill of how the thread stands while it works, waits on the person or failed; and on its right what
 * the page puts there — a thread's, the frame's button that shows its panel.
 */
import type { ReactNode } from "react";
import type { Project, ThreadStatus } from "../../core/threads.ts";
import { ProjectMark } from "../files/project-mark.tsx";
import { ShowSidebar } from "../frame/frame.tsx";
import { Pill } from "../ui/pill.tsx";
import { StatusMark } from "./status-mark.tsx";

/** What the header shows: the thread's project, title and standing, and what stands on its right. */
export type HeaderProps = {
	readonly project?: Project;
	readonly title: string;
	readonly status?: ThreadStatus | undefined;
	readonly actions?: ReactNode;
};

/** The header. */
export function ChatHeader(props: HeaderProps): ReactNode {
	return (
		<header className="flex h-[var(--topbar-height)] shrink-0 items-center gap-2 bg-background px-3 @xl/pane:px-5">
			<ShowSidebar className="-ml-1" />
			<div className="flex min-w-0 flex-1 items-center gap-1.5 text-ui">
				{props.project === undefined ? null : (
					<>
						<ProjectMark project={props.project} />
						<span className="max-w-40 truncate text-muted-foreground @max-xl/pane:hidden">{props.project.name}</span>
						<span className="text-faint-foreground @max-xl/pane:hidden">/</span>
					</>
				)}
				<h2 className="min-w-0 truncate font-medium text-foreground">{props.title}</h2>
				{props.status === undefined ? null : <StatusPill status={props.status} />}
			</div>
			{props.actions}
		</header>
	);
}

/** How the thread stands, as a pill: waiting on the person, working, or failed; nothing at rest. */
function StatusPill(props: { readonly status: ThreadStatus }): ReactNode {
	switch (props.status) {
		case "asks":
			return (
				<Pill tone="waiting" icon={<StatusMark status="asks" />}>
					Waiting for you
				</Pill>
			);
		case "working":
			return (
				<Pill tone="running" icon={<StatusMark status="working" />}>
					Working
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
