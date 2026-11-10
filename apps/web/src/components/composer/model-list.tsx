/**
 * The models to choose from, as the model's chip opens them: a search over the models of the providers that hold a
 * credential; with nothing searched, the starred ones, then the recent, then each provider's, under headings that stay
 * as the list scrolls. The arrow keys walk the list while the search keeps the caret; ⌘F stars the highlighted model,
 * Enter or a click chooses it, the one chosen marked. Manage providers opens their settings.
 */
import { type ReactNode, useRef, useState } from "react";
import { useClient, useSettings, useThreads } from "@octoii-works/octoii-client/react";
import { Settings2, Star } from "lucide-react";
import { type ModelChoice, modelSections, providerName, providerOf, recentModelsOf, shortName, toggledFavorite } from "../../core/models.ts";
import { withSettings } from "../../core/route.ts";
import { type Vendor, vendorOfReference } from "../../core/vendors.ts";
import { go, useRoute } from "../state/navigation.ts";
import { failed } from "../state/notices.ts";
import { Button } from "../ui/button.tsx";
import { cn } from "../ui/cn.ts";
import { Command, CommandGroup, CommandHints, CommandItem, CommandList, CommandSearch } from "../ui/command.tsx";
import { VendorMark } from "../ui/vendor-mark.tsx";
import { useDirectory } from "./directory.ts";

/** A row of the list: where it stands — its section's title and the model — the model, and its maker, by its mark, else its provider's name. */
type Row = { readonly key: string; readonly model: ModelChoice; readonly vendor: Vendor | undefined; readonly provider: string };

/** A section of the list: its title, and its rows. */
type Section = { readonly title: string; readonly items: readonly Row[] };

/** What the list is given: the model chosen, who is told of another, and what closes the list as the person goes to manage the providers. */
export type ModelListProps = { readonly model: string | undefined; readonly onChoose: (model: string) => void; readonly onClose: () => void };

/** The hints of the list's keys. */
const HINTS = [
	{ keys: ["↑", "↓"], label: "Navigate" },
	{ keys: ["⌘", "F"], label: "Favorite" },
	{ keys: ["Enter"], label: "Choose" },
] as const;

/** The list: the directory read anew as it opens. */
export function ModelList(props: ModelListProps): ReactNode {
	const route = useRoute();
	const directory = useDirectory();
	const client = useClient();
	const favorites = useSettings()?.environment.favorite_models ?? [];
	const recent = recentModelsOf(useThreads() ?? []);
	const [query, setQuery] = useState("");
	// The row highlighted, which ⌘F stars: kept aside, as nothing is drawn of it but what the list draws itself.
	const highlighted = useRef<Row | undefined>(undefined);
	const sections: readonly Section[] =
		directory === undefined
			? []
			: modelSections({ directory, search: query, favorites, recent }).map((section) => ({
					title: section.title,
					items: section.models.map((model) => ({
						key: `${section.title}/${model.reference}`,
						model,
						vendor: vendorOfReference(directory, model.reference),
						provider: providerName(directory, providerOf(model.reference)),
					})),
				}));
	const star = (model: ModelChoice): void => {
		client
			.setSettings({ environment: { favorite_models: [...toggledFavorite(favorites, model.reference)] } })
			.catch((error: unknown) => failed("The favourites could not be kept", error));
	};
	return (
		<Command
			items={sections}
			mode="none"
			value={query}
			onValueChange={setQuery}
			onItemHighlighted={(row: Row | undefined) => {
				highlighted.current = row;
			}}
			itemToStringValue={(row: Row) => row.model.name}
		>
			<CommandSearch
				aria-label="Search models"
				placeholder="Search models..."
				onKeyDown={(event) => {
					const row = highlighted.current;
					if (!(event.metaKey || event.ctrlKey) || event.key.toLowerCase() !== "f" || row === undefined) return;
					event.preventDefault();
					star(row.model);
				}}
				aside={
					<Button
						variant="ghost-muted"
						size="xs"
						onClick={() => {
							props.onClose();
							go(withSettings(route, "providers"));
						}}
					>
						<Settings2 />
						Manage providers
					</Button>
				}
			/>
			<CommandList empty={directory === undefined ? "Reading the models…" : "No models found. A provider's models show once it has a key."}>
				{(section: Section) => (
					<CommandGroup key={section.title} title={section.title} items={section.items}>
						{(row: Row) => (
							<ModelRow
								key={row.key}
								row={row}
								starred={favorites.includes(row.model.reference)}
								chosen={row.model.reference === props.model}
								onChoose={() => props.onChoose(row.model.reference)}
								onStar={() => star(row.model)}
							/>
						)}
					</CommandGroup>
				)}
			</CommandList>
			<CommandHints hints={HINTS} />
		</Command>
	);
}

/** One model: its maker's mark, its name and context, its star — shown while it is starred, pointed at or highlighted — and its mark where it is chosen. */
function ModelRow(props: {
	readonly row: Row;
	readonly starred: boolean;
	readonly chosen: boolean;
	readonly onChoose: () => void;
	readonly onStar: () => void;
}): ReactNode {
	const { model } = props.row;
	return (
		<CommandItem value={props.row} onClick={props.onChoose} className="group/model h-control-lg">
			<VendorMark vendor={props.row.vendor} name={props.row.provider} />
			<span className="min-w-0 flex-1 truncate">{shortName(model.name)}</span>
			{model.context === undefined ? null : <span className="text-xs text-muted-foreground tabular-nums">{model.context}</span>}
			<button
				type="button"
				aria-label={props.starred ? "Unstar" : "Star"}
				onMouseDown={(event) => event.preventDefault()}
				onClick={(event) => {
					event.stopPropagation();
					props.onStar();
				}}
				className={cn(
					"rounded-sm p-0.5 hover:bg-accent",
					props.starred
						? "text-warning"
						: "text-muted-foreground opacity-0 group-hover/model:opacity-100 group-data-highlighted/model:opacity-100 pointer-coarse:opacity-100",
				)}
			>
				<Star className={cn("size-3.5", props.starred && "fill-current")} />
			</button>
			<span className={cn("size-1.5 rounded-full bg-primary", !props.chosen && "invisible")} />
		</CommandItem>
	);
}
