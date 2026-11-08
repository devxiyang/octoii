/** An icon on a small tile, a tint behind it and no line around it, as a card's mark sits before its title. */
import type { ReactNode } from "react";
import { cn } from "./cn.ts";

/** The tile, its icon inside. */
export function IconTile(props: { readonly children: ReactNode; readonly className?: string }): ReactNode {
	return (
		<span className={cn("flex size-6 shrink-0 items-center justify-center rounded-md bg-muted text-muted-foreground [&>svg]:size-3.5", props.className)}>
			{props.children}
		</span>
	);
}
