/**
 * The settings of this device: general (how the code views — a file's and a diff's — lay out what they show),
 * appearance (light, dark or the system's, the palette and the chat's width) and chat (what sends a message). The node keeps them for the device's session.
 */
import type { ReactNode } from "react";
import { type Device, type DeviceChange, PALETTES, type Palette, type PaletteVariables, paletteVariables } from "../../core/device.ts";
import { RadioChoice, RadioGroup } from "../ui/choices.tsx";
import { cn } from "../ui/cn.ts";
import { Select } from "../ui/select.tsx";
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
	"flex cursor-pointer flex-col rounded-lg border border-border bg-card text-ui text-muted-foreground hover:bg-accent focus-visible:ring-2 focus-visible:ring-ring data-checked:border-primary data-checked:text-foreground data-checked:ring-1 data-checked:ring-primary";

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
							<Swatch palette={palette} scheme="light" />
							<Swatch palette={palette} scheme="dark" />
						</span>
						<span>{palette.label}</span>
					</RadioChoice>
				))}
			</RadioGroup>
		</section>
	);
}

declare module "react" {
	interface CSSProperties extends Partial<PaletteVariables> {}
}

/** A palette's swatch in a scheme: its ground washing into its primary colour, by the design's own tokens. */
function Swatch(props: { readonly palette: Palette; readonly scheme: "light" | "dark" }): ReactNode {
	return (
		<span
			aria-hidden
			className={`${props.scheme} size-12 rounded-full border border-border bg-[radial-gradient(circle_at_30%_30%,var(--sidebar)_35%,var(--primary)_140%)]`}
			style={paletteVariables(props.palette)}
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
