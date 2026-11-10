/**
 * The mode's control: a chip naming the mode the thread's calls follow, from which the three modes open as a menu —
 * each its icon, its name and a few words of what it lets the thread do, the chosen one checked; ⌘. opens it too.
 * Auto, where the settings name no model to judge calls, opens the setting that names one.
 */
import { type ReactNode, useState } from "react";
import type { Mode } from "@octoii-works/octoii-client";
import { useSettings } from "@octoii-works/octoii-client/react";
import { ChevronDown, ShieldCheck, ShieldEllipsis, ShieldOff } from "lucide-react";
import { MODES, modeOffered, modeShown } from "../../core/modes.ts";
import { withOverlay } from "../../core/route.ts";
import { shortcutLabel } from "../../core/shortcuts.ts";
import { useShortcut } from "../effects/shortcut.ts";
import { go, useRoute } from "../state/navigation.ts";
import { Button } from "../ui/button.tsx";
import { cn } from "../ui/cn.ts";
import { Menu, MenuItem, MenuPopup, MenuRadioGroup, MenuRadioItem, MenuTrigger } from "../ui/menu.tsx";
import { Tip } from "../ui/tooltip.tsx";

/** The shortcut that opens the modes. */
const CHOOSE_MODE = "mod+.";

/** Each mode's icon: a shield where a sandbox keeps the work, one with an ellipsis where a model judges it, a broken one where nothing keeps it. */
const ICONS: Readonly<Record<Mode, typeof ShieldCheck>> = { default: ShieldCheck, auto: ShieldEllipsis, "full-access": ShieldOff };

/** What the mode's control is given: the mode chosen, and who is told of a choice. */
export type ModeControlProps = { readonly mode: Mode; readonly onChoose: (mode: Mode) => void };

/** The chip and the menu it opens. */
export function ModeControl(props: ModeControlProps): ReactNode {
	const [open, setOpen] = useState(false);
	const route = useRoute();
	const reviewModel = useSettings()?.environment.review_model;
	useShortcut(CHOOSE_MODE, () => setOpen(!open));
	const Icon = ICONS[props.mode];
	return (
		<Menu open={open} onOpenChange={setOpen}>
			<Tip label="Permissions" shortcut={shortcutLabel(CHOOSE_MODE)}>
				<MenuTrigger
					aria-label={`Permissions: ${modeShown(props.mode).label}`}
					render={<Button variant="ghost-muted" size="sm" className="h-control-sm gap-1 px-2 font-normal" onMouseDown={(event) => event.preventDefault()} />}
				>
					<Icon className={cn("size-3.5", props.mode === "full-access" && "text-warning-foreground")} />
					<span className="@max-md:hidden">{modeShown(props.mode).label}</span>
					<ChevronDown className="-me-0.5 size-3.5 opacity-70" />
				</MenuTrigger>
			</Tip>
			<MenuPopup side="top" align="start" sideOffset={10} className="w-72">
				<MenuRadioGroup value={props.mode} onValueChange={(mode: Mode) => props.onChoose(mode)}>
					{MODES.map((mode) =>
						modeOffered(mode, reviewModel) ? (
							<MenuRadioItem key={mode} value={mode} className="h-auto items-start py-1.5">
								<ModeWords mode={mode} description={modeShown(mode).description} />
							</MenuRadioItem>
						) : (
							<MenuItem
								key={mode}
								className="h-auto items-start py-1.5"
								onClick={() => go(withOverlay(route, { kind: "settings", section: "threads", at: "setting-review-model" }))}
							>
								<ModeWords mode={mode} description="Name a review model first" />
							</MenuItem>
						),
					)}
				</MenuRadioGroup>
			</MenuPopup>
		</Menu>
	);
}

/** A mode's line in the menu: its icon, its name, and the few words under it. */
function ModeWords(props: { readonly mode: Mode; readonly description: string }): ReactNode {
	const Icon = ICONS[props.mode];
	return (
		<>
			<Icon className={cn("mt-0.5 size-4 shrink-0", props.mode === "full-access" && "text-warning-foreground")} />
			<span className="flex min-w-0 flex-col">
				<span>{modeShown(props.mode).label}</span>
				<span className="text-xs text-muted-foreground">{props.description}</span>
			</span>
		</>
	);
}
