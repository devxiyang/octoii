/**
 * A slider, on Base UI: its value as a percentage in a small tile, a thin track filled in the primary colour up to a
 * round thumb; for a setting along a range.
 */
import { Slider as SliderPrimitive } from "@base-ui/react/slider";

/** What a slider takes: its value, its bounds, its step, who is told of a change, and what it is for. */
export type SliderProps = {
	readonly value: number;
	readonly min: number;
	readonly max: number;
	readonly step?: number;
	readonly onValueChange: (value: number) => void;
	readonly label: string;
};

/** A slider of a percentage. */
export function Slider(props: SliderProps) {
	return (
		<SliderPrimitive.Root
			value={props.value}
			min={props.min}
			max={props.max}
			step={props.step ?? 1}
			onValueChange={(value) => props.onValueChange(typeof value === "number" ? value : (value[0] ?? props.min))}
			className="flex items-center gap-3"
			aria-label={props.label}
		>
			<SliderPrimitive.Value className="min-w-12 rounded bg-muted px-1.5 py-0.5 text-center font-mono text-xs text-muted-foreground tabular-nums">
				{(_, value) => `${String(value[0] ?? props.value)}%`}
			</SliderPrimitive.Value>
			<SliderPrimitive.Control className="flex h-5 w-36 cursor-pointer items-center">
				<SliderPrimitive.Track className="h-1 w-full rounded-full bg-input">
					<SliderPrimitive.Indicator className="rounded-full bg-primary" />
					<SliderPrimitive.Thumb className="size-4 rounded-full border border-border bg-background shadow-sm outline-none focus-visible:ring-2 focus-visible:ring-ring" />
				</SliderPrimitive.Track>
			</SliderPrimitive.Control>
		</SliderPrimitive.Root>
	);
}
