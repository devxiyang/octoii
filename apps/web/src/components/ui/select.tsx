/**
 * A select, on Base UI: a trigger like an outline button naming the choice, its popup floating as a menu's does over the
 * trigger, the chosen item checked; for a setting with a few named values.
 */
import { Select as SelectPrimitive } from "@base-ui/react/select";
import { Check, ChevronsUpDown } from "lucide-react";
import { cn } from "./cn.ts";

/** A choice of a select: its value and what it shows. */
export type SelectItem<Value extends string> = { readonly value: Value; readonly label: string };

/** What a select takes: its choices, the one chosen, who is told of another, and what it is for. */
export type SelectProps<Value extends string> = {
	readonly items: readonly SelectItem<Value>[];
	readonly value: Value;
	readonly onValueChange: (value: Value) => void;
	readonly label: string;
	readonly className?: string;
};

/** How a control that picks one of some values reads, closed: the value chosen, and the mark that opens the others. */
export const PICKER_TRIGGER =
	"flex h-control min-w-36 cursor-pointer items-center justify-between gap-2 rounded-md border border-input px-2.5 text-ui text-foreground outline-none select-none hover:bg-accent focus-visible:border-ring focus-visible:ring-1 focus-visible:ring-ring data-popup-open:bg-accent";

/** A select of a few named values. */
export function Select<Value extends string>(props: SelectProps<Value>) {
	return (
		<SelectPrimitive.Root
			items={props.items}
			value={props.value}
			onValueChange={(value) => {
				const chosen = props.items.find((item) => item.value === value);
				if (chosen !== undefined) props.onValueChange(chosen.value);
			}}
		>
			<SelectPrimitive.Trigger aria-label={props.label} className={cn(PICKER_TRIGGER, props.className)} data-slot="select-trigger">
				<SelectPrimitive.Value className="truncate" />
				<SelectPrimitive.Icon className="text-muted-foreground">
					<ChevronsUpDown className="size-3.5" />
				</SelectPrimitive.Icon>
			</SelectPrimitive.Trigger>
			<SelectPrimitive.Portal>
				<SelectPrimitive.Positioner sideOffset={4} className="z-[130] outline-none select-none" data-slot="select-positioner">
					<SelectPrimitive.Popup
						className="floating min-w-(--anchor-width) origin-(--transform-origin) rounded-md outline-none transition-[scale,opacity] duration-100 data-ending-style:scale-98 data-ending-style:opacity-0 data-starting-style:scale-98 data-starting-style:opacity-0 data-[side=none]:data-starting-style:scale-100 data-[side=none]:data-starting-style:opacity-100"
						data-slot="select-popup"
					>
						<SelectPrimitive.List className="max-h-(--available-height) overflow-y-auto p-1">
							{props.items.map((item) => (
								<SelectPrimitive.Item
									key={item.value}
									value={item.value}
									className="grid min-h-control-sm cursor-default grid-cols-[1fr_1rem] items-center gap-3 rounded-sm px-2 py-1 text-ui outline-none select-none data-highlighted:bg-accent"
								>
									<SelectPrimitive.ItemText>{item.label}</SelectPrimitive.ItemText>
									<SelectPrimitive.ItemIndicator>
										<Check className="size-4" />
									</SelectPrimitive.ItemIndicator>
								</SelectPrimitive.Item>
							))}
						</SelectPrimitive.List>
					</SelectPrimitive.Popup>
				</SelectPrimitive.Positioner>
			</SelectPrimitive.Portal>
		</SelectPrimitive.Root>
	);
}
