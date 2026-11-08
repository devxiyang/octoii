/**
 * A choice of a few, side by side, on Base UI's radio group: each a segment of one track, its words in its middle, the
 * chosen one raised on it as a pill; the arrow keys walk them, as a radio group's do.
 */
import type { ReactNode } from "react";
import { Radio } from "@base-ui/react/radio";
import { RadioGroup } from "@base-ui/react/radio-group";
import { cn } from "./cn.ts";

/** A segment: the value it chooses, its words, and whether it may not be chosen now. */
export type Segment<Value extends string> = { readonly value: Value; readonly label: ReactNode; readonly disabled?: boolean };

/** The segments of `items`, `value` chosen, its label for assistive technology; `onValueChange` told of another. */
export function Segmented<Value extends string>(props: {
	readonly label: string;
	readonly value: Value;
	readonly onValueChange: (value: Value) => void;
	readonly items: readonly Segment<Value>[];
	readonly className?: string;
}): ReactNode {
	return (
		<RadioGroup
			aria-label={props.label}
			value={props.value}
			onValueChange={(value) => {
				const chosen = props.items.find((item) => item.value === value);
				if (chosen !== undefined) props.onValueChange(chosen.value);
			}}
			className={cn("grid auto-cols-fr grid-flow-col gap-0.5 rounded-lg bg-accent p-0.5", props.className)}
		>
			{props.items.map((item) => (
				<Radio.Root
					key={item.value}
					value={item.value}
					disabled={item.disabled === true}
					className="inline-flex h-control-sm min-w-0 items-center justify-center rounded-md px-2.5 text-ui text-muted-foreground outline-none transition-[background-color,color,box-shadow] duration-150 hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring/70 data-checked:bg-background data-checked:text-foreground data-checked:shadow-panel data-disabled:pointer-events-none data-disabled:opacity-50 motion-reduce:transition-none"
				>
					<span className="min-w-0 truncate">{item.label}</span>
				</Radio.Root>
			))}
		</RadioGroup>
	);
}
