/** A key, as a shortcut names it, on a faint cap; and keys side by side. */
import type { ComponentProps } from "react";
import { cn } from "./cn.ts";

/** One key. */
export function Kbd({ className, ...props }: ComponentProps<"kbd">) {
	return (
		<kbd
			className={cn(
				"pointer-events-none inline-flex h-control-2xs min-w-control-2xs items-center justify-center gap-1 rounded bg-foreground/[0.07] px-1 font-sans text-xs font-medium text-muted-foreground select-none [&_svg:not([class*='size-'])]:size-3",
				className,
			)}
			data-slot="kbd"
			{...props}
		/>
	);
}

/** Keys pressed together, a cap each. */
export function KbdGroup({ className, ...props }: ComponentProps<"kbd">) {
	return <kbd className={cn("inline-flex items-center gap-1", className)} data-slot="kbd-group" {...props} />;
}
