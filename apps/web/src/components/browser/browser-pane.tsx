/**
 * A page of the thread's browser, filling its tab of the right panel: a bar to go back, forward and load it again, and
 * its address, which takes what is typed — an address, a host, or words searched for — as Enter is pressed, and shows
 * where the page is otherwise; under it the dialog that holds the page, where one does, to answer; below them the page,
 * drawn and driven as its view. A blank page waits with the address bar focused.
 */
import { type FormEvent, type ReactNode, useState } from "react";
import type { PageDialog, PageListed } from "@octoii-works/octoii-client";
import { useClient } from "@octoii-works/octoii-client/react";
import { ArrowLeft, ArrowRight, Globe, LoaderCircle, MessageSquareWarning, RotateCw } from "lucide-react";
import { addressOf, shownAddress } from "../../core/browser.ts";
import { usePageView } from "../effects/page.ts";
import { Button, IconButton } from "../ui/button.tsx";
import { failed } from "../state/notices.ts";

/** The page `page`. */
export function BrowserPane(props: { readonly page: PageListed }): ReactNode {
	const { page } = props;
	const client = useClient();
	const view = usePageView(page.id);
	return (
		<div className="flex min-h-0 flex-1 flex-col">
			<div className="flex h-control-lg shrink-0 items-center gap-0.5 border-b border-border px-2 text-xs">
				<IconButton
					label="Go back"
					disabled={!page.back}
					onClick={() => void client.call("browser.back", { page: page.id }).catch((error: unknown) => failed("The page could not go back", error))}
				>
					<ArrowLeft className="size-3.5" />
				</IconButton>
				<IconButton
					label="Go forward"
					disabled={!page.forward}
					onClick={() => void client.call("browser.forward", { page: page.id }).catch((error: unknown) => failed("The page could not go forward", error))}
				>
					<ArrowRight className="size-3.5" />
				</IconButton>
				<IconButton
					label="Load the page again"
					onClick={() => void client.call("browser.reload", { page: page.id }).catch((error: unknown) => failed("The page could not be loaded again", error))}
				>
					{page.loading ? <LoaderCircle className="size-3.5 animate-spin" /> : <RotateCw className="size-3.5" />}
				</IconButton>
				<AddressBar
					page={page}
					onGo={(url) => void client.call("browser.navigate", { page: page.id, url }).catch((error: unknown) => failed("The page could not go there", error))}
				/>
			</div>
			{page.dialog === undefined ? null : (
				<DialogBar
					key={`${page.dialog.kind}:${page.dialog.message}`}
					dialog={page.dialog}
					onAnswer={(accept, text) =>
						void client
							.call("browser.dialog", { page: page.id, accept, ...(text === undefined ? {} : { text }) })
							.catch((error: unknown) => failed("The page's question could not be answered", error))
					}
				/>
			)}
			<div ref={view} className="relative min-h-0 flex-1 overflow-hidden bg-background" />
		</div>
	);
}

/** The words a dialog's buttons and its question take, by its kind: one asking to leave the page names its own. */
function buttonsOf(dialog: PageDialog): { readonly accept: string; readonly dismiss: string | undefined } {
	switch (dialog.kind) {
		case "alert":
			return { accept: "OK", dismiss: undefined };
		case "beforeunload":
			return { accept: "Leave", dismiss: "Stay" };
		default:
			return { accept: "OK", dismiss: "Cancel" };
	}
}

/**
 * The dialog that holds the page, which holds its scripts till it is answered: its message, the text a prompt offers
 * to change, and its buttons — an alert's OK alone.
 */
function DialogBar(props: { readonly dialog: PageDialog; readonly onAnswer: (accept: boolean, text?: string) => void }): ReactNode {
	const { dialog } = props;
	const [text, setText] = useState(dialog.offered);
	const words = buttonsOf(dialog);
	const prompt = dialog.kind === "prompt";
	return (
		<form
			role="alertdialog"
			aria-label="The page asks"
			onSubmit={(event) => {
				event.preventDefault();
				props.onAnswer(true, prompt ? text : undefined);
			}}
			className="flex shrink-0 flex-col gap-2 border-b border-border bg-accent px-3 py-2 text-ui"
		>
			<div className="flex items-start gap-2">
				<MessageSquareWarning className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
				<span className="min-w-0 flex-1 break-words whitespace-pre-wrap">
					{dialog.kind === "beforeunload" ? "Leave this page? What it holds may be lost." : dialog.message}
				</span>
			</div>
			{prompt ? (
				<input
					aria-label="The page's question"
					value={text}
					autoFocus
					onChange={(event) => setText(event.target.value)}
					className="h-control-sm rounded-md border border-border bg-background px-2 text-ui outline-none focus:border-ring"
				/>
			) : null}
			<div className="flex justify-end gap-2">
				{words.dismiss === undefined ? null : (
					<Button variant="outline" size="xs" onClick={() => props.onAnswer(false)}>
						{words.dismiss}
					</Button>
				)}
				<Button type="submit" size="xs">
					{words.accept}
				</Button>
			</div>
		</form>
	);
}

/**
 * The page's address: what the person types while they edit it, where the page is otherwise; Enter goes where it says,
 * Escape puts back where the page is. Focused as a blank page opens.
 */
function AddressBar(props: { readonly page: PageListed; readonly onGo: (url: string) => void }): ReactNode {
	const shown = shownAddress(props.page.url);
	const [typed, setTyped] = useState<string | undefined>(undefined);
	const go = (event: FormEvent<HTMLFormElement>): void => {
		event.preventDefault();
		const value = typed ?? shown;
		if (value.trim() === "") return;
		props.onGo(addressOf(value));
		setTyped(undefined);
		const field = event.currentTarget.elements.namedItem("address");
		if (field instanceof HTMLInputElement) field.blur();
	};
	return (
		<form onSubmit={go} className="ml-1 flex h-control-sm min-w-0 flex-1 items-center gap-1.5 rounded-md border border-border px-2 focus-within:border-ring">
			<Globe className="size-3.5 shrink-0 text-muted-foreground" />
			<input
				name="address"
				aria-label="Address"
				autoFocus={shown === ""}
				value={typed ?? shown}
				placeholder="Search or type an address"
				spellCheck={false}
				autoCapitalize="off"
				onChange={(event) => setTyped(event.target.value)}
				onFocus={(event) => event.target.select()}
				onBlur={() => setTyped(undefined)}
				onKeyDown={(event) => {
					if (event.key !== "Escape" || event.nativeEvent.isComposing) return;
					setTyped(undefined);
					event.currentTarget.blur();
				}}
				className="min-w-0 flex-1 bg-transparent text-xs outline-none placeholder:text-faint-foreground"
			/>
		</form>
	);
}
