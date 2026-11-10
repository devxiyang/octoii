/**
 * Providers: on the left, each of the node's providers, how it is connected and whether it holds what it needs, each
 * account the person added of one right after it; on the right, the one chosen — how it stands, as it is asked, and
 * what connects it: a key to give and to forget; a sign-in in a browser, finished as the browser comes back to the
 * node, or from the address another device's browser ended at; or a server of the person's, which needs nothing — and
 * another account of it to add, or, for an account added, its name to change and the account to remove. The models
 * listed again on asking; the list read anew after each change, and as the window is focused again, as the person comes
 * back from a sign-in.
 */
import { type FormEvent, type ReactNode, useState, useTransition } from "react";
import { Tabs } from "@base-ui/react/tabs";
import type { Provider } from "@octoii-works/octoii-client";
import { useClient } from "@octoii-works/octoii-client/react";
import { ChevronLeft, Plus, RefreshCw } from "lucide-react";
import { isSignInReturn } from "../../core/sign-in.ts";
import { vendorOfProvider } from "../../core/vendors.ts";
import { useOnFocus } from "../effects/focus.ts";
import { useRead } from "../effects/read.ts";
import { type Finishing, useSignInFinish } from "../effects/sign-in.ts";
import { takeSignInReturn } from "../state/sign-in.ts";
import { Button, IconButton } from "../ui/button.tsx";
import { cn } from "../ui/cn.ts";
import { Field } from "../ui/input.tsx";
import { Dialog, DialogClose, DialogDescription, DialogPopup, DialogTitle } from "../ui/dialog.tsx";
import { Menu, MenuItem, MenuPopup, MenuTrigger } from "../ui/menu.tsx";
import { VendorMark } from "../ui/vendor-mark.tsx";
import { Page, Row, SectionHeading } from "./layout.tsx";
import { failed } from "../state/notices.ts";

/** How a provider stands, in a line, by how it is connected and the credential the node holds for it. */
function standing(provider: Provider): string {
	switch (provider.connects) {
		case "api_key":
			return provider.credential === undefined ? "No key" : "Key kept";
		case "sign_in":
			return provider.credential === undefined ? "Not signed in" : "Signed in";
		case "agent":
			return `Through ${provider.through ?? "its agent"}`;
		case "server":
			return "On this computer";
	}
}

/** The providers in the node's order, each account the person added right after the provider it is another of. */
function ordered(providers: readonly Provider[]): readonly Provider[] {
	const added = providers.filter((each) => each.account !== undefined);
	return providers.filter((each) => each.account === undefined).flatMap((each) => [each, ...added.filter((account) => account.account?.of === each.id)]);
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

/**
 * The providers on the left, the chosen one's details on the right, and the models listed again — where the page is
 * narrow, the list alone till one is chosen, then its details alone, a button going back to the list.
 */
function ProviderList(props: {
	readonly chosen: string | undefined;
	readonly finishing: Finishing | undefined;
	readonly onChoose: (provider: string | undefined) => void;
	readonly onChanged: () => void;
}): ReactNode {
	const client = useClient();
	const [refreshing, startRefreshing] = useTransition();
	const providers = ordered(useRead("providers.list", {})?.providers ?? []);
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
			<section className="@container/providers flex flex-col gap-2">
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
					className="card grid min-h-96 grid-cols-1 overflow-hidden @xl/providers:grid-cols-[14rem_minmax(0,1fr)]"
				>
					<Tabs.List
						aria-label="Providers"
						className={cn("flex flex-col overflow-y-auto border-border @xl/providers:border-r", props.chosen !== undefined && "@max-xl/providers:hidden")}
					>
						{providers.map((each) => (
							<Tabs.Tab
								key={each.id}
								value={each.id}
								data-connected={each.credential === undefined ? undefined : ""}
								data-account={each.account === undefined ? undefined : ""}
								className="group/provider flex items-start gap-2.5 border-b border-border px-4 py-3 text-left outline-none hover:bg-accent focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-inset data-account:pl-8 data-active:bg-accent"
							>
								<span className="mt-0.5">
									<VendorMark vendor={vendorOfProvider(each)} name={each.name} size="md" />
								</span>
								<span className="min-w-0 flex-1">
									<span className="block truncate text-ui font-medium">{each.name}</span>
									<span className="block truncate text-xs text-muted-foreground">{standing(each)}</span>
								</span>
								<span className="mt-1.5 size-2 shrink-0 rounded-full bg-faint-foreground group-data-connected/provider:bg-success" />
							</Tabs.Tab>
						))}
						{/* Each provider but a server of the person's takes accounts: another account of a server would reach the same server. */}
						<AddAccountLine
							hosts={providers.filter((each) => each.account === undefined && each.connects !== "server")}
							onAdded={(id) => {
								props.onChanged();
								props.onChoose(id);
							}}
						/>
					</Tabs.List>
					{providers.map((each) => (
						<Tabs.Panel key={each.id} value={each.id} className={cn("min-w-0 outline-none", props.chosen === undefined && "@max-xl/providers:hidden")}>
							<ProviderDetails provider={each} onChanged={props.onChanged} onBack={() => props.onChoose(undefined)} />
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
	const tone = finishing.state === "failed" ? "border-error text-error-foreground" : "border-border text-muted-foreground";
	return (
		<p className={`rounded-md border px-4 py-3 text-ui ${tone}`}>
			{finishing.state === "finishing" ? "Finishing your sign-in…" : null}
			{finishing.state === "done" ? `Signed in to ${props.providers.find((each) => each.id === finishing.provider)?.name ?? finishing.provider}.` : null}
			{finishing.state === "failed" ? `The sign-in did not finish: ${finishing.message}` : null}
		</p>
	);
}

/** The chosen provider: how it stands, as it is asked, then what connects it, and its accounts; where the page is narrow, a button back to the list. */
function ProviderDetails(props: { readonly provider: Provider; readonly onChanged: () => void; readonly onBack: () => void }): ReactNode {
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
		<div className="[&>*+*]:border-t [&>*+*]:border-border">
			<div className="flex items-center gap-2.5 px-3.5 pt-4 pb-2">
				<IconButton label="All providers" onClick={props.onBack} className="-ms-1.5 @xl/providers:hidden">
					<ChevronLeft className="size-4" />
				</IconButton>
				<VendorMark vendor={vendorOfProvider(provider)} name={provider.name} size="md" />
				<h4 className="flex-1 text-body font-semibold">{provider.name}</h4>
				{provider.account === undefined ? <span className="font-mono text-xs text-muted-foreground">{provider.id}</span> : null}
			</div>
			<Row title="Status" description={stood} />
			{provider.connects === "api_key" ? <KeyDetails provider={provider} onChanged={props.onChanged} onFailed={failed} /> : null}
			{provider.connects === "sign_in" ? <SignInDetails provider={provider} onChanged={props.onChanged} onFailed={failed} /> : null}
			{provider.connects === "agent" ? (
				<Row
					title={`Signed in through ${provider.through ?? "its agent"}`}
					description="Its own sign-in on this computer, and its plan's limits: each account of it a sign-in of its own."
				/>
			) : null}
			{provider.connects === "server" ? (
				<Row title="On this computer" description="A server of yours that needs no key: its models are listed as it answers." />
			) : null}
			{provider.account === undefined ? null : <AccountDetails provider={provider} onChanged={props.onChanged} onFailed={failed} />}
			{refused === undefined ? null : <p className="px-3.5 py-3 text-xs text-error-foreground">{refused}</p>}
		</div>
	);
}

/**
 * The list's last line: another account of one of the node's providers — a second key, sign-in or login of it, its
 * models told apart by its name — the provider chosen from a menu, the account named in a dialog; once added, it is
 * chosen, its details next, where its key, sign-in or login is given.
 */
function AddAccountLine(props: { readonly hosts: readonly Provider[]; readonly onAdded: (id: string) => void }): ReactNode {
	const client = useClient();
	const [of, setOf] = useState<Provider | undefined>(undefined);
	const [open, setOpen] = useState(false);
	const [name, setName] = useState("");
	const [refused, setRefused] = useState<string | undefined>(undefined);
	const [adding, startAdding] = useTransition();
	const choose = (host: Provider): void => {
		setOf(host);
		setName("");
		setRefused(undefined);
		setOpen(true);
	};
	const add = (event: FormEvent): void => {
		event.preventDefault();
		if (of === undefined || name.trim() === "") return;
		startAdding(async () => {
			try {
				const id = await client.addAccount(of.id, name.trim());
				setOpen(false);
				props.onAdded(id);
			} catch (error) {
				setRefused(error instanceof Error ? error.message : String(error));
			}
		});
	};
	return (
		<>
			<Menu>
				<MenuTrigger className="flex items-center gap-2.5 px-4 py-3 text-left text-ui text-muted-foreground outline-none hover:bg-accent hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-inset">
					<Plus className="size-4" />
					Add account
				</MenuTrigger>
				<MenuPopup align="start" className="w-56">
					{props.hosts.map((host) => (
						<MenuItem key={host.id} onClick={() => choose(host)}>
							<VendorMark vendor={vendorOfProvider(host)} name={host.name} />
							{host.name}
						</MenuItem>
					))}
				</MenuPopup>
			</Menu>
			<Dialog open={open} onOpenChange={setOpen}>
				<DialogPopup className="w-[26rem] max-w-[calc(100vw-2rem)] p-5">
					<form onSubmit={add}>
						<DialogTitle className="text-body font-semibold">Another {of?.name} account</DialogTitle>
						<DialogDescription className="mt-2 text-ui text-balance text-muted-foreground">{of === undefined ? null : accountWords(of)}</DialogDescription>
						<Field label="The account's name" placeholder="Name, such as Work" value={name} onValueChange={setName} className="mt-4" />
						{refused === undefined ? null : <p className="mt-2 text-ui text-error-foreground">{refused}</p>}
						<div className="mt-5 flex justify-end gap-2">
							<DialogClose render={<Button variant="outline" size="sm" />}>Cancel</DialogClose>
							<Button type="submit" size="sm" disabled={adding || name.trim() === ""}>
								{adding ? "Adding…" : "Add"}
							</Button>
						</div>
					</form>
				</DialogPopup>
			</Dialog>
		</>
	);
}

/** What another account of `provider` is, and what is given once it is added. */
function accountWords(provider: Provider): string {
	switch (provider.connects) {
		case "agent":
			return `A login of ${provider.through ?? "its agent"} of its own, its models told apart by its name. Once it is added, its details tell how to sign in to it.`;
		case "sign_in":
			return "A sign-in of its own, its models told apart by its name. Once it is added, sign in to it with the other account.";
		case "api_key":
		case "server":
			return "A key of its own, its models told apart by its name. Once it is added, give it its key.";
	}
}

/** An account the person added: its name to change, and the account to remove, its sign-in or key forgotten with it. */
function AccountDetails(props: { readonly provider: Provider; readonly onChanged: () => void; readonly onFailed: (error: unknown) => void }): ReactNode {
	const client = useClient();
	const { provider } = props;
	const [name, setName] = useState(provider.account?.name ?? "");
	const [removing, setRemoving] = useState(false);
	const rename = (event: FormEvent): void => {
		event.preventDefault();
		if (name.trim() === "" || name.trim() === provider.account?.name) return;
		client.renameAccount(provider.id, name.trim()).then(props.onChanged, props.onFailed);
	};
	return (
		<>
			<Row title="Name" description="How its models are told apart from the other accounts'.">
				<form onSubmit={rename} className="flex items-center gap-2">
					<Field label="The account's name" placeholder="Name" value={name} onValueChange={setName} className="w-48" />
					<Button type="submit" size="sm" variant="outline" disabled={name.trim() === "" || name.trim() === provider.account?.name}>
						Rename
					</Button>
				</form>
			</Row>
			<Row
				title="Remove the account"
				description={removing ? "Its sign-in or key is forgotten with it; threads on its models ask for another." : "Its models go with it."}
			>
				{removing ? (
					<div className="flex items-center gap-2">
						<Button size="sm" variant="ghost-muted" onClick={() => setRemoving(false)}>
							Cancel
						</Button>
						<Button size="sm" variant="destructive" onClick={() => void client.removeAccount(provider.id).then(props.onChanged, props.onFailed)}>
							Remove
						</Button>
					</div>
				) : (
					<Button size="sm" variant="outline" onClick={() => setRemoving(true)}>
						Remove…
					</Button>
				)}
			</Row>
		</>
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
