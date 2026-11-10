/**
 * Menus, on Base UI: a dropdown that a trigger opens and a context menu that a right click opens at the pointer, both
 * floating over the page, with items that carry an icon or a shortcut, groups of which one is chosen — a check at its
 * end — lines between, and submenus an item opens beside it.
 */
import type { ComponentProps } from "react";
import { ContextMenu as ContextMenuPrimitive } from "@base-ui/react/context-menu";
import { Menu as MenuPrimitive } from "@base-ui/react/menu";
import { Check, ChevronRight } from "lucide-react";
import { renderClosingPositioner } from "./closing-positioner.tsx";
import { cn } from "./cn.ts";

/** A dropdown menu's root. */
export const Menu = MenuPrimitive.Root;

/** What opens a dropdown menu; `render` makes it the button it shows as. */
export function MenuTrigger(props: MenuPrimitive.Trigger.Props) {
	return <MenuPrimitive.Trigger data-slot="menu-trigger" {...props} />;
}

/** A context menu's root. */
export const ContextMenu = ContextMenuPrimitive.Root;

/** The area a right click opens a context menu on. */
export function ContextMenuTrigger(props: ContextMenuPrimitive.Trigger.Props) {
	return <ContextMenuPrimitive.Trigger data-slot="context-menu-trigger" {...props} />;
}

/** Where a menu's popup sits against what opened it. */
type Placement = {
	readonly side?: MenuPrimitive.Positioner.Props["side"];
	readonly align?: MenuPrimitive.Positioner.Props["align"];
	readonly sideOffset?: number;
	readonly alignOffset?: number;
};

/** A menu popup's own look: floating over the page, a little scale and fade in and out, its items scrolling within the space it has. */
const POPUP_CLASS =
	"floating relative flex max-w-[calc(100vw-2rem)] min-w-[min(10rem,calc(100vw-2rem))] origin-(--transform-origin) rounded-md outline-none transition-[scale,opacity] duration-100 data-ending-style:scale-98 data-ending-style:opacity-0 data-starting-style:scale-98 data-starting-style:opacity-0";

/** A dropdown menu's popup. */
export function MenuPopup({
	className,
	children,
	side = "bottom",
	align = "start",
	sideOffset = 4,
	alignOffset,
	...props
}: MenuPrimitive.Popup.Props & Placement) {
	return (
		<MenuPrimitive.Portal>
			<MenuPrimitive.Positioner
				side={side}
				align={align}
				sideOffset={sideOffset}
				{...(alignOffset === undefined ? {} : { alignOffset })}
				className="z-[130]"
				data-slot="menu-positioner"
				render={renderClosingPositioner}
			>
				<MenuPrimitive.Popup className={cn(POPUP_CLASS, className)} data-slot="menu-popup" {...props}>
					<div className="max-h-(--available-height) w-full overflow-y-auto p-1">{children}</div>
				</MenuPrimitive.Popup>
			</MenuPrimitive.Positioner>
		</MenuPrimitive.Portal>
	);
}

/** A context menu's popup, at the pointer. */
export function ContextMenuPopup({ className, children, ...props }: MenuPrimitive.Popup.Props) {
	return (
		<ContextMenuPrimitive.Portal>
			<ContextMenuPrimitive.Positioner className="z-[130]" data-slot="menu-positioner">
				<ContextMenuPrimitive.Popup className={cn(POPUP_CLASS, className)} data-slot="menu-popup" {...props}>
					<div className="max-h-(--available-height) w-full overflow-y-auto p-1">{children}</div>
				</ContextMenuPrimitive.Popup>
			</ContextMenuPrimitive.Positioner>
		</ContextMenuPrimitive.Portal>
	);
}

/** An item's own look: a row that shades as it is highlighted, its icon muted and sized. */
const ITEM_CLASS =
	"flex min-h-control-sm cursor-default items-center gap-2 rounded-sm px-2 py-1 text-ui text-foreground outline-none select-none data-disabled:pointer-events-none data-disabled:opacity-64 data-highlighted:bg-accent data-highlighted:text-foreground [&>svg]:pointer-events-none [&>svg]:-mx-0.5 [&>svg]:shrink-0 [&>svg:not([class*='opacity-'])]:opacity-80 [&>svg:not([class*='size-'])]:size-4 [&>svg:not([class*='text-'])]:text-muted-foreground";

/** A menu's item; `variant="destructive"` reads red. */
export function MenuItem({ className, variant = "default", ...props }: MenuPrimitive.Item.Props & { readonly variant?: "default" | "destructive" }) {
	return (
		<MenuPrimitive.Item
			className={cn(
				ITEM_CLASS,
				"data-[variant=destructive]:text-error-foreground data-[variant=destructive]:[&>svg:not([class*='text-'])]:text-current",
				className,
			)}
			data-slot="menu-item"
			data-variant={variant}
			{...props}
		/>
	);
}

/** An item's label, cut short where it is long. */
export function MenuItemLabel({ className, ...props }: ComponentProps<"span">) {
	return <span className={cn("min-w-0 flex-1 truncate", className)} data-slot="menu-item-label" {...props} />;
}

/** An item's shortcut, on its right. */
export function MenuShortcut({ className, ...props }: ComponentProps<"kbd">) {
	return <kbd className={cn("ms-auto font-sans text-xs tracking-widest text-muted-foreground", className)} data-slot="menu-shortcut" {...props} />;
}

/** A group of items of which one is chosen, `value`, each told of as it is chosen. */
export function MenuRadioGroup(props: MenuPrimitive.RadioGroup.Props) {
	return <MenuPrimitive.RadioGroup data-slot="menu-radio-group" {...props} />;
}

/** An item of a radio group: a row like any item's, a check at its end while it is the one chosen; choosing it closes the menu. */
export function MenuRadioItem({ className, children, ...props }: MenuPrimitive.RadioItem.Props) {
	return (
		<MenuPrimitive.RadioItem closeOnClick className={cn(ITEM_CLASS, className)} data-slot="menu-radio-item" {...props}>
			{children}
			<MenuPrimitive.RadioItemIndicator keepMounted className="ms-auto flex size-4 shrink-0 items-center justify-center data-unchecked:invisible">
				<Check className="size-4" />
			</MenuPrimitive.RadioItemIndicator>
		</MenuPrimitive.RadioItem>
	);
}

/** A line between groups. */
export function MenuSeparator({ className, ...props }: MenuPrimitive.Separator.Props) {
	return <MenuPrimitive.Separator className={cn("mx-2 my-1 h-px bg-border", className)} data-slot="menu-separator" {...props} />;
}

/** A submenu's root, within a menu. */
export const MenuSub = MenuPrimitive.SubmenuRoot;

/** The item that opens a submenu beside it: an item's row, a chevron at its end. */
export function MenuSubTrigger({ className, children, ...props }: MenuPrimitive.SubmenuTrigger.Props) {
	return (
		<MenuPrimitive.SubmenuTrigger className={cn(ITEM_CLASS, "data-popup-open:bg-accent", className)} data-slot="menu-sub-trigger" {...props}>
			{children}
			<ChevronRight className="ms-auto size-3.5" />
		</MenuPrimitive.SubmenuTrigger>
	);
}
