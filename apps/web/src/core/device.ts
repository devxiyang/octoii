/**
 * What the person set for the device the page runs on, as the node keeps it for the device's session: the theme and its
 * palette, how wide the chat grows, what sends a message, how wide the sidebar and the right panel are, how the diff
 * lays out its sides, whether code views wrap their long lines, and whether the Files view shows its tree — each with
 * its default where nothing is set. What is kept is read through the schema of what it may hold; whatever else it holds
 * is left.
 */
import { matches } from "@octoii-works/octoii-client";
import { type Static, Type } from "typebox";

/** What a device may have set, each field on its own. */
const DeviceSchema = Type.Object({
	theme: Type.Union([Type.Literal("system"), Type.Literal("light"), Type.Literal("dark")]),
	send_shortcut: Type.Union([Type.Literal("enter"), Type.Literal("mod-enter")]),
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
	sidebar_width: 256,
	panel_width: 560,
	palette: "default",
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

/**
 * A palette: its name, and the three numbers every colour of the design is made from — the hue all of them lean to, how
 * far the greys lean to it, and how vivid the primary colour is.
 */
export interface Palette {
	readonly id: Device["palette"];
	readonly label: string;
	readonly hue: number;
	readonly tint: number;
	readonly chroma: number;
}

/** The palette of a device that set none: its greys barely lean to its hue, so it reads as neutral. */
const DEFAULT_PALETTE: Palette = { id: "default", label: "Default", hue: 264, tint: 0.3, chroma: 0.2 };

/** The palettes: the default, and those whose greys lean to their hues. */
export const PALETTES: readonly Palette[] = [
	DEFAULT_PALETTE,
	{ id: "deep-sea", label: "Deep Sea", hue: 238, tint: 1, chroma: 0.156 },
	{ id: "lagoon", label: "Lagoon", hue: 192, tint: 1, chroma: 0.12 },
	{ id: "coral", label: "Coral", hue: 25, tint: 1, chroma: 0.156 },
	{ id: "sand", label: "Sand", hue: 75, tint: 1, chroma: 0.132 },
	{ id: "kelp", label: "Kelp", hue: 125, tint: 1, chroma: 0.12 },
	{ id: "anemone", label: "Anemone", hue: 345, tint: 1, chroma: 0.144 },
	{ id: "forest", label: "Forest", hue: 158, tint: 1, chroma: 0.12 },
	{ id: "lilac", label: "Lilac", hue: 295, tint: 1, chroma: 0.12 },
];

/** The stylesheet's variables a palette sets, which every colour is made from wherever they stand. */
export type PaletteVariables = Readonly<Record<"--palette-hue" | "--palette-tint" | "--palette-chroma", string>>;

/** The variables of `palette`. */
export function paletteVariables(palette: Palette): PaletteVariables {
	return { "--palette-hue": String(palette.hue), "--palette-tint": String(palette.tint), "--palette-chroma": String(palette.chroma) };
}

/** The palette a device has set. */
export function paletteOf(id: Device["palette"]): Palette {
	return PALETTES.find((palette) => palette.id === id) ?? DEFAULT_PALETTE;
}
