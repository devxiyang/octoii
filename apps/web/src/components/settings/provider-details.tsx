/**
 * A provider in use, as settings show it beside the list: its mark and name; how it stands, as it is asked — who it is
 * connected as, or what is wrong and how to put it right, the command to run copied from it, asked again on asking;
 * what connects it — its key, replaced as another is pasted, or
 * its sign-in, given again here or from another device's browser; an account's name, kept as it is changed; another
 * account of it to add; and what takes it out of use — its key forgotten, its sign-in, or the account itself — asked
 * first.
 */
import { type FormEvent, type ReactNode, useState } from "react";
import type { Provider, ProviderStatus } from "@octoii-works/octoii-client";
import { useClient } from "@octoii-works/octoii-client/react";
import { ChevronLeft } from "lucide-react";
import { standingOf, takesAccounts, troubled } from "../../core/providers.ts";
import { isSignInReturn } from "../../core/sign-in.ts";
import { vendorOfProvider } from "../../core/vendors.ts";
import { Button, IconButton } from "../ui/button.tsx";
import { cn } from "../ui/cn.ts";
import { Collapsible, CollapsiblePanel, CollapsibleTrigger, FoldChevron } from "../ui/collapsible.tsx";
import { Field } from "../ui/input.tsx";
import { VendorMark } from "../ui/vendor-mark.tsx";
import { useSignIn } from "./add-provider.tsx";
import { CodedWords } from "./coded-words.tsx";
import { Row } from "./layout.tsx";

/** What the details are given: the provider and how it stands, and who is told of a change, of another account to add, and of going back to the list. */
export type ProviderDetailsProps = {
	readonly provider: Provider;
	readonly status: ProviderStatus | undefined;
	readonly onChanged: () => void;
	readonly onAddAccount: (of: Provider) => void;
	readonly onBack: () => void;
};

/** What a change to a provider is told: that it was made, or the words it was refused with. */
type Changes = { readonly onChanged: () => void; readonly onFailed: (error: unknown) => void };

/** The details. */
export function ProviderDetails(props: ProviderDetailsProps): ReactNode {
	const { provider } = props;
	const [refused, setRefused] = useState<string | undefined>(undefined);
	const changes: Changes = { onChanged: props.onChanged, onFailed: (error) => setRefused(error instanceof Error ? error.message : String(error)) };
	return (
		<div className="[&>*+*]:border-t [&>*+*]:border-border">
			<div className="flex items-center gap-2.5 px-3.5 pt-3.5 pb-3">
				<IconButton label="All providers" onClick={props.onBack} className="-ms-1.5 @xl/providers:hidden">
					<ChevronLeft className="size-4" />
				</IconButton>
				<VendorMark vendor={vendorOfProvider(provider)} name={provider.name} size="md" />
				<h4 className="min-w-0 flex-1 truncate text-body font-semibold">{provider.name}</h4>
			</div>
			<Row
				title="Status"
				description={
					<span className={cn(troubled(props.status) && "text-error-foreground")}>
						<CodedWords text={standingOf(provider, props.status)} />
					</span>
				}
			>
				{troubled(props.status) ? (
					<Button size="sm" variant="outline" onClick={props.onChanged}>
						Check again
					</Button>
				) : undefined}
			</Row>
			{provider.connects === "api_key" ? <KeyRow provider={provider} {...changes} /> : null}
			{provider.connects === "sign_in" ? <SignInRows provider={provider} {...changes} /> : null}
			{provider.account === undefined ? null : <NameRow provider={provider} {...changes} />}
			{takesAccounts(provider) ? (
				<Row title="Other accounts" description={`Another ${provider.name} account, connected on its own, its models told apart by its name.`}>
					<Button size="sm" variant="outline" onClick={() => props.onAddAccount(provider)}>
						Add account
					</Button>
				</Row>
			) : null}
			<RemoveRow provider={provider} {...changes} />
			{refused === undefined ? null : <p className="px-3.5 py-3 text-xs text-error-foreground">{refused}</p>}
		</div>
	);
}

/** A provider reached by a key: the key it holds, replaced as another is pasted. */
function KeyRow(props: { readonly provider: Provider } & Changes): ReactNode {
	const client = useClient();
	const { provider } = props;
	const [key, setKey] = useState("");
	const held = provider.credential !== undefined;
	const save = (event: FormEvent): void => {
		event.preventDefault();
		if (key.trim() === "") return;
		client.setKey(provider.id, key.trim()).then(props.onChanged, props.onFailed);
		setKey("");
	};
	return (
		<Row
			title="API key"
			description={
				held ? "Kept on this computer and never shown again. Paste another to replace it." : "Paste a key from your account. It is kept on this computer."
			}
		>
			<form onSubmit={save} className="flex items-center gap-2">
				<Field
					label={`${provider.name} API key`}
					placeholder={held ? "New API key" : "API key"}
					value={key}
					onValueChange={setKey}
					className="w-56 font-mono"
				/>
				<Button type="submit" size="sm" variant="outline" disabled={key.trim() === ""}>
					{held ? "Replace" : "Save"}
				</Button>
			</form>
		</Row>
	);
}

/**
 * A provider signed in to: the sign-in given again in a new tab, which comes back to settings; and, folded, the address
 * another device's browser ended at, pasted, where that browser could not come back to this computer.
 */
function SignInRows(props: { readonly provider: Provider } & Changes): ReactNode {
	const client = useClient();
	const signIn = useSignIn();
	const { provider } = props;
	const [pasted, setPasted] = useState("");
	const signed = provider.credential !== undefined;
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
			<Row
				title="Account"
				description={
					signed
						? `Signed in with your ${provider.name} account. Sign in again to use another.`
						: `Sign in with your ${provider.name} account in a new tab; you come back here once you have.`
				}
			>
				<Button size="sm" variant={signed ? "outline" : "default"} onClick={() => void signIn(provider.id).catch(props.onFailed)}>
					{signed ? "Sign in again" : "Sign in"}
				</Button>
			</Row>
			<Collapsible>
				<CollapsibleTrigger className="group/fold flex h-control w-full items-center gap-1 px-3.5 text-left text-xs text-muted-foreground outline-none hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-inset">
					Signing in on another device?
					<FoldChevron className="quiet-chevron" />
				</CollapsibleTrigger>
				<CollapsiblePanel>
					<Row title="Paste the address it ended at" description="A phone's or another computer's browser cannot come back here by itself.">
						<form onSubmit={finish} className="flex items-center gap-2">
							<Field
								label="The address the browser ended at"
								placeholder="http://localhost:…/auth/callback?…"
								value={pasted}
								onValueChange={setPasted}
								className="w-56 font-mono"
							/>
							<Button type="submit" size="sm" variant="outline" disabled={!isSignInReturn(pasted)}>
								Finish
							</Button>
						</form>
					</Row>
				</CollapsiblePanel>
			</Collapsible>
		</>
	);
}

/** An account the person added: its name, kept as the person leaves the field or presses Enter. */
function NameRow(props: { readonly provider: Provider } & Changes): ReactNode {
	const client = useClient();
	const { provider } = props;
	const [name, setName] = useState(provider.account?.name ?? "");
	const keep = (): void => {
		const named = name.trim();
		if (named === "" || named === provider.account?.name) return;
		client.renameAccount(provider.id, named).then(props.onChanged, props.onFailed);
	};
	return (
		<Row title="Name" description="How its models are told apart from the other accounts'.">
			<form
				onSubmit={(event) => {
					event.preventDefault();
					keep();
				}}
			>
				<Field label="The account's name" placeholder="Name" value={name} onValueChange={setName} onBlur={keep} className="w-56" />
			</form>
		</Row>
	);
}

/** What takes a provider out of use, where anything does: what it is, what it does, and what follows once asked. */
type Removal = { readonly title: string; readonly description: string; readonly follows: string; readonly remove: () => Promise<void> };

/** What takes `provider` out of use: an account removed; a kept key forgotten; a sign-in signed out of. None for its agent's own sign-in, nor a server, which settings do not hold. */
function useRemoval(provider: Provider): Removal | undefined {
	const client = useClient();
	if (provider.account !== undefined) {
		return {
			title: "Remove account",
			description: "Its models go with it.",
			follows: "Its key or sign-in is forgotten with it; threads on its models ask for another.",
			remove: () => client.removeAccount(provider.id),
		};
	}
	if (provider.credential === undefined) return undefined;
	if (provider.connects === "sign_in") {
		return {
			title: "Sign out",
			description: "Its models leave the list.",
			follows: "The sign-in kept on this computer is forgotten.",
			remove: () => client.removeKey(provider.id),
		};
	}
	if (provider.connects === "api_key") {
		return {
			title: "Remove key",
			description: "Its models leave the list.",
			follows: "The key kept on this computer is forgotten; one this computer's environment gives is still read.",
			remove: () => client.removeKey(provider.id),
		};
	}
	return undefined;
}

/** The row that takes the provider out of use, asked first: what follows said as the person asks. */
function RemoveRow(props: { readonly provider: Provider } & Changes): ReactNode {
	const removal = useRemoval(props.provider);
	const [asking, setAsking] = useState(false);
	if (removal === undefined) return null;
	return (
		<Row title={removal.title} description={asking ? removal.follows : removal.description}>
			{asking ? (
				<>
					<Button size="sm" variant="ghost-muted" onClick={() => setAsking(false)}>
						Cancel
					</Button>
					<Button size="sm" variant="destructive" onClick={() => void removal.remove().then(props.onChanged, props.onFailed)}>
						{removal.title}
					</Button>
				</>
			) : (
				<Button size="sm" variant="outline" onClick={() => setAsking(true)}>
					{removal.title}…
				</Button>
			)}
		</Row>
	);
}
