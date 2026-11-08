/**
 * What the person set for the device the page runs on, as the node keeps it for the device's session: the theme and its
 * palette, contrast and glass, how wide the chat grows, what sends a message, how the sidebar groups threads and how
 * wide it is, how wide the right panel is, how the diff lays out its sides, whether code views wrap their long lines,
 * and whether the Files view shows its tree — each with its default where nothing is set. What is kept is read through the schema of what it may hold;
 * whatever else it holds is left.
 */
import { matches } from "@octoii-works/octoii-client";
import { type Static, Type } from "typebox";

/** What a device may have set, each field on its own. */
const DeviceSchema = Type.Object({
	theme: Type.Union([Type.Literal("system"), Type.Literal("light"), Type.Literal("dark")]),
	send_shortcut: Type.Union([Type.Literal("enter"), Type.Literal("mod-enter")]),
	sidebar_grouping: Type.Union([Type.Literal("status"), Type.Literal("project")]),
	sidebar_width: Type.Number(),
	panel_width: Type.Number(),
	palette: Type.Union([
		Type.Literal("default"),
		Type.Literal("deep-sea"),
		Type.Literal("lagoon"),
		Type.Literal("coral"),
		Type.Literal("sand"),
		Type.Literal("kelp"),
		Type.Literal("anemone"),
		Type.Literal("forest"),
		Type.Literal("lilac"),
	]),
	contrast: Type.Number(),
	glass_opacity: Type.Number(),
	chat_width: Type.Union([Type.Literal("narrow"), Type.Literal("comfortable"), Type.Literal("wide")]),
	diff_layout: Type.Union([Type.Literal("stacked"), Type.Literal("split")]),
	wrap_lines: Type.Boolean(),
	files_tree: Type.Boolean(),
});

/** What is set for a device, each field its default where nothing is set. */
export type Device = Static<typeof DeviceSchema>;

/** A change of what is set for the device: the fields it sets. */
export type DeviceChange = Partial<Device>;

/** What every device has before the person sets anything, which restoring the defaults puts back. */
export const DEVICE_DEFAULTS: Device = {
	theme: "system",
	send_shortcut: "enter",
	sidebar_grouping: "status",
	sidebar_width: 256,
	panel_width: 560,
	palette: "default",
	contrast: 100,
	glass_opacity: 80,
	chat_width: "comfortable",
	diff_layout: "stacked",
	wrap_lines: false,
	files_tree: true,
};

const KeptSchema = Type.Record(Type.String(), Type.Unknown());

/** What is set, from what is kept: each field it holds that fits, the defaults filling the rest. */
export function deviceOf(kept: unknown): Device {
	const given = matches(KeptSchema, kept) ? kept : {};
	const fitting = Object.entries(DeviceSchema.properties).flatMap(([name, schema]) => (matches(schema, given[name]) ? [[name, given[name]]] : []));
	const device: unknown = { ...DEVICE_DEFAULTS, ...Object.fromEntries(fitting) };
	return matches(DeviceSchema, device) ? device : DEVICE_DEFAULTS;
}

/** Whether the page shows dark: the device's theme, or the system's where the theme follows it. */
export function isDark(theme: Device["theme"], systemDark: boolean): boolean {
	return theme === "dark" || (theme === "system" && systemDark);
}

/** Each palette: its name and the hue it leans toward, for its swatch. */
export const PALETTES: readonly { readonly id: Device["palette"]; readonly label: string; readonly hue: number }[] = [
	{ id: "default", label: "Default", hue: 264 },
	{ id: "deep-sea", label: "Deep Sea", hue: 238 },
	{ id: "lagoon", label: "Lagoon", hue: 192 },
	{ id: "coral", label: "Coral", hue: 25 },
	{ id: "sand", label: "Sand", hue: 75 },
	{ id: "kelp", label: "Kelp", hue: 125 },
	{ id: "anemone", label: "Anemone", hue: 345 },
	{ id: "forest", label: "Forest", hue: 158 },
	{ id: "lilac", label: "Lilac", hue: 295 },
];
