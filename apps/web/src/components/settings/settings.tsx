/**
 * Settings: a modal over the chat, the route naming its section, so closing it leaves the chat as it was; its sections
 * listed on the left in their groups, each with its icon, under a search that narrows them, `/` its key; the open one's
 * page on the right under a breadcrumb, with a button that puts this device's settings back as they came.
 */
import { type ReactNode, useRef, useState } from "react";
import { Archive, Gauge, Keyboard, MessageSquareText, MessagesSquare, Palette, RotateCcw, Search, SlidersHorizontal, Sparkles, X } from "lucide-react";
import { SETTINGS_SECTIONS, type SettingsSection } from "../../core/route.ts";
import { useShortcut } from "../effects/shortcut.ts";
import { useDevice } from "../state/device.ts";
import { IconButton } from "../ui/button.tsx";
import { Dialog, DialogPopup, DialogTitle } from "../ui/dialog.tsx";
import { Input } from "../ui/input.tsx";
import { Kbd } from "../ui/kbd.tsx";
import { AppearancePage, ChatPage, GeneralPage } from "./device-pages.tsx";
import { KeybindingsPage } from "./keybindings-page.tsx";
import { ProvidersPage } from "./providers-page.tsx";
import { UsagePage } from "./usage-page.tsx";
import { ArchivePage } from "./archive-page.tsx";
import { ThreadsPage } from "./threads-page.tsx";

/** Each section's icon. */
const SECTION_ICONS: Readonly<Record<SettingsSection, typeof Palette>> = {
	general: SlidersHorizontal,
	appearance: Palette,
	chat: MessageSquareText,
	keybindings: Keyboard,
	providers: Sparkles,
	usage: Gauge,
	threads: MessagesSquare,
	archive: Archive,
};

/** The sections of what is set for this device, whose header offers its defaults back. */
const DEVICE_SECTIONS: readonly SettingsSection[] = ["general", "appearance", "chat"];

/** Settings at `section`, or closed where it is none. */
export function Settings(props: {
	readonly section: SettingsSection | undefined;
	readonly onSection: (section: SettingsSection | undefined) => void;
}): ReactNode {
	const shown = SETTINGS_SECTIONS.find((each) => each.key === props.section);
	return (
		<Dialog open={shown !== undefined} onOpenChange={(open) => (open ? undefined : props.onSection(undefined))}>
			<DialogPopup placement="fill" className="h-full max-h-[44rem] max-w-[56rem] self-center overflow-hidden bg-background">
				<DialogTitle className="sr-only">Settings</DialogTitle>
				<div className="flex h-full min-h-0">
					<SectionList shown={shown?.key} onSection={props.onSection} />
					<div className="flex min-w-0 flex-1 flex-col">
						<div className="flex h-11 shrink-0 items-center gap-2 border-b border-border ps-5 pe-2 text-ui">
							<span className="text-muted-foreground">Settings</span>
							<span className="text-muted-foreground/60">/</span>
							<span className="flex-1 font-medium">{shown?.label}</span>
							{shown !== undefined && DEVICE_SECTIONS.includes(shown.key) ? <RestoreDefaults /> : null}
							<IconButton label="Close settings" onClick={() => props.onSection(undefined)}>
								<X className="size-4" />
							</IconButton>
						</div>
						<div className="min-h-0 flex-1 overflow-y-auto">{shown === undefined ? null : <SectionPage section={shown.key} />}</div>
					</div>
				</div>
			</DialogPopup>
		</Dialog>
	);
}

/** The sections in their groups, each with its icon, those whose name holds the search. */
function SectionList(props: { readonly shown: SettingsSection | undefined; readonly onSection: (section: SettingsSection) => void }): ReactNode {
	const [search, setSearch] = useState("");
	const box = useRef<HTMLInputElement>(null);
	useShortcut("/", () => box.current?.focus());
	const words = search.trim().toLowerCase();
	const listed = SETTINGS_SECTIONS.filter((section) => section.label.toLowerCase().includes(words));
	return (
		<nav className="flex w-52 shrink-0 flex-col gap-px overflow-y-auto border-r border-border bg-sidebar p-2">
			<label className="mb-1 flex h-control items-center gap-2 rounded-md px-2 focus-within:bg-sidebar-row-hover">
				<Search className="size-4 text-sidebar-muted" />
				<Input
					ref={box}
					type="search"
					variant="bare"
					aria-label="Search settings"
					placeholder="Search"
					value={search}
					onValueChange={setSearch}
					className="text-ui placeholder:text-sidebar-muted"
				/>
				<Kbd>/</Kbd>
			</label>
			{listed.map((section, index) => {
				const Icon = SECTION_ICONS[section.key];
				return (
					<div key={section.key}>
						{section.group !== "" && listed[index - 1]?.group !== section.group ? (
							<p className="px-2 pt-3 pb-1 text-xs text-sidebar-muted">{section.group}</p>
						) : null}
						<button
							type="button"
							aria-current={section.key === props.shown ? "page" : undefined}
							onClick={() => props.onSection(section.key)}
							className="group/section flex h-control-sm w-full items-center gap-2 rounded-md px-2 text-left text-ui text-sidebar-foreground/75 hover:bg-sidebar-row-hover aria-[current=page]:bg-sidebar-row-active aria-[current=page]:text-foreground aria-[current=page]:shadow-xs"
						>
							<Icon className="size-3.5 text-sidebar-muted group-aria-[current=page]/section:text-foreground" />
							{section.label}
						</button>
					</div>
				);
			})}
		</nav>
	);
}

/** Puts this device's settings back as they came. */
function RestoreDefaults(): ReactNode {
	const { restore } = useDevice();
	return (
		<button
			type="button"
			onClick={restore}
			className="flex h-control-sm items-center gap-1.5 rounded-md px-2 text-ui text-muted-foreground hover:bg-accent hover:text-foreground"
		>
			<RotateCcw className="size-3.5" />
			Restore device defaults
		</button>
	);
}

/** The page of a section. */
function SectionPage(props: { readonly section: SettingsSection }): ReactNode {
	const { device, set } = useDevice();
	switch (props.section) {
		case "general":
			return <GeneralPage device={device} set={set} />;
		case "appearance":
			return <AppearancePage device={device} set={set} />;
		case "chat":
			return <ChatPage device={device} set={set} />;
		case "keybindings":
			return <KeybindingsPage />;
		case "providers":
			return <ProvidersPage />;
		case "usage":
			return <UsagePage />;
		case "threads":
			return <ThreadsPage />;
		case "archive":
			return <ArchivePage />;
	}
}
