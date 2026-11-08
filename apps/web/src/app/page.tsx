/**
 * What both of the page's entries do: the root it draws in, its theme following the system until the device's own is
 * read; pairing by the link the page was opened at, which leaves its address at once; and the app, or the pairing page.
 */
import { createRoot, type Root } from "react-dom/client";
import { ClientProvider } from "@octoii-works/octoii-client/react";
import { PAIRING_PATH } from "../core/pairing.ts";
import { type Reach, ReachContext } from "../components/state/reach.ts";
import { PairingPage } from "./access.tsx";
import { App } from "./app.tsx";
import { connect } from "./connect.ts";

/** The root the page draws in. */
export function pageRoot(): Root {
	document.documentElement.classList.toggle("dark", window.matchMedia("(prefers-color-scheme: dark)").matches);
	const container = document.getElementById("root");
	if (container === null) throw new Error("The page has no #root");
	return createRoot(container);
}

/** Pairs this browser by the link the page was opened at, where it was; the words of why that failed. */
export async function pairFromAddress(reach: Reach): Promise<string | undefined> {
	if (window.location.pathname !== PAIRING_PATH) return undefined;
	const link = window.location.href;
	window.history.replaceState(null, "", "/");
	if (!reach.readsLink(link)) return undefined;
	return reach.pair(link).then(
		() => undefined,
		(error: unknown) => (error instanceof Error ? error.message : String(error)),
	);
}

/** Draws the app, on a client of the node `reach` reaches. */
export function showApp(root: Root, reach: Reach): void {
	root.render(
		<ReachContext value={reach}>
			<ClientProvider client={connect(reach)}>
				<App />
			</ClientProvider>
		</ReachContext>,
	);
}

/** Draws the pairing page, with why a pairing failed. */
export function showPairing(root: Root, reach: Reach, failed: string | undefined): void {
	root.render(
		<ReachContext value={reach}>
			<PairingPage failed={failed} />
		</ReachContext>,
	);
}
