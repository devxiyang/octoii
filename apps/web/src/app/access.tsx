/**
 * What the page says of its access to the node: where the node knows this browser by no session, the pairing page —
 * how to get a link from the computer Octoii runs on, and a field to paste one in — and, while the connection is down,
 * that it connects again.
 */
import { type FormEvent, type ReactNode, useContext, useState, useTransition } from "react";
import type { ConnectionStatus } from "@octoii-works/octoii-client";
import { ReachContext, useReach } from "../components/state/reach.ts";
import { Button } from "../components/ui/button.tsx";
import { Field } from "../components/ui/input.tsx";

/** Whether the node knows the page's browser by no session: the page has no access until it is paired. */
export function unpaired(connection: ConnectionStatus): boolean {
	return connection.status === "waiting" && connection.error?.code === "not-admitted";
}

/** The pairing page: how to pair this browser, a field for a link, and why a pairing failed. */
export function PairingPage(props: { readonly failed?: string | undefined }): ReactNode {
	const reach = useReach();
	const [link, setLink] = useState("");
	const [failed, setFailed] = useState(props.failed);
	const [pairing, startPairing] = useTransition();
	const readable = reach.readsLink(link);
	const pair = (event: FormEvent): void => {
		event.preventDefault();
		if (!readable || pairing) return;
		startPairing(async () => {
			try {
				await reach.pair(link);
				// The page starts anew, its WebSocket opened as the session it now holds.
				window.location.reload();
			} catch (error) {
				setFailed(error instanceof Error ? error.message : String(error));
			}
		});
	};
	return (
		<div className="flex h-dvh flex-col items-center justify-center gap-3 px-6">
			<h1 className="text-title font-semibold">Pair this browser with Octoii</h1>
			<p className="max-w-md text-center text-ui text-muted-foreground">
				On the computer Octoii runs on, run <code className="rounded-sm bg-muted px-1 py-0.5 font-mono text-xs">octoii pair</code> and open the link it prints
				here, or paste it below. A link pairs one browser, once, within five minutes.
			</p>
			<form onSubmit={pair} className="mt-2 flex w-full max-w-md gap-2">
				<Field label="Pairing link" placeholder={reach.linkExample} value={link} onValueChange={setLink} className="flex-1" />
				<Button type="submit" variant="default" disabled={!readable || pairing}>
					Pair
				</Button>
			</form>
			{failed === undefined ? null : <p className="max-w-md text-center text-xs text-error-foreground">{failed}</p>}
			{reach.about === undefined ? null : (
				<a href={reach.about} className="mt-2 text-xs text-muted-foreground hover:text-foreground">
					What is Octoii?
				</a>
			)}
		</div>
	);
}

/** A line over the page while the connection is down; nothing while it is open. */
export function ConnectionLine(props: { readonly connection: ConnectionStatus }): ReactNode {
	const { connection } = props;
	const away = useContext(ReachContext)?.whyAway?.();
	if (connection.status === "open") return null;
	const words =
		connection.status === "stopped"
			? `Octoii stopped connecting: ${connection.error.message}`
			: (away ?? (connection.status === "connecting" ? "Connecting to Octoii…" : "Connecting to Octoii again…"));
	return <div className="shrink-0 bg-muted px-4 py-1 text-center text-xs text-muted-foreground">{words}</div>;
}
