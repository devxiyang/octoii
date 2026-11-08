/**
 * The composer: a card that grows with the person's words; below, the model's chip, which opens the models over it, the
 * effort's, where the model reasons, the mode's, which opens the modes' menu, and the send button, which stops the turn
 * while it works and the box is empty; over the box, the files the message gives, pasted, dropped or picked. Enter sends, or Cmd/Ctrl+Enter where the device says so; a message sent while
 * the turn works waits in the thread's inbox till the turn's next step takes it in, which it steers. Nothing is sent
 * before a model is chosen: a thread's turns ask it. `@` mentions a file of the thread's folder, from a menu of those
 * its path holds.
 */
import { type ReactNode, useId, useRef, useState, useTransition } from "react";
import type { Effort, FoundPath, Mode } from "@octoii-works/octoii-client";
import { ArrowUp, Square } from "lucide-react";
import type { Device } from "../../core/device.ts";
import type { DraftPlace } from "../../core/drafts.ts";
import { withMention } from "../../core/mentions.ts";
import { type Placement, usePlacedCaret } from "../effects/caret.ts";
import { useDraft } from "../state/draft.ts";
import { MentionMenu, optionId } from "./mention-menu.tsx";
import { useMentions } from "./mentions.ts";
import { ModeControl } from "./mode-picker.tsx";
import type { Attachment } from "../../core/attachments.ts";
import { modelOf } from "../../core/models.ts";
import { AttachButton, Attachments } from "./attachments.tsx";
import { filesOf, useAttaching } from "./attaching.ts";
import { useDirectory } from "./directory.ts";
import { EffortControl } from "./effort-picker.tsx";
import { ModelControl } from "./model-picker.tsx";
import { failed } from "../state/notices.ts";

/**
 * What the composer is given: the model and the mode, whether a turn works, whose draft it edits, the folder whose files
 * it mentions, and what sending and stopping do.
 */
export type ComposerProps = {
	readonly model: string | undefined;
	readonly onModel: (model: string) => void;
	/** The mode the thread's calls follow; none while it is not known yet. */
	readonly mode: Mode | undefined;
	readonly onMode: (mode: Mode) => void;
	/** How hard the model reasons; none, the model's own. */
	readonly effort: Effort | undefined;
	readonly onEffort: (effort: Effort) => void;
	readonly working: boolean;
	readonly sendShortcut: Device["send_shortcut"];
	readonly placeholder?: string;
	/** Whose draft the box edits: its words are kept there while the person goes between places. */
	readonly draft: DraftPlace;
	/** The folder whose files `@` mentions; none where the thread works in none. */
	readonly folder: string | undefined;
	/** Sends the words and the files; resolves once the node took them, so the box empties then. */
	readonly onSend: (message: Outgoing) => Promise<void>;
	readonly onStop: () => void;
};

/** A message as the composer sends it: its words, and the files it gives its model. */
export type Outgoing = { readonly text: string; readonly attachments: readonly Attachment[] };

/** The words a box says it takes, and what it says where it mentions files. */
const PLACEHOLDER = "Ask anything";
const PLACEHOLDER_MENTIONING = "Ask anything. @ files";

/** The composer. */
export function Composer(props: ComposerProps): ReactNode {
	const draft = useDraft(props.draft);
	const [sending, startSending] = useTransition();
	const [choosingModel, setChoosingModel] = useState(false);
	const menu = useId();
	const box = useRef<HTMLTextAreaElement>(null);
	const [caret, setCaret] = useState(0);
	const [placement, setPlacement] = useState<Placement | undefined>(undefined);
	usePlacedCaret(box, placement);
	const mentions = useMentions(props.folder, draft.text, caret);
	const mention = (found: FoundPath): void => {
		if (mentions.mention === undefined) return;
		const next = withMention(draft.text, mentions.mention, caret, found);
		draft.setText(next.text);
		setCaret(next.caret);
		setPlacement({ caret: next.caret });
	};
	const attaching = useAttaching(draft);
	const model = modelOf(useDirectory(), props.model);
	const empty = draft.text.trim() === "" && draft.attachments.length === 0;
	const unready = empty || props.model === undefined || attaching.sending.length > 0;
	const send = (): void => {
		if (unready || sending) return;
		const message = { text: draft.text.trim(), attachments: draft.attachments };
		startSending(async () => {
			try {
				await props.onSend(message);
				draft.clear();
			} catch (error) {
				// The draft stays, to be sent again.
				failed("The message could not be sent", error);
			}
		});
	};
	const keyDown = (event: React.KeyboardEvent<HTMLTextAreaElement>): void => {
		if (event.nativeEvent.isComposing) return;
		const taken = mentions.key(event.key);
		if (taken.handled) {
			event.preventDefault();
			if (taken.chosen !== undefined) mention(taken.chosen);
			return;
		}
		if (event.key !== "Enter" || event.shiftKey || event.altKey) return;
		// Enter sends unless the device sends with Cmd/Ctrl+Enter, where Enter alone makes a new line.
		if (props.sendShortcut === "mod-enter" && !(event.metaKey || event.ctrlKey)) return;
		event.preventDefault();
		send();
	};
	return (
		<div
			className="relative rounded-[20px] border border-black/[0.08] bg-card shadow-composer dark:border-white/[0.08]"
			onDragOver={(event) => {
				if (event.dataTransfer.types.includes("Files")) event.preventDefault();
			}}
			onDrop={(event) => {
				const files = filesOf(event.dataTransfer);
				if (files.length === 0) return;
				event.preventDefault();
				attaching.attach(files);
			}}
		>
			{mentions.mention === undefined ? null : <MentionMenu id={menu} mentions={mentions} onChoose={mention} />}
			<Attachments attachments={draft.attachments} attaching={attaching} seesImages={model?.architecture?.input_modalities?.includes("image")} />
			<textarea
				onPaste={(event) => {
					const files = filesOf(event.clipboardData);
					if (files.length === 0) return;
					event.preventDefault();
					attaching.attach(files);
				}}
				ref={box}
				value={draft.text}
				onChange={(event) => {
					draft.setText(event.target.value);
					setCaret(event.target.selectionStart);
				}}
				onSelect={(event) => setCaret(event.currentTarget.selectionStart)}
				onKeyDown={keyDown}
				aria-label="Message"
				aria-autocomplete={props.folder === undefined ? undefined : "list"}
				aria-controls={mentions.mention === undefined ? undefined : menu}
				aria-activedescendant={
					mentions.mention === undefined || mentions.found === undefined || mentions.found.length === 0 ? undefined : optionId(menu, mentions.highlighted)
				}
				rows={2}
				placeholder={
					props.model === undefined ? "Choose a model to begin" : (props.placeholder ?? (props.folder === undefined ? PLACEHOLDER : PLACEHOLDER_MENTIONING))
				}
				className="block field-sizing-content max-h-[40vh] min-h-16 w-full resize-none bg-transparent px-4 pt-4 pb-1 text-sm leading-relaxed outline-none placeholder:text-muted-foreground/70"
			/>
			<div className="@container flex items-center gap-0.5 px-3 pb-3">
				{/* Where the box is narrow its controls give up their words, the least needed first, and the model's name is cut, rather than scroll. */}
				<div className="flex min-w-0 flex-1 items-center gap-0.5 overflow-hidden">
					<AttachButton onFiles={attaching.attach} />
					<ModelControl model={props.model} onChoose={props.onModel} open={choosingModel} onOpenChange={setChoosingModel} returnFocus={box} />
					<EffortControl model={props.model} effort={props.effort} onChoose={props.onEffort} />
					{props.mode === undefined ? null : <ModeControl mode={props.mode} onChoose={props.onMode} />}
				</div>
				<SendButton working={props.working} empty={empty} unready={unready || sending} onSend={send} onStop={props.onStop} />
			</div>
		</div>
	);
}

/** Send, or steer the turn while it works; stop where it works and the box is empty; nothing while nothing can be sent. */
function SendButton(props: {
	readonly working: boolean;
	readonly empty: boolean;
	readonly unready: boolean;
	readonly onSend: () => void;
	readonly onStop: () => void;
}): ReactNode {
	if (props.working && props.empty) {
		return (
			<button
				type="button"
				aria-label="Stop"
				onClick={props.onStop}
				className="ml-1 flex size-control items-center justify-center rounded-full bg-foreground text-background hover:bg-foreground/85"
			>
				<Square className="size-3 fill-current" />
			</button>
		);
	}
	return (
		<button
			type="button"
			aria-label={props.working ? "Steer" : "Send"}
			disabled={props.unready}
			onClick={props.onSend}
			className="ml-1 flex size-control items-center justify-center rounded-full bg-primary text-primary-foreground hover:bg-primary/90 disabled:bg-foreground/8 disabled:text-muted-foreground"
		>
			<ArrowUp className="size-4" />
		</button>
	);
}
