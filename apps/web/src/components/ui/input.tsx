/**
 * A text field, on Base UI: a box with a faint edge that rings in the primary colour while it is focused; the bare
 * variant leaves the box to what holds it, such as a search row.
 */
import { Input as InputPrimitive } from "@base-ui/react/input";
import { cn } from "./cn.ts";

/** What a text field takes: an input's props, its size, and its look: a box, or bare, the box left to what holds it. */
export type InputProps = Omit<InputPrimitive.Props, "size"> & { readonly size?: "sm" | "default"; readonly variant?: "default" | "bare" };

/** A text field. */
export function Input({ className, size = "default", variant = "default", ...props }: InputProps) {
	const boxed = variant === "default";
	return (
		<InputPrimitive
			className={cn(
				"w-full min-w-0 bg-transparent text-ui outline-none placeholder:text-faint-foreground [&::-webkit-search-cancel-button]:appearance-none",
				boxed &&
					"rounded-md border border-input px-[calc(--spacing(3)-1px)] focus-visible:border-ring focus-visible:ring-1 focus-visible:ring-ring disabled:opacity-64",
				boxed && (size === "sm" ? "h-control-sm" : "h-control"),
				className,
			)}
			data-slot="input"
			{...props}
		/>
	);
}

/** What a field takes: what it is for, and a text field's own. */
export type FieldProps = Omit<InputProps, "aria-label"> & { readonly label: string };

/** A text field named for assistive technology; Enter in it submits the form it is in, as any field's does. */
export function Field({ label, ...props }: FieldProps) {
	return <Input aria-label={label} {...props} />;
}
