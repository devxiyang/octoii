/**
 * A pill that tells how something stands, tinted by its tone: running, waiting on the person, done, failed, or plain —
 * an icon before its words where it has one.
 */
import type { ReactNode } from "react";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "./cn.ts";

const pill = cva(
	"inline-flex h-control-2xs shrink-0 items-center gap-1 rounded-md px-1.5 text-xs font-medium whitespace-nowrap select-none [&>svg]:size-3 [&>svg]:shrink-0",
	{
		variants: {
			tone: {
				running: "bg-info-surface text-info-foreground",
				waiting: "bg-warning-surface text-warning-foreground",
				done: "bg-success-surface text-success-foreground",
				failed: "bg-error-surface text-error-foreground",
				plain: "bg-accent text-muted-foreground",
			},
		},
		defaultVariants: { tone: "plain" },
	},
);

/** How a pill is tinted. */
export type PillTone = NonNullable<VariantProps<typeof pill>["tone"]>;

/** The pill: its tone, the icon before its words, and its words. */
export function Pill(props: { readonly tone?: PillTone; readonly icon?: ReactNode; readonly children: ReactNode; readonly className?: string }): ReactNode {
	return (
		<span className={cn(pill({ tone: props.tone }), props.className)}>
			{props.icon}
			{props.children}
		</span>
	);
}
