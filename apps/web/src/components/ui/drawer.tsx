/**
 * Drawers, on Base UI: a panel that slides in from the page's left edge over a veil, and goes as it is swiped back to
 * that edge, as a press outside it or Escape closes it — the veil fading as it is swiped — and that a swipe in from
 * the edge opens; at once where the person asks for less motion. It keeps clear of the screen's own edges, as a notch
 * or the bar at a phone's foot.
 */
import { Drawer as DrawerPrimitive } from "@base-ui/react/drawer";
import { cn } from "./cn.ts";

/** A drawer's root: swiped to the left, to the edge it came from, to close. */
export function Drawer(props: Omit<DrawerPrimitive.Root.Props, "swipeDirection">) {
	return <DrawerPrimitive.Root swipeDirection="left" {...props} />;
}

/** A drawer's title, for assistive technology where none shows. */
export const DrawerTitle = DrawerPrimitive.Title;

/** The page's left edge, which a drawer is swiped in from by touch. */
export function DrawerSwipeArea({ className, ...props }: DrawerPrimitive.SwipeArea.Props) {
	return <DrawerPrimitive.SwipeArea className={cn("fixed inset-y-0 left-0 z-20 w-3 pointer-fine:hidden", className)} {...props} />;
}

/** A drawer's panel over its veil, from the page's left edge. */
export function DrawerPopup({ className, ...props }: DrawerPrimitive.Popup.Props) {
	return (
		<DrawerPrimitive.Portal>
			<DrawerPrimitive.Backdrop
				className="dialog-backdrop fixed inset-0 z-40 opacity-[calc(1-var(--drawer-swipe-progress,0))] transition-opacity duration-[450ms] ease-[cubic-bezier(0.32,0.72,0,1)] data-ending-style:opacity-0 data-ending-style:duration-[calc(var(--drawer-swipe-strength,1)*400ms)] data-starting-style:opacity-0 data-swiping:duration-0 motion-reduce:transition-none"
				data-slot="drawer-backdrop"
			/>
			<DrawerPrimitive.Viewport className="fixed inset-0 z-40 flex items-stretch justify-start" data-slot="drawer-viewport">
				<DrawerPrimitive.Popup
					className={cn(
						"flex h-full w-[min(20rem,85vw)] flex-col overflow-hidden pt-[env(safe-area-inset-top)] pb-[env(safe-area-inset-bottom)] pl-[env(safe-area-inset-left)] shadow-dialog outline-none [transform:translateX(var(--drawer-swipe-movement-x,0px))] transition-transform duration-[450ms] ease-[cubic-bezier(0.32,0.72,0,1)] data-ending-style:[transform:translateX(-100%)] data-ending-style:duration-[calc(var(--drawer-swipe-strength,1)*400ms)] data-starting-style:[transform:translateX(-100%)] data-swiping:select-none data-swiping:duration-0 motion-reduce:transition-none",
						className,
					)}
					data-slot="drawer-popup"
					{...props}
				/>
			</DrawerPrimitive.Viewport>
		</DrawerPrimitive.Portal>
	);
}
