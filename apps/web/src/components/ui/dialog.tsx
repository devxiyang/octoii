/**
 * Dialogs, on Base UI: a light veil over the page and a popup on the dialog's glass that scales and fades in and out,
 * as tall as its content and centred, near the top, or filling the room it has up to its own most; Escape and a click
 * outside close it. An alert dialog asks what the person must answer, and only its buttons and Escape close it.
 */
import { AlertDialog as AlertDialogPrimitive } from "@base-ui/react/alert-dialog";
import { Dialog as DialogPrimitive } from "@base-ui/react/dialog";
import { cn } from "./cn.ts";

/** A dialog's root. */
export const Dialog = DialogPrimitive.Root;

/** An alert dialog's root: its popup the dialog's own. */
export const AlertDialog = AlertDialogPrimitive.Root;

/** A dialog's title, for assistive technology where none shows. */
export const DialogTitle = DialogPrimitive.Title;

/** A dialog's words under its title, which assistive technology reads with it. */
export const DialogDescription = DialogPrimitive.Description;

/** A button that closes its dialog; `render` makes it the button it shows as. */
export const DialogClose = DialogPrimitive.Close;

/**
 * Where a dialog's popup sits: centred, as tall as its content; near the top, for a palette; or filling the room, for
 * settings — the whole screen where the page is narrow, as a phone's.
 */
const PLACEMENTS = {
	center: "grid-rows-[1fr_auto_1fr] sm:p-6 lg:p-10",
	top: "grid-rows-[12vh_auto_1fr]",
	fill: "grid-rows-[1fr_minmax(0,100%)_1fr] p-0 md:p-6 lg:p-10",
} as const;

/** A dialog's popup over its veil. */
export function DialogPopup({ className, placement = "center", ...props }: DialogPrimitive.Popup.Props & { readonly placement?: keyof typeof PLACEMENTS }) {
	return (
		<DialogPrimitive.Portal>
			<DialogPrimitive.Backdrop
				className="dialog-backdrop fixed inset-0 z-50 transition-all duration-200 data-ending-style:opacity-0 data-starting-style:opacity-0"
				data-slot="dialog-backdrop"
			/>
			<DialogPrimitive.Viewport className={cn("fixed inset-0 z-50 grid justify-items-center p-4", PLACEMENTS[placement])} data-slot="dialog-viewport">
				<DialogPrimitive.Popup
					className={cn(
						"dialog-glass relative row-start-2 flex max-h-full min-h-0 w-full min-w-0 flex-col rounded-2xl text-popover-foreground outline-none transition-[scale,opacity] duration-200 ease-in-out data-ending-style:scale-98 data-ending-style:opacity-0 data-starting-style:scale-98 data-starting-style:opacity-0",
						className,
					)}
					data-slot="dialog-popup"
					{...props}
				/>
			</DialogPrimitive.Viewport>
		</DialogPrimitive.Portal>
	);
}
