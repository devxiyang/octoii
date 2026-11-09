/**
 * Where the window is: the one state of navigation, kept in the page's address after `#`, so going back, a shortcut, a
 * notification and a new window all name a place the same way. A place of the chat is a thread or a new thread, where a
 * window opens; settings open over it, so closing them leaves the chat as it was.
 */

/** The sections of settings, in the order their list shows them, in their groups; the first is where settings open. */
export const SETTINGS_SECTIONS = [
	{ key: "general", label: "General", group: "" },
	{ key: "appearance", label: "Appearance", group: "" },
	{ key: "chat", label: "Chat", group: "" },
	{ key: "keybindings", label: "Keybindings", group: "" },
	{ key: "providers", label: "Providers", group: "Agents" },
	{ key: "threads", label: "Threads", group: "Agents" },
	{ key: "archive", label: "Archive", group: "Agents" },
] as const;

/** A section of settings, by its key. */
export type SettingsSection = (typeof SETTINGS_SECTIONS)[number]["key"];

/** A place of the chat: a new thread, in a project's folder — the last one's where none is named — or none; or a thread. */
export type ChatPlace = { readonly place: "new"; readonly project?: string } | { readonly place: "thread"; readonly thread: string };

/** What opens over the chat: a section of settings. */
export type Overlay = { readonly kind: "settings"; readonly section: SettingsSection };

/** A place of the window: a place of the chat, and what is open over it, where something is. */
export type Route = ChatPlace & { readonly over?: Overlay };

/** Home, where a window opens and an address it cannot read leads: a new thread, in the last project's folder. */
export const HOME: Route = { place: "new" };

/**
 * The address of a place: `#/thread/<thread>`, `#/new/<project>`, or `#/` for home, then `?settings=<section>` where
 * settings are open.
 */
export function routeAddress(route: Route): string {
	const settings = route.over === undefined ? "" : `?settings=${route.over.section}`;
	switch (route.place) {
		case "thread":
			return `#/thread/${encodeURIComponent(route.thread)}${settings}`;
		case "new":
			return `#/${route.project === undefined ? "" : `new/${encodeURIComponent(route.project)}`}${settings}`;
	}
}

/** The place an address names; home for one it cannot read, and nothing over it for a section it does not know. */
export function routeOf(address: string): Route {
	const [path = "", query = ""] = address.replace(/^#/, "").split("?");
	const parts = path
		.split("/")
		.filter((part) => part !== "")
		.map((part) => decodeURIComponent(part));
	const section = SETTINGS_SECTIONS.find((each) => each.key === new URLSearchParams(query).get("settings"))?.key;
	const open = section === undefined ? {} : { over: { kind: "settings" as const, section } };
	const [place, name] = parts;
	if (place === "thread" && name !== undefined) return { place: "thread", thread: name, ...open };
	if (place === "new" && name !== undefined) return { place: "new", project: name, ...open };
	return { ...HOME, ...open };
}

/** The same place with `over` open over it, or nothing. */
export function withOverlay(route: Route, over: Overlay | undefined): Route {
	const { over: _over, ...place } = route;
	return over === undefined ? place : { ...place, over };
}

/** The same place with settings open at `section`. */
export function withSettings(route: Route, section: SettingsSection): Route {
	return withOverlay(route, { kind: "settings", section });
}

/** The settings section open over a place, if settings are. */
export function settingsOf(route: Route): SettingsSection | undefined {
	return route.over?.section;
}
