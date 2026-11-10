/**
 * A meter, on Base UI: how full something stands within its bounds — a thin track filled up to its value, in the
 * primary colour, the warning's or the error's as its tone asks — its label and its value told to assistive technology.
 */
import type { ReactNode } from "react";
import { Meter as MeterPrimitive } from "@base-ui/react/meter";
import { cn } from "./cn.ts";

/** Each tone's fill. */
const TONES = { default: "bg-primary", warning: "bg-warning", error: "bg-error" } as const;

/** What a meter takes: its value and its most, what it measures, its value in words, and its tone. */
export type MeterProps = {
	readonly value: number;
	readonly max: number;
	readonly label: string;
	readonly valueText: string;
	readonly tone?: keyof typeof TONES;
	readonly className?: string;
};

/** A meter. */
export function Meter({ value, max, label, valueText, tone = "default", className }: MeterProps): ReactNode {
	return (
		<MeterPrimitive.Root value={Math.min(value, max)} max={max} aria-label={label} getAriaValueText={() => valueText} className={cn("w-full", className)}>
			<MeterPrimitive.Track className="h-1 w-full overflow-hidden rounded-full bg-muted">
				<MeterPrimitive.Indicator className={cn("rounded-full transition-[width] duration-300 motion-reduce:transition-none", TONES[tone])} />
			</MeterPrimitive.Track>
		</MeterPrimitive.Root>
	);
}
