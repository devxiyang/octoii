/**
 * Settings: a page of the frame, the route naming its section, so closing them goes back to the place the route holds
 * under them. In the sidebar's place, a search, `/` its key, and the sections, each with its icon; while the search
 * holds words, the settings it finds instead, each under its section's name, which bring their row into view. The open
 * section's page fills the page's column under a bar that holds the frame's button that shows the sidebar, where it is
 * not beside the page, and the one that closes settings.
 */
import { type ReactNode, useRef, useState } from "react";
import { Keyboard, MessagesSquare, Palette, Search, SlidersHorizontal, Sparkles, X } from "lucide-react";
import { SETTINGS_SECTIONS, type SettingsSection } from "../../core/route.ts";
import { type SettingsItem, settingsFound } from "../../core/settings-search.ts";
import { useIntoView } from "../effects/into-view.ts";
import { useShortcut } from "../effects/shortcut.ts";
import { HideSidebar, Pane, ShowSidebar } from "../frame/frame.tsx";
import { useDevice } from "../state/device.ts";
import { IconButton } from "../ui/button.tsx";
import { Input } from "../ui/input.tsx";
import { Kbd } from "../ui/kbd.tsx";
import { GeneralPage } from "./general-page.tsx";
import { KeybindingsPage } from "./keybindings-page.tsx";
import { ModelsPage } from "./models-page.tsx";
import { ThreadsPage } from "./threads-page.tsx";

/** Each section's icon. */
const SECTION_ICONS: Readonly<Record<SettingsSection, typeof Palette>> = {
	general: SlidersHorizontal,
	models: Sparkles,
	threads: MessagesSquare,
	keybindings: Keyboard,
};

/**
 * What settings are given: the section open and the setting brought into view on it, where one is; and who is told of
 * another section — with a setting to bring into view — or of none as settings close.
 */
export type SettingsProps = {
	readonly section: SettingsSection;
	readonly at: string | undefined;
	readonly onSection: (section: SettingsSection | undefined, at?: string) => void;
};

/** How a line of the sections' list reads: muted, the one shown marked. */
const LINE =
	"group/line flex h-control-sm w-full items-center gap-2 rounded-md px-2 text-left text-ui text-muted-foreground outline-none hover:bg-accent focus-visible:ring-2 focus-visible:ring-ring aria-[current=page]:bg-selected aria-[current=page]:text-foreground";

/** The sections, in the sidebar's place: under its header the search, then the sections — or, while the search holds words, the settings it finds. */
export function SettingsNav(props: SettingsProps): ReactNode {
	const [search, setSearch] = useState("");
	const box = useRef<HTMLInputElement>(null);
	useShortcut("/", () => box.current?.focus());
	const searching = search.trim() !== "";
	return (
		<>
			<div className="flex h-[var(--topbar-height)] shrink-0 items-center gap-1.5 px-2">
				<span className="min-w-0 flex-1 ps-2 text-ui font-semibold tracking-tight">Settings</span>
				<HideSidebar />
			</div>
			<nav aria-label="Settings" className="flex min-h-0 flex-1 flex-col gap-px overflow-y-auto px-2 pb-2 scrollbar-none">
				<label className="mb-1 flex h-control shrink-0 items-center gap-2 rounded-md px-2 focus-within:ring-1 focus-within:ring-ring hover:bg-accent">
					<Search className="size-4 shrink-0 text-muted-foreground" />
					<Input
						ref={box}
						type="search"
						variant="bare"
						aria-label="Search settings"
						placeholder="Search settings"
						value={search}
						onValueChange={setSearch}
						className="font-medium placeholder:text-muted-foreground"
					/>
					{searching ? null : <Kbd className="pointer-coarse:hidden">/</Kbd>}
				</label>
				{searching ? (
					<Found items={settingsFound(search)} onSection={props.onSection} />
				) : (
					SETTINGS_SECTIONS.map((section) => {
						const Icon = SECTION_ICONS[section.key];
						return (
							<button
								key={section.key}
								type="button"
								aria-current={section.key === props.section ? "page" : undefined}
								onClick={() => props.onSection(section.key)}
								className={LINE}
							>
								<Icon className="size-4 text-muted-foreground group-aria-[current=page]/line:text-foreground" />
								{section.label}
							</button>
						);
					})
				)}
			</nav>
		</>
	);
}

/** The settings a search found, each its title over its section's name, opening its section with its row brought into view; or that it found none. */
function Found(props: { readonly items: readonly SettingsItem[]; readonly onSection: SettingsProps["onSection"] }): ReactNode {
	if (props.items.length === 0) return <p className="px-2 py-4 text-center text-xs text-faint-foreground">No settings found</p>;
	return props.items.map((item) => (
		<button
			key={item.anchor}
			type="button"
			onClick={() => props.onSection(item.section, item.anchor)}
			className={`${LINE} h-auto flex-col items-start gap-0 py-1.5`}
		>
			<span className="text-foreground">{item.title}</span>
			<span className="text-xs text-faint-foreground">{SETTINGS_SECTIONS.find((section) => section.key === item.section)?.label}</span>
		</button>
	));
}

/**
 * The open section's page, in the page's column, under the bar that holds the frame's button that shows the sidebar and
 * the one that closes settings; the setting the place names brought into view.
 */
export function SettingsPage(props: SettingsProps): ReactNode {
	useIntoView(props.at);
	return (
		<Pane>
			<header className="flex h-[var(--topbar-height)] shrink-0 items-center gap-2 bg-background px-3 @xl/pane:px-5">
				<ShowSidebar className="-ml-1" />
				<span className="flex-1" />
				<IconButton label="Close settings" onClick={() => props.onSection(undefined)} className="-mr-1">
					<X className="size-4" />
				</IconButton>
			</header>
			<div className="min-h-0 flex-1 overflow-y-auto scrollbar-even">
				<SectionPage section={props.section} />
			</div>
		</Pane>
	);
}

/** The page of a section. */
function SectionPage(props: { readonly section: SettingsSection }): ReactNode {
	const { device, set, restore } = useDevice();
	switch (props.section) {
		case "general":
			return <GeneralPage device={device} set={set} restore={restore} />;
		case "models":
			return <ModelsPage />;
		case "threads":
			return <ThreadsPage />;
		case "keybindings":
			return <KeybindingsPage device={device} />;
	}
}
