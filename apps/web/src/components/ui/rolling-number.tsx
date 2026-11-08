/**
 * A number whose digits roll to each new value, as an odometer's do — still where the person asks for less motion —
 * written in the interface's language as `format` says.
 */
import type { ReactNode } from "react";
import NumberFlow, { type Format } from "@number-flow/react";
import { NUMBERS_LOCALE } from "../../core/numbers.ts";
import { cn } from "./cn.ts";

/** The number, `value`, as `format` writes it. */
export function RollingNumber(props: { readonly value: number; readonly format?: Format; readonly className?: string }): ReactNode {
	return (
		<NumberFlow
			value={props.value}
			locales={NUMBERS_LOCALE}
			{...(props.format === undefined ? {} : { format: props.format })}
			className={cn("tabular-nums", props.className)}
		/>
	);
}
