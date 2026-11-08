/**
 * Folding, on Base UI: a trigger that opens and closes what it heads — its chevron turning as it opens — and the panel
 * below it, which stands at its height at once as it opens, what it holds fading in, and is gone at once as it closes:
 * a height that grew would lay the page out again on every frame, and a list that measures what it holds would measure
 * it again on each.
 */
import type { ReactNode } from "react";
import { Collapsible as CollapsiblePrimitive } from "@base-ui/react/collapsible";
import { ChevronRight } from "lucide-react";
import { cn } from "./cn.ts";

/** A fold's root: open or closed, as it is told or as its trigger turns it. */
export const Collapsible = CollapsiblePrimitive.Root;

/** What opens and closes the panel; `render` makes it the row it shows as. */
export function CollapsibleTrigger({ className, ...props }: CollapsiblePrimitive.Trigger.Props) {
	return <CollapsiblePrimitive.Trigger className={cn("group/fold", className)} data-slot="collapsible-trigger" {...props} />;
}

/** A trigger's chevron: pointing on while its panel is closed, down once it opens. */
export function FoldChevron(props: { readonly className?: string }): ReactNode {
	return (
		<ChevronRight
			aria-hidden
			className={cn("size-3.5 shrink-0 transition-transform duration-150 group-data-panel-open/fold:rotate-90 motion-reduce:transition-none", props.className)}
		/>
	);
}

/** The panel: at its height as it opens, what it holds fading in; gone as it closes. */
export function CollapsiblePanel({ className, ...props }: CollapsiblePrimitive.Panel.Props) {
	return (
		<CollapsiblePrimitive.Panel
			className={cn("transition-opacity duration-150 ease-out data-starting-style:opacity-0 motion-reduce:transition-none", className)}
			data-slot="collapsible-panel"
			{...props}
		/>
	);
}
