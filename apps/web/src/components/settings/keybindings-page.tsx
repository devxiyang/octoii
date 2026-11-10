/** Keybindings: the keyboard's shortcuts, by where they work, in plain words — what sends a message as this device has it. */
import type { ReactNode } from "react";
import type { Device } from "../../core/device.ts";
import { Kbd } from "../ui/kbd.tsx";
import { Page, Row, Section } from "./layout.tsx";

/** A shortcut: what it does, and its keys, one cap each. */
type Shortcut = { readonly title: string; readonly keys: readonly string[] };

/** A group of shortcuts: where they work, what of that needs saying, and the shortcuts. */
type Group = { readonly title: string; readonly description?: string; readonly shortcuts: readonly Shortcut[] };

/** The shortcuts, by where they work, the composer's as `send` sets what sends a message. */
function groupsOf(send: Device["send_shortcut"]): readonly Group[] {
	return [
		{
			title: "Anywhere",
			shortcuts: [
				{ title: "Open the command palette", keys: ["⌘", "K"] },
				{ title: "New thread", keys: ["⌘", "N"] },
				{ title: "Show or hide the sidebar", keys: ["⌘", "B"] },
				{ title: "Show or hide the panel", keys: ["⌘", "⌥", "B"] },
			],
		},
		{
			title: "Composer",
			description: "What sends is set in General.",
			shortcuts: [
				{ title: "Send", keys: send === "enter" ? ["Enter"] : ["⌘", "Enter"] },
				{ title: "New line", keys: send === "enter" ? ["⇧", "Enter"] : ["Enter"] },
				{ title: "Choose a model", keys: ["⌘", "'"] },
				{ title: "Star the highlighted model", keys: ["⌘", "F"] },
			],
		},
		{
			title: "When a thread asks",
			shortcuts: [
				{ title: "Allow", keys: ["⌘", "Enter"] },
				{ title: "Deny", keys: ["Esc"] },
				{ title: "Pick a question's choice", keys: ["1–9"] },
			],
		},
		{ title: "Settings", shortcuts: [{ title: "Search settings", keys: ["/"] }] },
	];
}

/** The page. */
export function KeybindingsPage(props: { readonly device: Device }): ReactNode {
	return (
		<Page title="Keybindings" description="The keyboard's shortcuts, by where they work.">
			{groupsOf(props.device.send_shortcut).map((group, place) => (
				<Section key={group.title} title={group.title} description={group.description} anchor={place === 0 ? "setting-keybindings" : undefined}>
					{group.shortcuts.map((shortcut) => (
						<Row key={shortcut.title} title={shortcut.title}>
							<span className="flex items-center gap-1">
								{shortcut.keys.map((key) => (
									<Kbd key={key}>{key}</Kbd>
								))}
							</span>
						</Row>
					))}
				</Section>
			))}
		</Page>
	);
}
