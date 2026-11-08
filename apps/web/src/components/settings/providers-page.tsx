/**
 * Providers: on the left, each of the node's providers, how it is connected and whether it holds what it needs; on the
 * right, the one chosen — how it stands, as it is asked, and what connects it: a key to give and to forget; a sign-in in
 * a browser, finished as the browser comes back to the node, or from the address another device's browser ended at;
 * or a server of the person's, which needs nothing. The models listed again on asking; the list read anew after each
 * change, and as the window is focused again, as the person comes back from a sign-in.
 */
import { type FormEvent, type ReactNode, useState, useTransition } from "react";
import { Tabs } from "@base-ui/react/tabs";
import type { Provider } from "@octoii-works/octoii-client";
import { useClient } from "@octoii-works/octoii-client/react";
import { RefreshCw } from "lucide-react";
import { isSignInReturn } from "../../core/sign-in.ts";
import { useOnFocus } from "../effects/focus.ts";
import { useRead } from "../effects/read.ts";
import { type Finishing, useSignInFinish } from "../effects/sign-in.ts";
import { takeSignInReturn } from "../state/sign-in.ts";
import { Button } from "../ui/button.tsx";
import { Field } from "../ui/input.tsx";
import { Monogram } from "../ui/monogram.tsx";
import { Page, Row, SectionHeading } from "./layout.tsx";
import { failed } from "../state/notices.ts";

/** How a provider stands, in a line, by how it is connected and the credential the node holds for it. */
function standing(provider: Provider): string {
	switch (provider.connects) {
		case "api_key":
			return provider.credential === undefined ? "No key" : "Key kept";
		case "sign_in":
			return provider.credential === undefined ? "Not signed in" : "Signed in";
		case "server":
			return "A server of yours";
	}
}

/** The page: the providers, read anew after each change; the sign-in this page was opened to finish, where it was. */
export function ProvidersPage(): ReactNode {
	const [changes, setChanges] = useState(0);
	const [chosen, setChosen] = useState<string | undefined>(undefined);
	const [returned] = useState(takeSignInReturn);
	const finishing = useSignInFinish(returned);
	const changed = (): void => setChanges((count) => count + 1);
	useOnFocus(changed);
	return (
		<ProviderList
			key={`${String(changes)} ${finishing?.state ?? ""}`}
			chosen={chosen ?? (finishing?.state === "done" ? finishing.provider : undefined)}
			finishing={finishing}
			onChoose={setChosen}
			onChanged={changed}
		/>
	);
}

/** The providers on the left, the chosen one's details on the right, and the models listed again. */
function ProviderList(props: {
	readonly chosen: string | undefined;
	readonly finishing: Finishing | undefined;
	readonly onChoose: (provider: string) => void;
	readonly onChanged: () => void;
}): ReactNode {
	const client = useClient();
	const [refreshing, startRefreshing] = useTransition();
	const providers = useRead("providers.list", {})?.providers ?? [];
	const shown = providers.find((each) => each.id === props.chosen) ?? providers[0];
	const refresh = (): void =>
		startRefreshing(async () => {
			try {
				await client.refreshModels();
				props.onChanged();
			} catch (error) {
				failed("The models could not be listed again", error);
			}
		});
	return (
		<Page>
			<section className="flex flex-col gap-2">
				<SectionHeading
					title="Providers"
					action={
						<Button size="xs" variant="ghost-muted" disabled={refreshing} onClick={refresh} className="group/refresh">
							<RefreshCw className="group-disabled/refresh:animate-spin" />
							Refresh models
						</Button>
					}
				/>
				{props.finishing === undefined ? null : <SignInOutcome finishing={props.finishing} providers={providers} />}
				<Tabs.Root
					value={shown?.id ?? null}
					onValueChange={(id: string) => props.onChoose(id)}
					orientation="vertical"
					className="grid min-h-96 grid-cols-[14rem_minmax(0,1fr)] overflow-hidden rounded-xl border border-border/60 bg-card/40 shadow-xs"
				>
					<Tabs.List aria-label="Providers" className="flex flex-col overflow-y-auto border-r border-border/60">
						{providers.map((each) => (
							<Tabs.Tab
								key={each.id}
								value={each.id}
								data-connected={each.credential === undefined ? undefined : ""}
								className="group/provider flex items-start gap-2.5 border-b border-border/40 px-4 py-3 text-left outline-none hover:bg-accent/40 focus-visible:ring-2 focus-visible:ring-ring/70 focus-visible:ring-inset data-active:bg-accent/70"
							>
								<span className="mt-0.5">
									<Monogram name={each.name} size="md" />
								</span>
								<span className="min-w-0 flex-1">
									<span className="block truncate text-sm font-medium">{each.name}</span>
									<span className="block truncate text-xs text-muted-foreground">{standing(each)}</span>
								</span>
								<span className="mt-1.5 size-2 shrink-0 rounded-full bg-muted-foreground/30 group-data-connected/provider:bg-success" />
							</Tabs.Tab>
						))}
					</Tabs.List>
					{providers.map((each) => (
						<Tabs.Panel key={each.id} value={each.id} className="min-w-0 outline-none">
							<ProviderDetails provider={each} onChanged={props.onChanged} />
						</Tabs.Panel>
					))}
				</Tabs.Root>
			</section>
		</Page>
	);
}

/** How the sign-in this page finishes went: under way, done, or failed with the node's words. */
function SignInOutcome(props: { readonly finishing: Finishing; readonly providers: readonly Provider[] }): ReactNode {
	const { finishing } = props;
	const tone = finishing.state === "failed" ? "border-error/40 text-error-foreground" : "border-border/60 text-muted-foreground";
	return (
		<p className={`rounded-xl border px-4 py-3 text-sm ${tone}`}>
			{finishing.state === "finishing" ? "Finishing your sign-in…" : null}
			{finishing.state === "done" ? `Signed in to ${props.providers.find((each) => each.id === finishing.provider)?.name ?? finishing.provider}.` : null}
			{finishing.state === "failed" ? `The sign-in did not finish: ${finishing.message}` : null}
		</p>
	);
}

/** The chosen provider: how it stands, as it is asked, then what connects it. */
function ProviderDetails(props: { readonly provider: Provider; readonly onChanged: () => void }): ReactNode {
	const { provider } = props;
	const status = useRead("providers.status", { provider: provider.id });
	const [refused, setRefused] = useState<string | undefined>(undefined);
	const failed = (error: unknown): void => setRefused(error instanceof Error ? error.message : String(error));
	const stood =
		status === undefined
			? "Asking…"
			: status.connected
				? `Connected${status.account === undefined ? "" : ` as ${status.account}`}`
				: (status.problem ?? "Not connected");
	return (
		<div className="[&>*+*]:border-t [&>*+*]:border-border/40">
			<div className="flex items-center gap-2.5 px-3.5 pt-4 pb-2">
				<Monogram name={provider.name} size="md" />
				<h4 className="flex-1 text-base font-semibold">{provider.name}</h4>
				<span className="font-mono text-xs text-muted-foreground">{provider.id}</span>
			</div>
			<Row title="Status" description={stood} />
			{provider.connects === "api_key" ? <KeyDetails provider={provider} onChanged={props.onChanged} onFailed={failed} /> : null}
			{provider.connects === "sign_in" ? <SignInDetails provider={provider} onChanged={props.onChanged} onFailed={failed} /> : null}
			{provider.connects === "server" ? (
				<Row title="Server" description="Runs on this computer and needs no key: its models are listed as it answers." />
			) : null}
			{refused === undefined ? null : <p className="px-3.5 py-3 text-xs text-error-foreground">{refused}</p>}
		</div>
	);
}

/** What a provider reached by a key holds: the key to give, and the key it holds to forget. */
function KeyDetails(props: { readonly provider: Provider; readonly onChanged: () => void; readonly onFailed: (error: unknown) => void }): ReactNode {
	const client = useClient();
	const { provider } = props;
	const [key, setKey] = useState("");
	const save = (event: FormEvent): void => {
		event.preventDefault();
		if (key.trim() === "") return;
		client.setKey(provider.id, key.trim()).then(props.onChanged, props.onFailed);
		setKey("");
	};
	return (
		<>
			<Row title="API key" description="Kept by the node on this computer; never shown again.">
				<form onSubmit={save} className="flex items-center gap-2">
					<Field label={`${provider.name} key`} placeholder="API key" value={key} onValueChange={setKey} className="w-56" />
					<Button type="submit" size="sm" variant="outline" disabled={key.trim() === ""}>
						Save
					</Button>
				</form>
			</Row>
			{provider.credential === "api_key" ? (
				<Row title="Forget the key" description="The node keeps no key for this provider; one its environment gives is read as before.">
					<Button size="sm" variant="outline" onClick={() => void client.removeKey(provider.id).then(props.onChanged, props.onFailed)}>
						Forget
					</Button>
				</Row>
			) : null}
		</>
	);
}

/**
 * What a provider signed in to holds: a sign-in in a new tab, which comes back to the node; the address another
 * device's browser ended at, pasted, where the browser could not reach the node; and signing out.
 */
function SignInDetails(props: { readonly provider: Provider; readonly onChanged: () => void; readonly onFailed: (error: unknown) => void }): ReactNode {
	const client = useClient();
	const { provider } = props;
	const [pasted, setPasted] = useState("");
	const begin = (): void => {
		// The tab opens as the person clicks, so no browser blocks it; it goes to the issuer once the node says where.
		const tab = window.open("", "_blank");
		client.signIn(provider.id).then(
			(url) => {
				if (tab === null) window.location.assign(url);
				else tab.location.assign(url);
			},
			(error: unknown) => {
				tab?.close();
				props.onFailed(error);
			},
		);
	};
	const finish = (event: FormEvent): void => {
		event.preventDefault();
		if (!isSignInReturn(pasted)) return;
		client.finishSignIn(pasted.trim()).then(() => {
			setPasted("");
			props.onChanged();
		}, props.onFailed);
	};
	return (
		<>
			<Row title="Sign in" description={`Sign in with your ${provider.name} account in a new tab; it comes back here once you have.`}>
				<Button size="sm" variant="default" onClick={begin}>
					{provider.credential === undefined ? "Sign in" : "Sign in again"}
				</Button>
			</Row>
			<Row title="Signed in on another device?" description="Its browser cannot reach this computer: paste the address it ended at.">
				<form onSubmit={finish} className="flex items-center gap-2">
					<Field
						label="The address the browser ended at"
						placeholder="http://127.0.0.1:…/auth/callback?…"
						value={pasted}
						onValueChange={setPasted}
						className="w-56"
					/>
					<Button type="submit" size="sm" variant="outline" disabled={!isSignInReturn(pasted)}>
						Finish
					</Button>
				</form>
			</Row>
			{provider.credential === undefined ? null : (
				<Row title="Sign out" description="The node forgets the sign-in it keeps for this provider.">
					<Button size="sm" variant="outline" onClick={() => void client.removeKey(provider.id).then(props.onChanged, props.onFailed)}>
						Sign out
					</Button>
				</Row>
			)}
		</>
	);
}
