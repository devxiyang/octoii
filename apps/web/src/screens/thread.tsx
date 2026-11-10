/**
 * A thread, in the page's frame: its column — its header, with the button that shows its panel; its timeline in a
 * column of the chat's width, each turn's words, its work and its answer, the reply being written, kept at its end as
 * it grows; and docked at its foot, opaque, the messages waiting for the turn's end over the composer — and after it
 * its panel, where it is shown: its overview, its files and changes, its terminals and pages, which a path a message
 * names opens in. What the thread brought is seen as it is shown.
 */
import type { ReactNode } from "react";
import type { Conversation, Listed } from "@octoii-works/octoii-client";
import { useClient, useConversation, useThreads } from "@octoii-works/octoii-client/react";
import type { Device } from "../core/device.ts";
import { projectOf, statusOf, titleOf } from "../core/threads.ts";
import { contentOf } from "../core/attachments.ts";
import { firstSaid, rowsOf, withLimited } from "../core/timeline.ts";
import { Composer } from "../components/composer/composer.tsx";
import { Queued } from "../components/composer/queued.tsx";
import { Pane, PanelFrame, ShowPanel } from "../components/frame/frame.tsx";
import { ChatHeader } from "../components/thread/header.tsx";
import { Details } from "../components/thread/details.tsx";
import { Timeline } from "../components/thread/timeline.tsx";
import { RightPanel } from "../components/panel/right-panel.tsx";
import { MessageThreadContext } from "../components/thread/message-thread.ts";
import { failed } from "../components/state/notices.ts";
import { useSeen } from "../components/effects/seen.ts";

/** What a thread's page is given: its thread, and the device's settings. */
export type ThreadScreenProps = {
	readonly thread: string;
	readonly device: Device;
};

/** A thread's page. */
export function ThreadScreen(props: ThreadScreenProps): ReactNode {
	const { thread } = props;
	const client = useClient();
	const conversation = useConversation(thread);
	const row = useThreads()?.find((each) => each.id === thread);
	useSeen(thread);
	const rows = withLimited(rowsOf(conversation), row?.standing);
	const project = row === undefined ? undefined : projectOf(row);
	const workspace = row?.manifest.workspace;
	const said = firstSaid(rows);
	// Where the thread's turns stand, which its repository and its changes are read again at.
	const revision = conversation.status ?? "";
	return (
		<>
			<Pane>
				<ChatHeader
					title={row?.manifest.title ?? (said === undefined ? "New thread" : titleOf(said))}
					status={row === undefined ? undefined : statusOf(row)}
					{...(project === undefined ? {} : { project })}
					actions={<ShowPanel className="-mr-1" />}
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
					/>
				</MessageThreadContext>
				<Dock thread={thread} row={row} conversation={conversation} device={props.device} />
			</Pane>
			<PanelFrame>
				<RightPanel
					thread={thread}
					overview={<Details thread={thread} row={row} turns={conversation.turns} compactions={conversation.compactions} revision={revision} />}
					folder={workspace}
					terminals={conversation.terminals}
					pages={conversation.pages}
					revision={revision}
				/>
			</PanelFrame>
		</>
	);
}

/**
 * What docks at the column's foot, opaque, the turns fading out behind its upper edge: the messages waiting in the
 * thread's inbox over the composer, in the chat's column.
 */
function Dock(props: { readonly thread: string; readonly row: Listed | undefined; readonly conversation: Conversation; readonly device: Device }): ReactNode {
	const { thread, row, conversation } = props;
	const client = useClient();
	const working = conversation.status === "running" || conversation.inbox.length > 0;
	return (
		<div className="relative shrink-0 bg-background pb-[max(--spacing(4),env(safe-area-inset-bottom))]">
			<div aria-hidden className="pointer-events-none absolute inset-x-0 bottom-full h-6 bg-linear-to-t from-background to-transparent" />
			{/* The list's bar is given its room here too, so this column stands where the list's does. */}
			<div className="overflow-hidden scrollbar-even">
				<div className="chat-column">
					{/* What waits steers a turn that works, docked till its next step; sent to a thread at rest, it begins the next turn, shown in the timeline as it does. */}
					<Queued thread={thread} inbox={conversation.status === "running" ? conversation.inbox : []} />
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
			</div>
		</div>
	);
}
