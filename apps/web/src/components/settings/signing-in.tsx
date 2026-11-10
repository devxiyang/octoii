/**
 * Signing in to a provider from settings: a sign-in in a browser, in a new tab opened as the person clicks; or an
 * agent's login, which the node runs in a terminal of its own, shown where the person signs in — typed into there, a
 * link it shows opened in the browser — and closed as they are done, how the provider stands asked again then.
 */
import { type ReactNode, useState } from "react";
import type { Provider } from "@octoii-works/octoii-client";
import { useClient } from "@octoii-works/octoii-client/react";
import { useClosedWithView, useTerminalView } from "../effects/terminal.ts";
import { Button } from "../ui/button.tsx";

/**
 * Begins a sign-in to a provider in a browser, in a new tab opened as the person clicks, so no browser blocks it, sent
 * to the issuer once the node says where — or in this one where the browser opened none.
 */
export function useSignIn(): (provider: string) => Promise<void> {
	const client = useClient();
	return async (provider) => {
		const tab = window.open("", "_blank");
		try {
			const started = await client.signIn(provider);
			if (!("url" in started)) throw new Error("The provider is signed in to through its agent, not in a browser.");
			if (tab === null) window.location.assign(started.url);
			else tab.location.assign(started.url);
		} catch (error) {
			tab?.close();
			throw error;
		}
	};
}

/** What an agent's login is given: the provider, whether it is signed in already, and who is told once the person is done, or of what failed. */
export type AgentLoginProps = {
	readonly provider: Provider;
	readonly signedIn: boolean;
	readonly onDone: () => void;
	readonly onFailed: (error: unknown) => void;
};

/**
 * The login of a provider's agent: the button that begins it, then its terminal, where the person signs in — closed as
 * it goes, on Done or as the person leaves — and the person told as done.
 */
export function AgentLogin(props: AgentLoginProps): ReactNode {
	const client = useClient();
	const [terminal, setTerminal] = useState<string | undefined>(undefined);
	const begin = (): void => {
		client.signIn(props.provider.id).then((started) => {
			if ("terminal" in started) setTerminal(started.terminal);
			else props.onFailed(new Error("The provider is signed in to in a browser, not through its agent."));
		}, props.onFailed);
	};
	const done = (): void => {
		setTerminal(undefined);
		props.onDone();
	};
	if (terminal === undefined) {
		return (
			<Button size="sm" variant={props.signedIn ? "outline" : "default"} onClick={begin}>
				{props.signedIn ? "Sign in again" : "Sign in"}
			</Button>
		);
	}
	return (
		<div className="flex w-full flex-col gap-2">
			<LoginTerminal terminal={terminal} onFailed={props.onFailed} />
			<div className="flex justify-end">
				<Button size="sm" onClick={done}>
					Done
				</Button>
			</div>
		</div>
	);
}

/** The terminal a login runs in, drawn and typed into where the person signs in, on the well's ground; closed as it goes. */
function LoginTerminal(props: { readonly terminal: string; readonly onFailed: (error: unknown) => void }): ReactNode {
	const ref = useTerminalView(props.terminal);
	useClosedWithView(props.terminal, props.onFailed);
	return (
		<div className="well relative h-72 overflow-hidden p-2">
			<div ref={ref} className="absolute inset-2 bg-muted text-foreground" />
		</div>
	);
}
