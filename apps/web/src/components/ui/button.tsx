/**
 * Buttons: a size and a look each, declared as variants; its icons sized and tinted with it; pressed, it gives a little.
 * An icon button names what it does in a tip, with its shortcut; a toggle button, on Base UI, stays pressed while what
 * it sets is on. Each renders as a `<button>`, or as the element a Base UI trigger hands it.
 */
import type { ReactElement, ReactNode } from "react";
import { mergeProps } from "@base-ui/react/merge-props";
import { Toggle } from "@base-ui/react/toggle";
import { useRender } from "@base-ui/react/use-render";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "./cn.ts";
import { Tip } from "./tooltip.tsx";

/** A button's looks and sizes. */
export const buttonVariants = cva(
	"[--icon-color:currentColor] relative inline-flex shrink-0 cursor-pointer items-center justify-center gap-2 rounded-control border text-sm font-medium whitespace-nowrap outline-none transition-[box-shadow,scale,background-color] select-none [&:active:not([aria-haspopup])]:scale-[0.97] focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-inset disabled:pointer-events-none disabled:opacity-64 aria-disabled:cursor-not-allowed aria-disabled:opacity-64 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4 [&_svg:not([class*='text-'])]:text-(--icon-color)",
	{
		defaultVariants: { size: "default", variant: "default" },
		variants: {
			size: {
				default: "h-control px-[calc(--spacing(3)-1px)]",
				lg: "h-control-lg px-[calc(--spacing(3.5)-1px)]",
				sm: "h-control-sm gap-1.5 px-[calc(--spacing(2.5)-1px)] text-ui",
				xs: "h-control-xs gap-1 px-[calc(--spacing(2)-1px)] text-xs [&_svg:not([class*='size-'])]:size-3.5",
				compact: "h-control-sm gap-1 rounded-md px-[calc(--spacing(2)-1px)] text-xs [&_svg:not([class*='size-'])]:size-3.5",
				icon: "size-control touch-target",
				"icon-sm": "size-control-sm touch-target",
				"icon-xs": "size-control-xs touch-target rounded-md [&_svg:not([class*='size-'])]:size-3.5",
				"icon-micro": "size-control-2xs touch-target rounded-sm [&_svg:not([class*='size-'])]:size-3",
			},
			variant: {
				default:
					"border-primary bg-primary text-primary-foreground shadow-xs shadow-primary/24 not-disabled:inset-shadow-control-highlight [:active,[data-pressed]]:inset-shadow-control-pressed hover:bg-primary/90 data-pressed:bg-primary/90",
				destructive:
					"border-destructive bg-destructive text-white shadow-xs shadow-destructive/24 not-disabled:inset-shadow-control-highlight hover:bg-destructive/90 data-pressed:bg-destructive/90",
				outline:
					"[--icon-color:var(--muted-foreground)] border-input bg-popover text-foreground shadow-xs/5 hover:bg-accent/50 data-pressed:bg-accent/50 dark:bg-input/32 dark:hover:bg-input/64",
				secondary: "border-transparent bg-secondary text-secondary-foreground hover:bg-secondary/90 data-pressed:bg-secondary/80",
				ghost: "[--icon-color:var(--muted-foreground)] border-transparent text-foreground hover:bg-accent data-pressed:bg-accent data-popup-open:bg-accent",
				"ghost-muted":
					"border-transparent text-muted-foreground hover:bg-accent hover:text-foreground data-pressed:bg-accent data-pressed:text-foreground data-popup-open:bg-accent data-popup-open:text-foreground",
				"ghost-destructive": "border-transparent text-muted-foreground hover:bg-accent hover:text-destructive-foreground data-pressed:bg-accent",
				link: "border-transparent underline-offset-4 hover:underline",
			},
		},
	},
);

/** What a button takes: a `<button>`'s props, its look and size, and the element a trigger renders it as. */
export type ButtonProps = useRender.ComponentProps<"button"> & VariantProps<typeof buttonVariants>;

/** A button. */
export function Button({ className, variant, size, render, ...props }: ButtonProps) {
	const own = {
		className: cn(buttonVariants({ className, size, variant })),
		"data-slot": "button",
		type: render === undefined ? ("button" as const) : undefined,
	};
	return useRender({ defaultTagName: "button", props: mergeProps<"button">(own, props), render });
}

/** What an icon button takes: what it does, for its tip and for assistive technology, its shortcut, and its icon, which a trigger that renders it may give instead. */
export type IconButtonProps = Omit<ButtonProps, "children" | "aria-label"> & {
	readonly label: string;
	readonly shortcut?: string;
	readonly children?: ReactNode;
};

/** A button of an icon alone, its label in a tip with its shortcut. */
export function IconButton({ label, shortcut, size = "icon-sm", variant = "ghost-muted", ...props }: IconButtonProps): ReactElement {
	return (
		<Tip label={label} {...(shortcut === undefined ? {} : { shortcut })}>
			<Button aria-label={label} size={size} variant={variant} {...props} />
		</Tip>
	);
}

/** What a toggle button takes: an icon button's own, whether what it sets is on, and who is told as it turns. */
export type ToggleButtonProps = Omit<IconButtonProps, "onClick"> & { readonly pressed: boolean; readonly onPressedChange: (pressed: boolean) => void };

/** An icon button that stays pressed while what it sets is on, as assistive technology is told; pressed, it shades. */
export function ToggleButton({ pressed, onPressedChange, ...props }: ToggleButtonProps): ReactElement {
	return <Toggle pressed={pressed} onPressedChange={(next) => onPressedChange(next)} render={<IconButton {...props} />} />;
}
