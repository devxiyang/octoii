/**
 * Choosing one of some or several, on Base UI: a group the arrow keys walk, or one each choice of which is checked on
 * its own; each choice a row or a card with a look of its own, shaded by `data-checked` as it is chosen, and the mark
 * it may hold — a dot filled with the primary colour, or a box with a check in it.
 */
import type { ReactNode } from "react";
import { Checkbox as CheckboxPrimitive } from "@base-ui/react/checkbox";
import { CheckboxGroup as CheckboxGroupPrimitive } from "@base-ui/react/checkbox-group";
import { Radio as RadioPrimitive } from "@base-ui/react/radio";
import { RadioGroup as RadioGroupPrimitive } from "@base-ui/react/radio-group";
import { Check } from "lucide-react";
import { cn } from "./cn.ts";

/** A group of choices of which one is chosen, `value`. */
export const RadioGroup = RadioGroupPrimitive;

/** A choice of a radio group: a row or a card, `render` its element, its marks turned as it is chosen. */
export function RadioChoice({ className, ...props }: RadioPrimitive.Root.Props) {
	return <RadioPrimitive.Root className={cn("group/choice outline-none", className)} data-slot="radio-choice" {...props} />;
}

/** A group of choices any of which is chosen, `value` holding them. */
export const CheckboxGroup = CheckboxGroupPrimitive;

/** A choice of a checkbox group, chosen on its own: a row, its marks turned as it is chosen. */
export function CheckboxChoice({ className, ...props }: CheckboxPrimitive.Root.Props) {
	return <CheckboxPrimitive.Root className={cn("group/choice outline-none", className)} data-slot="checkbox-choice" {...props} />;
}

/** The ring of a mark: the input's edge, the primary colour filling it while its choice is chosen. */
const MARK_CLASS =
	"flex size-4 shrink-0 items-center justify-center border border-input transition-colors group-data-checked/choice:border-primary group-data-checked/choice:bg-primary group-data-checked/choice:text-primary-foreground";

/** A radio choice's mark: a ring, a dot in it while its choice is chosen. */
export function RadioDot(): ReactNode {
	return (
		<span aria-hidden className={cn(MARK_CLASS, "rounded-full")}>
			<RadioPrimitive.Indicator className="size-1.5 rounded-full bg-current" />
		</span>
	);
}

/** A checkbox choice's mark: a box, a check in it while its choice is chosen. */
export function CheckboxBox(): ReactNode {
	return (
		<span aria-hidden className={cn(MARK_CLASS, "rounded-[4px]")}>
			<CheckboxPrimitive.Indicator>
				<Check className="size-3" />
			</CheckboxPrimitive.Indicator>
		</span>
	);
}
