/**
 * The mode's control: a chip naming the mode the thread's calls follow, from which a card of the modes grows — the
 * three side by side, the chosen one's rules below them: what goes ahead on its own, and what is judged first, by the
 * person or by the review model; auto offered once the settings name a model to judge calls. ⌘. opens it too.
 */
import { type ReactNode, useState } from "react";
import type { Mode } from "@octoii-works/octoii-client";
import { useSettings } from "@octoii-works/octoii-client/react";
import { Check, ChevronDown, CircleDot, ShieldCheck, ShieldEllipsis, ShieldOff } from "lucide-react";
import { MODES, modeOffered, modeShown, rulesOf } from "../../core/modes.ts";
import { withSettings } from "../../core/route.ts";
import { shortcutLabel } from "../../core/shortcuts.ts";
import { useShortcut } from "../effects/shortcut.ts";
import { go, useRoute } from "../state/navigation.ts";
import { Button } from "../ui/button.tsx";
import { cn } from "../ui/cn.ts";
import { Popover, PopoverPopup, PopoverTrigger } from "../ui/popover.tsx";
import { Segmented } from "../ui/segmented.tsx";
import { Tip } from "../ui/tooltip.tsx";

/** The shortcut that opens the modes. */
const CHOOSE_MODE = "mod+.";

/** Each mode's icon: a shield where a sandbox keeps the work, one with an ellipsis where a model judges it, a broken one where nothing keeps it. */
const ICONS: Readonly<Record<Mode, typeof ShieldCheck>> = { default: ShieldCheck, auto: ShieldEllipsis, "full-access": ShieldOff };

/** What the mode's control is given: the mode chosen, and who is told of a choice. */
export type ModeControlProps = { readonly mode: Mode; readonly onChoose: (mode: Mode) => void };

/** The chip and the card it opens. */
export function ModeControl(props: ModeControlProps): ReactNode {
	const [open, setOpen] = useState(false);
	const route = useRoute();
	const reviewModel = useSettings()?.environment.review_model;
	useShortcut(CHOOSE_MODE, () => setOpen(!open));
	const Icon = ICONS[props.mode];
	const shown = modeShown(props.mode);
	const rules = rulesOf(props.mode);
	return (
		<Popover open={open} onOpenChange={setOpen}>
			<Tip label={shown.description} shortcut={shortcutLabel(CHOOSE_MODE)}>
				<PopoverTrigger
					aria-label={`Permissions: ${shown.label}`}
					render={<Button variant="ghost-muted" size="sm" className="h-control-sm gap-1 px-2 font-normal" onMouseDown={(event) => event.preventDefault()} />}
				>
					<Icon className={cn("size-3.5", props.mode === "full-access" && "text-warning-foreground")} />
					<span className="@max-md:hidden">{shown.label}</span>
					<ChevronDown className="-me-0.5 size-3.5 opacity-70" />
				</PopoverTrigger>
			</Tip>
			<PopoverPopup side="top" align="start" sideOffset={10} className="flex w-[min(24rem,calc(100vw-2rem))] flex-col gap-3 p-3">
				<div className="flex flex-col gap-0.5 px-0.5">
					<p className="text-sm font-medium">Permissions</p>
					<p className="text-xs text-muted-foreground">What the thread may do without asking you.</p>
				</div>
				<Segmented
					label="Mode"
					value={props.mode}
					onValueChange={props.onChoose}
					items={MODES.map((mode) => ({ value: mode, label: modeShown(mode).label, disabled: !modeOffered(mode, reviewModel) }))}
				/>
				<Rules title="Runs on its own" items={rules.own} icon={<Check className="size-3.5 text-success-foreground" />} />
				<Rules title={rules.judged.by} items={rules.judged.what} icon={<CircleDot className="size-3.5 text-warning-foreground" />} />
				{modeOffered("auto", reviewModel) ? null : (
					<p className="px-0.5 text-xs text-muted-foreground">
						Auto needs a model to judge calls.{" "}
						<button
							type="button"
							className="text-foreground underline-offset-2 hover:underline"
							onClick={() => {
								setOpen(false);
								go(withSettings(route, "threads"));
							}}
						>
							Name one in Settings
						</button>
					</p>
				)}
				<p className="border-t border-border/60 px-0.5 pt-2 text-xs text-muted-foreground">What you always allowed in the project goes ahead in every mode.</p>
			</PopoverPopup>
		</Popover>
	);
}

/** A list of the mode's rules under its title, each with its mark; that there is nothing where it holds none. */
function Rules(props: { readonly title: string; readonly items: readonly string[]; readonly icon: ReactNode }): ReactNode {
	return (
		<div className="flex flex-col gap-1 px-0.5">
			<p className="text-xs font-medium text-muted-foreground">{props.title}</p>
			{props.items.length === 0 ? (
				<p className="text-sm text-muted-foreground">Nothing</p>
			) : (
				<ul className="flex flex-col gap-1">
					{props.items.map((item) => (
						<li key={item} className="flex items-start gap-2 text-sm">
							<span className="mt-0.5 shrink-0">{props.icon}</span>
							<span>{item}</span>
						</li>
					))}
				</ul>
			)}
		</div>
	);
}
