/**
 * The model's control: a chip naming the provider and the model, from which the models to choose from open — a card
 * that grows out of the chip, over the composer — ⌘' opening it too; a model chosen, the focus goes back where the
 * person was typing.
 */
import type { ReactNode, RefObject } from "react";
import { ChevronDown } from "lucide-react";
import { modelLabel, providerName, providerOf } from "../../core/models.ts";
import { shortcutLabel } from "../../core/shortcuts.ts";
import { useShortcut } from "../effects/shortcut.ts";
import { Button } from "../ui/button.tsx";
import { Monogram } from "../ui/monogram.tsx";
import { Popover, PopoverPopup, PopoverTrigger } from "../ui/popover.tsx";
import { Tip } from "../ui/tooltip.tsx";
import { useDirectory } from "./directory.ts";
import { ModelList } from "./model-list.tsx";

/** The shortcut that opens the models. */
const CHOOSE_MODEL = "mod+'";

/** What the model's control is given: the model chosen, who is told of a choice, whether the models are open, and where the focus goes back to. */
export type ModelControlProps = {
	readonly model: string | undefined;
	readonly onChoose: (model: string) => void;
	readonly open: boolean;
	readonly onOpenChange: (open: boolean) => void;
	readonly returnFocus: RefObject<HTMLElement | null>;
};

/** The chip and the card it opens. */
export function ModelControl(props: ModelControlProps): ReactNode {
	const directory = useDirectory();
	const { model } = props;
	useShortcut(CHOOSE_MODEL, () => props.onOpenChange(!props.open));
	const provider = model === undefined ? undefined : providerName(directory, providerOf(model));
	return (
		<Popover open={props.open} onOpenChange={props.onOpenChange}>
			<Tip label="Choose a model" shortcut={shortcutLabel(CHOOSE_MODEL)}>
				<PopoverTrigger
					render={
						<Button
							variant="ghost-muted"
							size="sm"
							className="h-control-sm max-w-[60cqw] min-w-0 shrink justify-start gap-1 px-2 font-normal text-foreground"
							onMouseDown={(event) => event.preventDefault()}
						/>
					}
				>
					{model === undefined || provider === undefined ? (
						<span className="text-muted-foreground">Choose a model</span>
					) : (
						<span className="flex min-w-0 items-center gap-1 whitespace-nowrap">
							<Monogram name={provider} />
							<span className="min-w-0 shrink-[2] truncate text-muted-foreground @max-xl:hidden">{provider}</span>
							<span className="text-muted-foreground/60 @max-xl:hidden">/</span>
							<span className="min-w-0 truncate">{modelLabel(model, directory)}</span>
						</span>
					)}
					<ChevronDown className="-me-0.5 size-3.5 opacity-70" />
				</PopoverTrigger>
			</Tip>
			<PopoverPopup
				side="top"
				align="start"
				sideOffset={10}
				finalFocus={props.returnFocus}
				className="flex w-[min(34rem,calc(100vw-2rem))] flex-col overflow-hidden data-ending-style:scale-95 data-starting-style:scale-95"
			>
				<ModelList
					model={model}
					onChoose={(chosen) => {
						props.onChoose(chosen);
						props.onOpenChange(false);
					}}
				/>
			</PopoverPopup>
		</Popover>
	);
}
