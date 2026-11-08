/**
 * Tooltips: one provider for the page, so moving between triggers shows the next at once; and a tip over a control, its
 * words and its shortcut, a key a cap, on the popover's surface.
 */
import type { ReactElement, ReactNode } from "react";
import { Tooltip as TooltipPrimitive } from "@base-ui/react/tooltip";
import { cn } from "./cn.ts";
import { Kbd, KbdGroup } from "./kbd.tsx";

/** The page's tooltips' provider: a short delay, none between neighbours. */
export function TooltipProvider(props: { readonly children: ReactNode }) {
	return (
		<TooltipPrimitive.Provider delay={500} closeDelay={0}>
			{props.children}
		</TooltipPrimitive.Provider>
	);
}

/** A tooltip's popup: on the popover's surface, small, its edge catching the light. */
export function TooltipPopup({
	className,
	side = "top",
	align = "center",
	sideOffset = 4,
	children,
	...props
}: TooltipPrimitive.Popup.Props & {
	readonly side?: TooltipPrimitive.Positioner.Props["side"];
	readonly align?: TooltipPrimitive.Positioner.Props["align"];
	readonly sideOffset?: number;
}) {
	return (
		<TooltipPrimitive.Portal>
			<TooltipPrimitive.Positioner
				side={side}
				align={align}
				sideOffset={sideOffset}
				collisionPadding={5}
				className="pointer-events-none z-[140] max-w-(--available-width)"
				data-slot="tooltip-positioner"
			>
				<TooltipPrimitive.Popup
					className={cn(
						"relative flex max-w-80 origin-(--transform-origin) rounded-md border bg-popover text-xs leading-snug text-balance text-popover-foreground shadow-md/5 transition-[scale,opacity] wrap-anywhere data-ending-style:scale-98 data-ending-style:opacity-0 data-instant:duration-0 data-starting-style:scale-98 data-starting-style:opacity-0",
						className,
					)}
					data-slot="tooltip-popup"
					{...props}
				>
					<div className="flex min-w-0 items-center gap-2 px-2 py-1">{children}</div>
				</TooltipPrimitive.Popup>
			</TooltipPrimitive.Positioner>
		</TooltipPrimitive.Portal>
	);
}

/** A tip over `children`, the one element it describes: its words, and its shortcut where it has one, a key a cap. */
export function Tip(props: {
	readonly label: ReactNode;
	readonly shortcut?: string;
	readonly side?: TooltipPrimitive.Positioner.Props["side"];
	readonly children: ReactElement;
}) {
	return (
		<TooltipPrimitive.Root>
			<TooltipPrimitive.Trigger render={props.children} />
			<TooltipPopup {...(props.side === undefined ? {} : { side: props.side })}>
				<span>{props.label}</span>
				{props.shortcut === undefined ? null : (
					<KbdGroup>
						{[...props.shortcut].map((key, index) => (
							// A shortcut's keys never move, so where each stands is its key.
							<Kbd key={`${String(index)}${key}`}>{key}</Kbd>
						))}
					</KbdGroup>
				)}
			</TooltipPopup>
		</TooltipPrimitive.Root>
	);
}
