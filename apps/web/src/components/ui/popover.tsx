/**
 * Popovers, on Base UI: a card a trigger opens beside it, floating over the page, scaling and fading in from where it
 * opens and out again — at once where the person asks for less motion — gone while what opened it is hidden; Escape
 * and a click outside close it, the focus going back to its trigger.
 */
import { Popover as PopoverPrimitive } from "@base-ui/react/popover";
import { cn } from "./cn.ts";

/** A popover's root. */
export const Popover = PopoverPrimitive.Root;

/** What opens a popover; `render` makes it the button it shows as. */
export function PopoverTrigger(props: PopoverPrimitive.Trigger.Props) {
	return <PopoverPrimitive.Trigger data-slot="popover-trigger" {...props} />;
}

/** Where a popover sits against what opened it. */
type Placement = {
	readonly side?: PopoverPrimitive.Positioner.Props["side"];
	readonly align?: PopoverPrimitive.Positioner.Props["align"];
	readonly sideOffset?: number;
};

/** A popover's card, within the room the window leaves it. */
export function PopoverPopup({ className, side = "bottom", align = "end", sideOffset = 6, ...props }: PopoverPrimitive.Popup.Props & Placement) {
	return (
		<PopoverPrimitive.Portal>
			<PopoverPrimitive.Positioner
				side={side}
				align={align}
				sideOffset={sideOffset}
				collisionPadding={8}
				className="z-[120] data-anchor-hidden:invisible"
				data-slot="popover-positioner"
			>
				<PopoverPrimitive.Popup
					className={cn(
						"floating max-h-(--available-height) origin-(--transform-origin) overflow-y-auto rounded-lg outline-none transition-[scale,opacity] duration-150 data-ending-style:scale-98 data-ending-style:opacity-0 data-starting-style:scale-98 data-starting-style:opacity-0 motion-reduce:transition-none",
						className,
					)}
					data-slot="popover-popup"
					{...props}
				/>
			</PopoverPrimitive.Positioner>
		</PopoverPrimitive.Portal>
	);
}
