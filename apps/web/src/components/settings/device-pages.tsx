/**
 * The settings of this device: general (how the code views — a file's and a diff's — lay out what they show),
 * appearance (light, dark or the system's, the palette, contrast, glass and the
 * chat's width) and chat (what sends a message). The node keeps them for the device's session.
 */
import type { ReactNode } from "react";
import { type Device, type DeviceChange, PALETTES } from "../../core/device.ts";
import { RadioChoice, RadioGroup } from "../ui/choices.tsx";
import { cn } from "../ui/cn.ts";
import { Select } from "../ui/select.tsx";
import { Slider } from "../ui/slider.tsx";
import { Switch } from "../ui/switch.tsx";
import { Page, Row, Section, SectionHeading } from "./layout.tsx";
import { SchemePreview } from "./scheme-preview.tsx";

/** What a device page is given: what is set, and how to set it. */
type DevicePageProps = { readonly device: Device; readonly set: (change: DeviceChange) => void };

/** General. */
export function GeneralPage(props: DevicePageProps): ReactNode {
	return (
		<Page>
			<Section title="Files and diffs">
				<Row title="Wrap long lines" description="Long lines of a file and of a diff wrap onto the next, rather than scroll.">
					<Switch aria-label="Wrap long lines" checked={props.device.wrap_lines} onCheckedChange={(wrap_lines) => props.set({ wrap_lines })} />
				</Row>
				<Row title="Diff layout" description="A diff's two sides, one over the other or side by side.">
					<Select
						label="Diff layout"
						value={props.device.diff_layout}
						onValueChange={(diff_layout) => props.set({ diff_layout })}
						items={[
							{ value: "stacked", label: "Stacked" },
							{ value: "split", label: "Side by side" },
						]}
					/>
				</Row>
				<Row title="Folder tree" description="The Files view shows the folder's tree beside the file it reads.">
					<Switch aria-label="Folder tree" checked={props.device.files_tree} onCheckedChange={(files_tree) => props.set({ files_tree })} />
				</Row>
			</Section>
		</Page>
	);
}

/** How a card of a choice of the page reads: a card on the page, ringed in the primary colour while it is the one chosen. */
const CARD_CLASS =
	"flex cursor-pointer flex-col rounded-xl border border-border bg-card text-ui text-muted-foreground hover:bg-accent/40 focus-visible:ring-2 focus-visible:ring-ring data-checked:border-primary data-checked:text-foreground data-checked:ring-1 data-checked:ring-primary";

/** Appearance: the color scheme as three cards. */
export function AppearancePage(props: DevicePageProps): ReactNode {
	const schemes = [
		{ key: "system", label: "System" },
		{ key: "light", label: "Light" },
		{ key: "dark", label: "Dark" },
	] as const;
	return (
		<Page>
			<section className="flex flex-col gap-2">
				<SectionHeading title="Color scheme" />
				<RadioGroup
					aria-label="Color scheme"
					value={props.device.theme}
					onValueChange={(theme: Device["theme"]) => props.set({ theme })}
					className="grid grid-cols-3 gap-3"
				>
					{schemes.map((scheme) => (
						<RadioChoice key={scheme.key} value={scheme.key} render={<div />} className={cn(CARD_CLASS, "gap-2 p-2")}>
							<SchemePreview scheme={scheme.key} />
							<span>{scheme.label}</span>
						</RadioChoice>
					))}
				</RadioGroup>
			</section>
			<Palettes device={props.device} set={props.set} />
			<Section title="Interface">
				<Row title="Contrast" description="How far secondary text and borders lean toward the text.">
					<Slider label="Contrast" value={props.device.contrast} min={100} max={160} onValueChange={(contrast) => props.set({ contrast })} />
				</Row>
				<Row title="Glass opacity" description="Higher values make menus, dialogs and the composer more solid.">
					<Slider
						label="Glass opacity"
						value={props.device.glass_opacity}
						min={40}
						max={100}
						onValueChange={(opacity) => props.set({ glass_opacity: opacity })}
					/>
				</Row>
				<Row title="Chat width" description="How wide messages and the composer grow on a large screen.">
					<Select
						label="Chat width"
						value={props.device.chat_width}
						onValueChange={(width) => props.set({ chat_width: width })}
						items={[
							{ value: "narrow", label: "Narrow" },
							{ value: "comfortable", label: "Comfortable" },
							{ value: "wide", label: "Wide" },
						]}
					/>
				</Row>
			</Section>
		</Page>
	);
}

/** The palettes, each a card of its light and dark swatches, the chosen one ringed. */
function Palettes(props: DevicePageProps): ReactNode {
	return (
		<section className="flex flex-col gap-2">
			<SectionHeading title="Palettes" />
			<RadioGroup
				aria-label="Palette"
				value={props.device.palette}
				onValueChange={(palette: Device["palette"]) => props.set({ palette })}
				className="grid grid-cols-3 gap-3"
			>
				{PALETTES.map((palette) => (
					<RadioChoice key={palette.id} value={palette.id} render={<div />} className={cn(CARD_CLASS, "items-center gap-3 px-3 pt-4 pb-3")}>
						<span className="flex gap-3">
							<Swatch hue={palette.hue} lightness={0.96} />
							<Swatch hue={palette.hue} lightness={0.22} />
						</span>
						<span>{palette.label}</span>
					</RadioChoice>
				))}
			</RadioGroup>
		</section>
	);
}

/** A palette's swatch: its ground at `lightness` washing into its primary colour. */
function Swatch(props: { readonly hue: number; readonly lightness: number }): ReactNode {
	const ground = `oklch(${String(props.lightness)} 0.02 ${String(props.hue)})`;
	const primary = `oklch(0.6 0.14 ${String(props.hue)})`;
	return (
		<span
			aria-hidden
			className="size-12 rounded-full border border-border shadow-sm"
			style={{ background: `radial-gradient(circle at 30% 30%, ${ground} 35%, ${primary} 140%)` }}
		/>
	);
}

/** Chat: what sends a message. */
export function ChatPage(props: DevicePageProps): ReactNode {
	return (
		<Page>
			<Section title="Composer">
				<Row title="Send shortcut" description="Enter sends and Shift+Enter makes a new line; or Cmd/Ctrl+Enter sends and Enter makes a new line.">
					<Select
						label="Send shortcut"
						value={props.device.send_shortcut}
						onValueChange={(shortcut) => props.set({ send_shortcut: shortcut })}
						items={[
							{ value: "enter", label: "Enter" },
							{ value: "mod-enter", label: "⌘ Enter" },
						]}
					/>
				</Row>
			</Section>
		</Page>
	);
}
