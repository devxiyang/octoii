/** Keybindings: the keyboard's shortcuts, by where they work, those whose name holds the search. */
import { type ReactNode, useState } from "react";
import { Field } from "../ui/input.tsx";
import { Kbd } from "../ui/kbd.tsx";
import { Page, Row, Section } from "./layout.tsx";

/** A shortcut: what it does, when it works, and its keys, one cap each. */
type Shortcut = { readonly title: string; readonly when: string; readonly keys: readonly string[] };

/** The shortcuts, by where they work. */
const SHORTCUTS: readonly { readonly group: string; readonly shortcuts: readonly Shortcut[] }[] = [
	{
		group: "Navigation",
		shortcuts: [
			{ title: "Command Palette: Toggle", when: "Always", keys: ["⌘", "K"] },
			{ title: "Thread: New", when: "Always", keys: ["⌘", "N"] },
			{ title: "Sidebar: Toggle", when: "Always", keys: ["⌘", "B"] },
			{ title: "Settings: Search", when: "Settings open, no text field focused", keys: ["/"] },
		],
	},
	{
		group: "Composer",
		shortcuts: [
			{ title: "Message: Send", when: "Composer focused", keys: ["Enter"] },
			{ title: "Message: New line", when: "Composer focused", keys: ["⇧", "Enter"] },
			{ title: "Model: Choose", when: "Composer shown", keys: ["⌘", "'"] },
		],
	},
];

/** The page. */
export function KeybindingsPage(): ReactNode {
	const [search, setSearch] = useState("");
	const words = search.trim().toLowerCase();
	return (
		<Page>
			<Section title="Keybindings">
				<div className="p-3">
					<Field label="Search keybindings" placeholder="Search keybindings" value={search} onValueChange={setSearch} />
				</div>
			</Section>
			{SHORTCUTS.map(({ group, shortcuts }) => {
				const shown = shortcuts.filter((shortcut) => shortcut.title.toLowerCase().includes(words));
				return shown.length === 0 ? null : (
					<Section key={group} title={group}>
						{shown.map((shortcut) => (
							<Row key={shortcut.title} title={shortcut.title} description={`When ${shortcut.when}`}>
								<span className="flex gap-1">
									{shortcut.keys.map((key) => (
										<Kbd key={key}>{key}</Kbd>
									))}
								</span>
							</Row>
						))}
					</Section>
				);
			})}
		</Page>
	);
}
