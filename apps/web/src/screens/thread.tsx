/**
 * A thread: its header, with the buttons of its details; its timeline in a column of the chat's width — each turn's
 * words, its work and its answer, the reply being written — kept at its end as it grows, and at its foot the input area
 * — the messages waiting for the turn's end and the composer — with what waits on the person laid over the whole of
 * it, topmost, while it waits; and its details at the chat's top right, where the chat has room beside its column, the
 * column centred in the room the card leaves. Beside the chat, the right panel, where it is shown, which a path a
 * message names opens in; filling the chat's place where the person has it so, the chat kept as it was beneath it.
 * What the thread brought is seen as it is shown.
 */
import type { CSSProperties, ReactNode } from "react";
import type { Conversation, Listed } from "@octoii-works/octoii-client";
import { useClient, useConversation, useThreads } from "@octoii-works/octoii-client/react";
import type { Device } from "../core/device.ts";
import { projectOf, statusOf, titleOf } from "../core/threads.ts";
import { contentOf } from "../core/attachments.ts";
import { firstSaid, rowsOf } from "../core/timeline.ts";
import { Composer } from "../components/composer/composer.tsx";
import { Queued } from "../components/composer/queued.tsx";
import { ChatHeader } from "../components/thread/header.tsx";
import { DetailsButtons, type DetailsProps, InlineDetails } from "../components/thread/details.tsx";
import { Timeline } from "../components/thread/timeline.tsx";
import { RightPanel } from "../components/panel/right-panel.tsx";
import { MessageThreadContext } from "../components/thread/message-thread.ts";
import { placePanel, usePanelPlace } from "../components/state/panel.ts";
import { useDetailsShown } from "../components/state/details.ts";
import { cn } from "../components/ui/cn.ts";
import { failed } from "../components/state/notices.ts";
import { useSeen } from "../components/effects/seen.ts";

/** What a thread's page is given: its thread, the device's settings, and the sidebar's state. */
export type ThreadScreenProps = {
	readonly thread: string;
	readonly device: Device;
	readonly sidebarHidden: boolean;
	readonly onShowSidebar: () => void;
};

/** A thread's page. */
export function ThreadScreen(props: ThreadScreenProps): ReactNode {
	const { thread } = props;
	const client = useClient();
	const conversation = useConversation(thread);
	const row = useThreads()?.find((each) => each.id === thread);
	useSeen(thread);
	const rows = rowsOf(conversation);
	const project = row === undefined ? undefined : projectOf(row);
	const panelPlace = usePanelPlace();
	const detailsShown = useDetailsShown();
	const workspace = row?.manifest.workspace;
	const said = firstSaid(rows);
	// Where the thread's turns stand, which its repository and its changes are read again at.
	const revision = conversation.status ?? "";
	const details: DetailsProps = { thread, row, turns: conversation.turns, compactions: conversation.compactions, revision };
	return (
		<div className="flex min-h-0 min-w-0 flex-1">
			<div
				style={detailsShown ? DETAILS_ROOM : undefined}
				className={cn("@container/chat relative flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden bg-background", panelPlace === "full" && "hidden")}
			>
				<ChatHeader
					title={row?.manifest.title ?? (said === undefined ? "New thread" : titleOf(said))}
					status={row === undefined ? undefined : statusOf(row)}
					{...(project === undefined ? {} : { project })}
					sidebarHidden={props.sidebarHidden}
					onShowSidebar={props.onShowSidebar}
					actions={<DetailsButtons {...details} />}
					{...(panelPlace === "hidden" ? { onShowPanel: () => placePanel("beside") } : {})}
				/>
				<MessageThreadContext value={{ thread, workspace, pages: conversation.pages }}>
					<Timeline
						thread={thread}
						parent={row?.manifest.parent?.thread}
						rows={rows}
						read={conversation.read}
						complete={conversation.complete}
						waiting={conversation.asks.length}
						onEarlier={() => void client.readOlder(thread).catch((error: unknown) => failed("Earlier messages could not be read", error))}
						foot={<InputArea thread={thread} row={row} conversation={conversation} device={props.device} />}
					/>
				</MessageThreadContext>
				<InlineDetails {...details} />
			</div>
			{panelPlace === "hidden" ? null : (
				<RightPanel thread={thread} folder={workspace} terminals={conversation.terminals} pages={conversation.pages} revision={revision} />
			)}
		</div>
	);
}

declare module "react" {
	interface CSSProperties {
		/** The room the details card takes beside the chat's column while it is shown. */
		"--details-room"?: string;
	}
}

/** The room the details card takes beside the chat's column while it is shown, which the column is centred beside. */
const DETAILS_ROOM: CSSProperties = { "--details-room": "var(--details-inline-room)" };

/**
 * The input area: the messages waiting in the thread's inbox over the composer — free while something waits on the
 * person, whose cards stand in the timeline where they are asked.
 */
function InputArea(props: {
	readonly thread: string;
	readonly row: Listed | undefined;
	readonly conversation: Conversation;
	readonly device: Device;
}): ReactNode {
	const { thread, row, conversation } = props;
	const client = useClient();
	const working = conversation.status === "running" || conversation.inbox.length > 0;
	return (
		<div className="flex flex-col justify-end">
			<Queued thread={thread} inbox={conversation.inbox} />
			<Composer
				model={row?.manifest.model}
				onModel={(model) => void client.configure(thread, { model }).catch((error: unknown) => failed("The model could not be changed", error))}
				mode={row?.manifest.mode}
				onMode={(mode) => void client.configure(thread, { mode }).catch((error: unknown) => failed("The mode could not be changed", error))}
				effort={row?.manifest.effort}
				onEffort={(effort) => void client.configure(thread, { effort }).catch((error: unknown) => failed("The effort could not be changed", error))}
				working={working}
				sendShortcut={props.device.send_shortcut}
				{...(working ? { placeholder: "Steer the work: your message joins at its next step" } : {})}
				draft={{ thread }}
				folder={row?.manifest.workspace}
				onSend={async ({ text, attachments }) => {
					await client.deliver(thread, { message: { role: "user", content: contentOf(text, attachments) } });
				}}
				onStop={() => void client.stop(thread).catch((error: unknown) => failed("The thread could not be stopped", error))}
			/>
		</div>
	);
}
