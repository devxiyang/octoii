/**
 * Adding a provider: a dialog that leads from the catalogue — the node's providers by how each connects, those in use
 * marked — to what connects the one chosen: its API key; a sign-in in a new tab; its agent's login, run in a terminal
 * here; or a server of the person's, checked again as they ask; for one in use already, another account of it, named
 * first. Once the provider is connected, the dialog closes on it.
 */
import { type FormEvent, type ReactNode, useState, useTransition } from "react";
import type { Provider, ProviderStatus } from "@octoii-works/octoii-client";
import { useClient } from "@octoii-works/octoii-client/react";
import { catalogueOf, standingOf, takesAccounts } from "../../core/providers.ts";
import { vendorOfProvider } from "../../core/vendors.ts";
import { Button } from "../ui/button.tsx";
import { DialogDescription, DialogTitle } from "../ui/dialog.tsx";
import { Field } from "../ui/input.tsx";
import { VendorMark } from "../ui/vendor-mark.tsx";
import { CodedWords } from "./coded-words.tsx";
import { AgentLogin, useSignIn } from "./signing-in.tsx";

/** Where adding begins: the catalogue, or another account of a provider in use. */
export type AddStart = { readonly of: Provider | undefined };

/** A step of adding: choosing from the catalogue, naming another account of a provider, or connecting one. */
type Step = { readonly kind: "pick" } | { readonly kind: "name"; readonly of: Provider } | { readonly kind: "connect"; readonly provider: Provider };

/** What adding is given: where it begins, the node's providers and the ids of those in use, and who is told of the one connected, by its id, or that the person left for a sign-in. */
export type AddProviderProps = {
	readonly start: AddStart;
	readonly providers: readonly Provider[];
	readonly used: ReadonlySet<string>;
	readonly onConnected: (provider: string) => void;
	readonly onLeft: () => void;
};

/** The steps of adding, from where it begins. */
export function AddProvider(props: AddProviderProps): ReactNode {
	const [step, setStep] = useState<Step>(props.start.of === undefined ? { kind: "pick" } : { kind: "name", of: props.start.of });
	const back = (): void => setStep({ kind: "pick" });
	switch (step.kind) {
		case "pick":
			return (
				<Catalogue
					providers={props.providers}
					used={props.used}
					onPick={(provider) => {
						if (!props.used.has(provider.id)) setStep({ kind: "connect", provider });
						else if (takesAccounts(provider)) setStep({ kind: "name", of: provider });
						else props.onConnected(provider.id);
					}}
				/>
			);
		case "name":
			return <NameAccount of={step.of} onBack={back} onAdded={(provider) => setStep({ kind: "connect", provider })} />;
		case "connect":
			return <Connect provider={step.provider} onBack={back} onConnected={() => props.onConnected(step.provider.id)} onLeft={props.onLeft} />;
	}
}

/** The catalogue: each group's providers — the group saying how they connect — on cards of their marks and names, those in use saying so. */
function Catalogue(props: {
	readonly providers: readonly Provider[];
	readonly used: ReadonlySet<string>;
	readonly onPick: (provider: Provider) => void;
}): ReactNode {
	return (
		<>
			<DialogTitle className="text-body font-semibold">Add a provider</DialogTitle>
			<DialogDescription className="mt-1 text-ui text-muted-foreground">Where your threads' models come from.</DialogDescription>
			<div className="mt-4 flex flex-col gap-4">
				{catalogueOf(props.providers).map((group) => (
					<section key={group.title} className="flex flex-col gap-2">
						<h4 className="label-caps">{group.title}</h4>
						<div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
							{group.providers.map((provider) => (
								<button
									key={provider.id}
									type="button"
									onClick={() => props.onPick(provider)}
									className="card flex h-12 items-center gap-3 px-3 text-left outline-none hover:bg-accent focus-visible:ring-2 focus-visible:ring-ring"
								>
									<VendorMark vendor={vendorOfProvider(provider)} name={provider.name} size="md" />
									<span className="min-w-0 flex-1 truncate text-ui font-medium">{provider.name}</span>
									{props.used.has(provider.id) ? <span className="shrink-0 text-xs text-muted-foreground">In use</span> : null}
								</button>
							))}
						</div>
					</section>
				))}
			</div>
		</>
	);
}

/** The heading of a step about `provider`: its mark, and what the step does. */
function StepTitle(props: { readonly provider: Provider; readonly children: ReactNode }): ReactNode {
	return (
		<DialogTitle className="flex items-center gap-2.5 text-body font-semibold">
			<VendorMark vendor={vendorOfProvider(props.provider)} name={props.provider.name} size="md" />
			{props.children}
		</DialogTitle>
	);
}

/** The foot of a step: back to the catalogue, and what the step does. */
function StepFoot(props: { readonly onBack: () => void; readonly children: ReactNode }): ReactNode {
	return (
		<div className="mt-5 flex justify-end gap-2">
			<Button size="sm" variant="outline" onClick={props.onBack}>
				Back
			</Button>
			{props.children}
		</div>
	);
}

/** Another account of `of`, named: once added, connected as its own, its models told apart by its name. */
function NameAccount(props: { readonly of: Provider; readonly onBack: () => void; readonly onAdded: (provider: Provider) => void }): ReactNode {
	const client = useClient();
	const [name, setName] = useState("");
	const [refused, setRefused] = useState<string | undefined>(undefined);
	const [adding, startAdding] = useTransition();
	const add = (event: FormEvent): void => {
		event.preventDefault();
		const named = name.trim();
		if (named === "") return;
		startAdding(async () => {
			try {
				const id = await client.addAccount(props.of.id, named);
				// The account as the list will tell of it: connected as its provider is, holding nothing yet.
				const { credential: _credential, ...of } = props.of;
				props.onAdded({ ...of, id, name: `${props.of.name} · ${named}`, account: { of: props.of.id, name: named } });
			} catch (error) {
				setRefused(error instanceof Error ? error.message : String(error));
			}
		});
	};
	return (
		<form onSubmit={add}>
			<StepTitle provider={props.of}>Another {props.of.name} account</StepTitle>
			<DialogDescription className="mt-2 text-ui text-balance text-muted-foreground">
				Connected on its own, its models told apart from the other account's by its name.
			</DialogDescription>
			<Field label="The account's name" placeholder="Name, such as Work" value={name} onValueChange={setName} className="mt-4" autoFocus />
			{refused === undefined ? null : <p className="mt-2 text-ui text-error-foreground">{refused}</p>}
			<StepFoot onBack={props.onBack}>
				<Button type="submit" size="sm" disabled={adding || name.trim() === ""}>
					{adding ? "Adding…" : "Add account"}
				</Button>
			</StepFoot>
		</form>
	);
}

/** What connects `provider`, by how it is connected. */
function Connect(props: {
	readonly provider: Provider;
	readonly onBack: () => void;
	readonly onConnected: () => void;
	readonly onLeft: () => void;
}): ReactNode {
	switch (props.provider.connects) {
		case "api_key":
			return <ConnectKey provider={props.provider} onBack={props.onBack} onConnected={props.onConnected} />;
		case "sign_in":
			return <ConnectSignIn provider={props.provider} onBack={props.onBack} onLeft={props.onLeft} />;
		case "agent":
		case "server":
			return <ConnectHere provider={props.provider} onBack={props.onBack} onConnected={props.onConnected} />;
	}
}

/** A provider reached by a key: the key pasted, kept on this computer. */
function ConnectKey(props: { readonly provider: Provider; readonly onBack: () => void; readonly onConnected: () => void }): ReactNode {
	const client = useClient();
	const [key, setKey] = useState("");
	const [refused, setRefused] = useState<string | undefined>(undefined);
	const [saving, startSaving] = useTransition();
	const save = (event: FormEvent): void => {
		event.preventDefault();
		if (key.trim() === "") return;
		startSaving(async () => {
			try {
				await client.setKey(props.provider.id, key.trim());
				props.onConnected();
			} catch (error) {
				setRefused(error instanceof Error ? error.message : String(error));
			}
		});
	};
	return (
		<form onSubmit={save}>
			<StepTitle provider={props.provider}>Connect {props.provider.name}</StepTitle>
			<DialogDescription className="mt-2 text-ui text-balance text-muted-foreground">
				Paste an API key from your {props.provider.name} account. It is kept on this computer and never shown again.
			</DialogDescription>
			<Field label={`${props.provider.name} API key`} placeholder="API key" value={key} onValueChange={setKey} className="mt-4 font-mono" autoFocus />
			{refused === undefined ? null : <p className="mt-2 text-ui text-error-foreground">{refused}</p>}
			<StepFoot onBack={props.onBack}>
				<Button type="submit" size="sm" disabled={saving || key.trim() === ""}>
					{saving ? "Connecting…" : "Connect"}
				</Button>
			</StepFoot>
		</form>
	);
}

/** A provider signed in to: the sign-in begun in a new tab, which comes back to settings once it is done. */
function ConnectSignIn(props: { readonly provider: Provider; readonly onBack: () => void; readonly onLeft: () => void }): ReactNode {
	const signIn = useSignIn();
	const [refused, setRefused] = useState<string | undefined>(undefined);
	return (
		<>
			<StepTitle provider={props.provider}>Connect {props.provider.name}</StepTitle>
			<DialogDescription className="mt-2 text-ui text-balance text-muted-foreground">
				Sign in with your {props.provider.name} account in a new tab. You come back here once you have.
			</DialogDescription>
			{refused === undefined ? null : <p className="mt-2 text-ui text-error-foreground">{refused}</p>}
			<StepFoot onBack={props.onBack}>
				<Button
					size="sm"
					onClick={() =>
						void signIn(props.provider.id).then(props.onLeft, (error: unknown) => setRefused(error instanceof Error ? error.message : String(error)))
					}
				>
					Sign in
				</Button>
			</StepFoot>
		</>
	);
}

/**
 * A provider reached on this computer — through its agent, signed in to in a terminal here, or a server of the
 * person's — and how it stands, asked again as they say, or as they are done signing in.
 */
function ConnectHere(props: { readonly provider: Provider; readonly onBack: () => void; readonly onConnected: () => void }): ReactNode {
	const client = useClient();
	const [status, setStatus] = useState<ProviderStatus | undefined>(undefined);
	const [refused, setRefused] = useState<string | undefined>(undefined);
	const [checking, startChecking] = useTransition();
	const check = (): void =>
		startChecking(async () => {
			const asked = await client.providerStatus(props.provider.id).catch((error: unknown) => ({
				connected: false,
				problem: error instanceof Error ? error.message : String(error),
			}));
			setStatus(asked);
			if (asked.connected) props.onConnected();
		});
	const through = props.provider.through ?? "its agent";
	return (
		<>
			<StepTitle provider={props.provider}>Connect {props.provider.name}</StepTitle>
			<DialogDescription className="mt-2 text-ui text-balance text-muted-foreground">
				{props.provider.connects === "agent"
					? `Octoii reaches ${props.provider.name} through ${through} on this computer. Sign in to it here; its login is kept on this computer.`
					: `Start ${props.provider.name} on this computer; its models are listed as it answers.`}
			</DialogDescription>
			{props.provider.connects === "agent" ? (
				<div className="mt-4">
					<AgentLogin
						provider={props.provider}
						signedIn={false}
						onDone={check}
						onFailed={(error) => setRefused(error instanceof Error ? error.message : String(error))}
					/>
				</div>
			) : null}
			{status === undefined || status.connected ? null : (
				<p className="mt-3 text-ui text-error-foreground">
					<CodedWords text={standingOf(props.provider, status)} />
				</p>
			)}
			{refused === undefined ? null : <p className="mt-2 text-ui text-error-foreground">{refused}</p>}
			<StepFoot onBack={props.onBack}>
				<Button size="sm" variant={props.provider.connects === "agent" ? "outline" : "default"} disabled={checking} onClick={check}>
					{checking ? "Checking…" : status === undefined ? "Check" : "Check again"}
				</Button>
			</StepFoot>
		</>
	);
}
