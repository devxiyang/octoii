/**
 * General: what is set for this device, which the node keeps for its session — how Octoii looks (light, dark or the
 * system's; the palette; how wide the chat grows), what sends a message, and how a file and a diff read — and what puts
 * it all back as it came, asked first.
 */
import { type ReactNode, useState } from "react";
import { type Device, type DeviceChange, PALETTES, type PaletteVariables, paletteVariables } from "../../core/device.ts";
import { useDarkPage } from "../effects/theme.ts";
import { Button } from "../ui/button.tsx";
import { RadioChoice, RadioGroup } from "../ui/choices.tsx";
import { cn } from "../ui/cn.ts";
import { Select } from "../ui/select.tsx";
import { Switch } from "../ui/switch.tsx";
import { Tip } from "../ui/tooltip.tsx";
import { BlockRow, Page, Row, Section } from "./layout.tsx";
import { SchemePreview } from "./scheme-preview.tsx";

declare module "react" {
	interface CSSProperties extends Partial<PaletteVariables> {}
}

/** What the page is given: what is set for this device, how to set it, and how to put it back as it came. */
export type GeneralPageProps = { readonly device: Device; readonly set: (change: DeviceChange) => void; readonly restore: () => void };

/** The page. */
export function GeneralPage(props: GeneralPageProps): ReactNode {
	const { device, set } = props;
	return (
		<Page title="General" description="How Octoii looks and reads on this device, and what sends a message.">
			<Section title="Appearance">
				<BlockRow title="Theme" anchor="setting-theme">
					<Schemes device={device} set={set} />
				</BlockRow>
				<BlockRow title="Palette" description="The colour of buttons, links and what is chosen." anchor="setting-palette">
					<Palettes device={device} set={set} />
				</BlockRow>
				<Row title="Chat width" description="How wide messages and the composer grow on a large screen." anchor="setting-chat-width">
					<Select
						label="Chat width"
						value={device.chat_width}
						onValueChange={(chat_width) => set({ chat_width })}
						items={[
							{ value: "narrow", label: "Narrow" },
							{ value: "comfortable", label: "Comfortable" },
							{ value: "wide", label: "Wide" },
						]}
					/>
				</Row>
			</Section>
			<Section title="Composer">
				<Row title="Send shortcut" description="The other key makes a new line." anchor="setting-send-shortcut">
					<Select
						label="Send shortcut"
						value={device.send_shortcut}
						onValueChange={(send_shortcut) => set({ send_shortcut })}
						items={[
							{ value: "enter", label: "Enter" },
							{ value: "mod-enter", label: "⌘ Enter" },
						]}
					/>
				</Row>
			</Section>
			<Section title="Files and diffs">
				<Row title="Wrap long lines" description="Long lines wrap onto the next, rather than scroll." anchor="setting-wrap-lines">
					<Switch aria-label="Wrap long lines" checked={device.wrap_lines} onCheckedChange={(wrap_lines) => set({ wrap_lines })} />
				</Row>
				<Row title="Diff layout" description="A diff's two sides, one over the other or side by side." anchor="setting-diff-layout">
					<Select
						label="Diff layout"
						value={device.diff_layout}
						onValueChange={(diff_layout) => set({ diff_layout })}
						items={[
							{ value: "stacked", label: "Stacked" },
							{ value: "split", label: "Side by side" },
						]}
					/>
				</Row>
				<Row title="Folder tree" description="The Files view shows the folder's tree beside the file." anchor="setting-folder-tree">
					<Switch aria-label="Folder tree" checked={device.files_tree} onCheckedChange={(files_tree) => set({ files_tree })} />
				</Row>
			</Section>
			<Section title="This device">
				<Restore onRestore={props.restore} />
			</Section>
		</Page>
	);
}

/** How a scheme's card reads: its picture over its name, ringed in the primary colour while it is the one chosen. */
const SCHEME_CARD =
	"flex cursor-pointer flex-col gap-2 rounded-lg border border-border bg-card p-2 text-ui text-muted-foreground outline-none hover:bg-accent focus-visible:ring-2 focus-visible:ring-ring data-checked:border-primary data-checked:text-foreground data-checked:ring-1 data-checked:ring-primary";

/** The schemes, each a card of its picture: the system's, light and dark. */
function Schemes(props: { readonly device: Device; readonly set: (change: DeviceChange) => void }): ReactNode {
	const schemes = [
		{ key: "system", label: "System" },
		{ key: "light", label: "Light" },
		{ key: "dark", label: "Dark" },
	] as const;
	return (
		<RadioGroup
			aria-label="Theme"
			value={props.device.theme}
			onValueChange={(theme: Device["theme"]) => props.set({ theme })}
			className="grid grid-cols-3 gap-3 @md:grid-cols-[repeat(3,minmax(0,11rem))]"
		>
			{schemes.map((scheme) => (
				<RadioChoice key={scheme.key} value={scheme.key} render={<div />} className={SCHEME_CARD}>
					<SchemePreview scheme={scheme.key} />
					<span>{scheme.label}</span>
				</RadioChoice>
			))}
		</RadioGroup>
	);
}

/** The palettes, each a dot of its primary colour in the scheme the page shows, its name its tip; the chosen one ringed, and named beside them. */
function Palettes(props: { readonly device: Device; readonly set: (change: DeviceChange) => void }): ReactNode {
	const scheme = useDarkPage() ? "dark" : "light";
	const chosen = PALETTES.find((palette) => palette.id === props.device.palette) ?? PALETTES[0];
	return (
		<div className="flex flex-wrap items-center gap-x-4 gap-y-2">
			<RadioGroup
				aria-label="Palette"
				value={props.device.palette}
				onValueChange={(palette: Device["palette"]) => props.set({ palette })}
				className="flex flex-wrap items-center gap-2.5"
			>
				{PALETTES.map((palette) => (
					<Tip key={palette.id} label={palette.label}>
						<RadioChoice
							value={palette.id}
							aria-label={palette.label}
							render={<span />}
							className="flex size-7 cursor-pointer items-center justify-center rounded-full outline-none focus-visible:ring-2 focus-visible:ring-ring data-checked:ring-2 data-checked:ring-primary"
						>
							<span aria-hidden className={cn(scheme, "size-5 rounded-full bg-primary")} style={paletteVariables(palette)} />
						</RadioChoice>
					</Tip>
				))}
			</RadioGroup>
			<span className="text-ui text-muted-foreground">{chosen?.label}</span>
		</div>
	);
}

/** The row that puts this device's settings back as they came, asked first. */
function Restore(props: { readonly onRestore: () => void }): ReactNode {
	const [asking, setAsking] = useState(false);
	return (
		<Row
			title="Restore defaults"
			description={asking ? "Appearance, the composer, and files and diffs go back as they came." : "Put this device's settings back as they came."}
			anchor="setting-restore"
		>
			{asking ? (
				<>
					<Button size="sm" variant="ghost-muted" onClick={() => setAsking(false)}>
						Cancel
					</Button>
					<Button
						size="sm"
						variant="destructive"
						onClick={() => {
							props.onRestore();
							setAsking(false);
						}}
					>
						Restore
					</Button>
				</>
			) : (
				<Button size="sm" variant="outline" onClick={() => setAsking(true)}>
					Restore…
				</Button>
			)}
		</Row>
	);
}
