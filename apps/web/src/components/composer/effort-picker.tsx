/**
 * How hard the thread's model reasons: a chip naming the effort chosen — the model's own where none is — which opens a
 * menu of those the model takes, highest first, its default marked; ⇧⌘D steps to the next. Nothing for a model that
 * does not reason.
 */
import { type ReactNode, useState } from "react";
import type { Effort } from "@octoii-works/octoii-client";
import { Brain, ChevronDown } from "lucide-react";
import { effortLabel, effortsOf, modelOf, nextEffort } from "../../core/models.ts";
import { shortcutLabel } from "../../core/shortcuts.ts";
import { useShortcut } from "../effects/shortcut.ts";
import { Button } from "../ui/button.tsx";
import { Menu, MenuPopup, MenuRadioGroup, MenuRadioItem, MenuTrigger } from "../ui/menu.tsx";
import { Tip } from "../ui/tooltip.tsx";
import { useDirectory } from "./directory.ts";

/** The shortcut that steps to the next effort. */
const NEXT_EFFORT = "mod+shift+d";

/** What the effort's control is given: the model, the effort chosen — none, the model's own — and who is told of a choice. */
export type EffortControlProps = { readonly model: string | undefined; readonly effort: Effort | undefined; readonly onChoose: (effort: Effort) => void };

/** The chip and the menu it opens. */
export function EffortControl(props: EffortControlProps): ReactNode {
	const [open, setOpen] = useState(false);
	const model = modelOf(useDirectory(), props.model);
	const efforts = effortsOf(model);
	const fallback = model?.reasoning?.default_effort;
	const shown = props.effort ?? fallback;
	useShortcut(NEXT_EFFORT, () => {
		const next = nextEffort(efforts, shown);
		if (next !== undefined) props.onChoose(next);
	});
	if (efforts.length === 0) return null;
	return (
		<Menu open={open} onOpenChange={setOpen}>
			<Tip label="How hard the model reasons" shortcut={shortcutLabel(NEXT_EFFORT)}>
				<MenuTrigger
					aria-label={`Effort: ${shown === undefined ? "the model's own" : effortLabel(shown)}`}
					render={<Button variant="ghost-muted" size="sm" className="h-control-sm gap-1 px-2 font-normal" onMouseDown={(event) => event.preventDefault()} />}
				>
					<Brain className="size-3.5" />
					<span className="@max-sm:hidden">{shown === undefined ? "Default" : effortLabel(shown)}</span>
					<ChevronDown className="-me-0.5 size-3.5 opacity-70" />
				</MenuTrigger>
			</Tip>
			<MenuPopup side="top" align="start" className="w-48">
				<MenuRadioGroup value={shown ?? null}>
					{efforts.map((effort) => (
						<MenuRadioItem key={effort} value={effort} onClick={() => props.onChoose(effort)}>
							<span className="flex-1">{effortLabel(effort)}</span>
							{effort === fallback ? <span className="text-xs text-muted-foreground">default</span> : null}
						</MenuRadioItem>
					))}
				</MenuRadioGroup>
			</MenuPopup>
		</Menu>
	);
}
