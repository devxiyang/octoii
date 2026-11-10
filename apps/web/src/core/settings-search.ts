/**
 * The settings the search finds: each by its section, its title as its row reads it, the other words it answers to,
 * and the anchor its row stands at; those that a search's words find, in the order their sections stand.
 */
import type { SettingsSection } from "./route.ts";

/** A setting the search finds. */
export type SettingsItem = { readonly section: SettingsSection; readonly title: string; readonly words: string; readonly anchor: string };

/** Every setting the search finds, in the order their sections stand. */
export const SETTINGS_ITEMS: readonly SettingsItem[] = [
	{ section: "general", title: "Theme", words: "appearance color colour scheme light dark system", anchor: "setting-theme" },
	{ section: "general", title: "Palette", words: "appearance color colour accent hue", anchor: "setting-palette" },
	{ section: "general", title: "Chat width", words: "appearance narrow comfortable wide column messages", anchor: "setting-chat-width" },
	{ section: "general", title: "Send shortcut", words: "composer enter keyboard new line", anchor: "setting-send-shortcut" },
	{ section: "general", title: "Wrap long lines", words: "files diffs wrap scroll", anchor: "setting-wrap-lines" },
	{ section: "general", title: "Diff layout", words: "files diffs split stacked side by side", anchor: "setting-diff-layout" },
	{ section: "general", title: "Folder tree", words: "files tree", anchor: "setting-folder-tree" },
	{ section: "general", title: "Restore defaults", words: "reset device", anchor: "setting-restore" },
	{ section: "models", title: "Providers", words: "api key sign in account connect claude openai anthropic openrouter ollama", anchor: "setting-providers" },
	{ section: "models", title: "Usage", words: "limits plan quota reset", anchor: "setting-usage" },
	{ section: "threads", title: "Permission mode", words: "permissions default auto full access sandbox", anchor: "setting-mode" },
	{ section: "threads", title: "Review model", words: "permissions auto reviewer judge", anchor: "setting-review-model" },
	{ section: "threads", title: "Allowed", words: "permissions always allow grants project commands", anchor: "setting-allowed" },
	{ section: "threads", title: "Archive", words: "archived threads restore delete", anchor: "setting-archive" },
	{ section: "keybindings", title: "Keybindings", words: "shortcuts keys commands", anchor: "setting-keybindings" },
];

/** The settings `search` finds: each whose title or other words hold every word of it; none where it holds no word. */
export function settingsFound(search: string): readonly SettingsItem[] {
	const words = search
		.trim()
		.toLowerCase()
		.split(/\s+/)
		.filter((word) => word !== "");
	if (words.length === 0) return [];
	return SETTINGS_ITEMS.filter((item) => {
		const text = `${item.title} ${item.words}`.toLowerCase();
		return words.every((word) => text.includes(word));
	});
}
