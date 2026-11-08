/** A switch, on Base UI: a track that fills with the primary colour when on, its thumb stretching a little as it is pressed. */
import { Switch as SwitchPrimitive } from "@base-ui/react/switch";
import { cn } from "./cn.ts";

/** A switch. */
export function Switch({ className, ...props }: SwitchPrimitive.Root.Props) {
	return (
		<SwitchPrimitive.Root
			className={cn(
				"inline-flex h-[calc(var(--thumb-size)+2px)] w-[calc(var(--thumb-size)*2-2px)] shrink-0 cursor-pointer items-center rounded-full p-[2px] outline-none transition-[background-color,box-shadow] duration-200 [--thumb-size:--spacing(4)] focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-inset data-checked:bg-primary data-disabled:cursor-not-allowed data-disabled:opacity-64 data-unchecked:bg-input",
				className,
			)}
			data-slot="switch"
			{...props}
		>
			<SwitchPrimitive.Thumb
				className="pointer-events-none block size-[calc(var(--thumb-size)-2px)] shrink-0 origin-left rounded-(--thumb-size) bg-background shadow-sm/5 [transition:translate_.15s,border-radius_.15s,scale_.1s_.1s,transform-origin_.15s] in-[[role=switch]:active]:not-data-disabled:scale-x-110 data-checked:origin-right data-checked:translate-x-[calc(var(--thumb-size)-4px)] dark:data-unchecked:bg-muted-foreground"
				data-slot="switch-thumb"
			/>
		</SwitchPrimitive.Root>
	);
}
