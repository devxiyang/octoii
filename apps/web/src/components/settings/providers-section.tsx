/**
 * The providers in use, as settings show them: on the left, each of them — each account the person added right after
 * the provider it is another of — and how it stands in a line, what is wrong marked; the last line adds another; on the
 * right, the one chosen. Where none is in use, the section offers to add one. The models are listed again on asking.
 */
import { type ReactNode, useState, useTransition } from "react";
import { Tabs } from "@base-ui/react/tabs";
import type { Provider, ProviderStatus } from "@octoii-works/octoii-client";
import { useClient } from "@octoii-works/octoii-client/react";
import { Plus, RefreshCw } from "lucide-react";
import { inUseOf, standingShortOf, troubled } from "../../core/providers.ts";
import { vendorOfProvider } from "../../core/vendors.ts";
import type { Finishing } from "../effects/sign-in.ts";
import { failed } from "../state/notices.ts";
import { Button } from "../ui/button.tsx";
import { cn } from "../ui/cn.ts";
import { Dialog, DialogPopup } from "../ui/dialog.tsx";
import { VendorMark } from "../ui/vendor-mark.tsx";
import { AddProvider, type AddStart } from "./add-provider.tsx";
import { ProviderDetails } from "./provider-details.tsx";
import { SectionHeading } from "./layout.tsx";

/** What the section is given: the node's providers and how those whose standing matters stand, the sign-in settings were opened to finish, and who is told of a change. */
export type ProvidersSectionProps = {
	readonly providers: readonly Provider[] | undefined;
	readonly statuses: ReadonlyMap<string, ProviderStatus> | undefined;
	readonly finishing: Finishing | undefined;
	readonly onChanged: () => void;
};

/** The section: the providers in use and the one chosen, the models listed again on asking, and what adds a provider. */
export function ProvidersSection(props: ProvidersSectionProps): ReactNode {
	const client = useClient();
	const { providers, statuses, finishing } = props;
	const [chosen, setChosen] = useState<string | undefined>(undefined);
	const [adding, setAdding] = useState<AddStart | undefined>(undefined);
	const [refreshing, startRefreshing] = useTransition();
	const used = providers === undefined || statuses === undefined ? undefined : inUseOf(providers, statuses);
	const changed = props.onChanged;
	const refresh = (): void =>
		startRefreshing(async () => {
			try {
				await client.refreshModels();
				changed();
			} catch (error) {
				failed("The models could not be listed again", error);
			}
		});
	return (
		<section id="setting-providers" className="@container/providers flex scroll-mt-4 flex-col gap-2">
			<SectionHeading
				title="Providers"
				action={
					<Button size="xs" variant="ghost-muted" disabled={refreshing} onClick={refresh} className="group/refresh -me-2">
						<RefreshCw className="group-disabled/refresh:animate-spin" />
						Refresh models
					</Button>
				}
			/>
			{finishing === undefined ? null : <SignInOutcome finishing={finishing} providers={providers ?? []} />}
			{used === undefined ? (
				<p className="card px-4 py-10 text-center text-ui text-muted-foreground">Checking the providers…</p>
			) : used.length === 0 ? (
				<NoneInUse onAdd={() => setAdding({ of: undefined })} />
			) : (
				<InUse
					used={used}
					statuses={statuses}
					chosen={chosen ?? (finishing?.state === "done" ? finishing.provider : undefined)}
					onChoose={setChosen}
					onChanged={changed}
					onAdd={(start) => setAdding(start)}
				/>
			)}
			<Dialog open={adding !== undefined} onOpenChange={(open) => (open ? undefined : setAdding(undefined))}>
				<DialogPopup className="w-[40rem] max-w-full p-5">
					{adding === undefined || providers === undefined ? null : (
						<AddProvider
							start={adding}
							providers={providers}
							used={new Set((used ?? []).map((each) => each.id))}
							onConnected={(provider) => {
								setAdding(undefined);
								setChosen(provider);
								changed();
							}}
							onLeft={() => setAdding(undefined)}
						/>
					)}
				</DialogPopup>
			</Dialog>
		</section>
	);
}

/** Where no provider is in use: what a provider is for, and the button that adds one. */
function NoneInUse(props: { readonly onAdd: () => void }): ReactNode {
	return (
		<div className="card flex flex-col items-center gap-3 px-4 py-10 text-center">
			<p className="text-ui text-muted-foreground">Connect a provider to choose models for your threads.</p>
			<Button size="sm" onClick={props.onAdd}>
				<Plus />
				Add a provider
			</Button>
		</div>
	);
}

/**
 * The providers in use on the left, the chosen one's details on the right — where the section is narrow, the list
 * alone till one is chosen, then its details alone, a button going back to the list.
 */
function InUse(props: {
	readonly used: readonly Provider[];
	readonly statuses: ReadonlyMap<string, ProviderStatus> | undefined;
	readonly chosen: string | undefined;
	readonly onChoose: (provider: string | undefined) => void;
	readonly onChanged: () => void;
	readonly onAdd: (start: AddStart) => void;
}): ReactNode {
	const shown = props.used.find((each) => each.id === props.chosen) ?? props.used[0];
	return (
		<Tabs.Root
			value={shown?.id ?? null}
			onValueChange={(id: string) => props.onChoose(id)}
			orientation="vertical"
			className="card grid grid-cols-1 overflow-hidden @xl/providers:grid-cols-[16rem_minmax(0,1fr)]"
		>
			<Tabs.List
				aria-label="Providers"
				className={cn("flex flex-col border-border p-1.5 @xl/providers:border-e", props.chosen !== undefined && "@max-xl/providers:hidden")}
			>
				{props.used.map((each) => (
					<ProviderTab key={each.id} provider={each} status={props.statuses?.get(each.id)} />
				))}
				<button
					type="button"
					onClick={() => props.onAdd({ of: undefined })}
					className="flex h-control items-center gap-2.5 rounded-md px-2.5 text-left text-ui text-muted-foreground outline-none hover:bg-accent hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring"
				>
					<span className="flex size-5 items-center justify-center">
						<Plus className="size-4" />
					</span>
					Add provider
				</button>
			</Tabs.List>
			{props.used.map((each) => (
				<Tabs.Panel key={each.id} value={each.id} className={cn("min-w-0 outline-none", props.chosen === undefined && "@max-xl/providers:hidden")}>
					<ProviderDetails
						provider={each}
						status={props.statuses?.get(each.id)}
						onChanged={props.onChanged}
						onAddAccount={(of) => props.onAdd({ of })}
						onBack={() => props.onChoose(undefined)}
					/>
				</Tabs.Panel>
			))}
		</Tabs.Root>
	);
}

/** A provider in the list: its mark, its name, and how it stands in a line, red with a dot where it does not answer; an account set in under its provider. */
function ProviderTab(props: { readonly provider: Provider; readonly status: ProviderStatus | undefined }): ReactNode {
	const { provider } = props;
	const wrong = troubled(props.status);
	const standing = standingShortOf(provider, props.status);
	return (
		<Tabs.Tab
			value={provider.id}
			data-account={provider.account === undefined ? undefined : ""}
			className="flex items-start gap-2.5 rounded-md px-2.5 py-2 text-left outline-none hover:bg-accent focus-visible:ring-2 focus-visible:ring-ring data-account:ps-7 data-active:bg-selected"
		>
			<VendorMark vendor={vendorOfProvider(provider)} name={provider.name} size="md" />
			<span className="min-w-0 flex-1">
				<span className="block truncate text-ui font-medium">{provider.account?.name ?? provider.name}</span>
				<span className={cn("flex items-center gap-1.5 text-xs", wrong ? "text-error-foreground" : "text-muted-foreground")}>
					{wrong ? <span aria-hidden className="size-1.5 shrink-0 rounded-full bg-error" /> : null}
					<span title={standing} className="truncate">
						{standing}
					</span>
				</span>
			</span>
		</Tabs.Tab>
	);
}

/** How the sign-in settings were opened to finish went: under way, done, or failed with the node's words. */
function SignInOutcome(props: { readonly finishing: Finishing; readonly providers: readonly Provider[] }): ReactNode {
	const { finishing } = props;
	return (
		<p
			className={cn(
				"rounded-md border px-4 py-3 text-ui",
				finishing.state === "failed" ? "border-error text-error-foreground" : "border-border text-muted-foreground",
			)}
		>
			{finishing.state === "finishing" ? "Finishing your sign-in…" : null}
			{finishing.state === "done" ? `Signed in to ${props.providers.find((each) => each.id === finishing.provider)?.name ?? finishing.provider}.` : null}
			{finishing.state === "failed" ? `The sign-in did not finish: ${finishing.message}` : null}
		</p>
	);
}
