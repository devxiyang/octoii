/**
 * A command list, on Base UI's autocomplete, in a dialog near the top of the page or a popover of what opens it: a field
 * that searches it, with what may stand beside it; under it the list, in groups whose headings stay as it scrolls, the
 * arrow keys walking it while the field keeps the caret and Enter taking the one highlighted; what it says where
 * nothing is found; and at its foot the hints of its keys. The list is filtered as the field is typed in, or by its
 * owner, `mode="none"`.
 */
import type { ReactNode } from "react";
import { Autocomplete } from "@base-ui/react/autocomplete";
import { Search } from "lucide-react";
import { FINE_POINTER, useMedia } from "../effects/media.ts";
import { cn } from "./cn.ts";
import { Dialog, DialogPopup, DialogTitle } from "./dialog.tsx";
import { Kbd } from "./kbd.tsx";

/** What the dialog takes: whether it is open, who is told it closes, what it is for, its width, and the list. */
export type CommandDialogProps = {
	readonly open: boolean;
	readonly onOpenChange: (open: boolean) => void;
	readonly title: string;
	readonly className?: string;
	readonly children: ReactNode;
};

/** The dialog, its title for assistive technology alone. */
export function CommandDialog(props: CommandDialogProps): ReactNode {
	return (
		<Dialog open={props.open} onOpenChange={props.onOpenChange}>
			<DialogPopup placement="top" className={cn("w-[36rem] max-w-[calc(100vw-2rem)] overflow-hidden", props.className)}>
				<DialogTitle className="sr-only">{props.title}</DialogTitle>
				{props.children}
			</DialogPopup>
		</Dialog>
	);
}

/** What the list's root takes: its groups, each holding its items, and the autocomplete's own. */
export type CommandProps<Item> = Omit<Autocomplete.Root.Props<Item>, "items"> & { readonly items: readonly { readonly items: readonly Item[] }[] };

/** The list's root, open and inline where it is shown, the first of what it holds highlighted from the start. */
export function Command<Item>({ items, ...props }: CommandProps<Item>) {
	return <Autocomplete.Root open inline autoHighlight="always" keepHighlight items={items} {...props} />;
}

/**
 * The search: its icon, the field — which has the focus as the dialog opens where the pointer is fine, and not where it
 * is a finger, as a phone's keys would rise over the list — and what stands at its end.
 */
export function CommandSearch({ aside, className, ...props }: Autocomplete.Input.Props & { readonly aside?: ReactNode }) {
	const fine = useMedia(FINE_POINTER);
	return (
		<label className="flex h-12 items-center gap-2.5 border-b border-foreground/[0.07] px-4">
			<Search className="size-4 shrink-0 text-muted-foreground" />
			<Autocomplete.Input
				autoFocus={fine}
				className={cn("min-w-0 flex-1 bg-transparent text-base outline-none placeholder:text-placeholder", className)}
				{...props}
			/>
			{aside}
		</label>
	);
}

/** The list as it scrolls, with what it says where nothing is found. */
export function CommandList(props: { readonly empty: ReactNode; readonly children: Autocomplete.List.Props["children"] }) {
	return (
		<div className="max-h-[min(28rem,60vh)] overflow-y-auto px-1.5 pb-1.5">
			<Autocomplete.Empty>
				<p className="p-8 text-center text-sm text-muted-foreground">{props.empty}</p>
			</Autocomplete.Empty>
			<Autocomplete.List>{props.children}</Autocomplete.List>
		</div>
	);
}

/** A group of the list: its items under its heading, which stays atop as the group scrolls under it. */
export function CommandGroup<Item>(props: { readonly title: string; readonly items: readonly Item[]; readonly children: (item: Item) => ReactNode }) {
	return (
		<Autocomplete.Group items={[...props.items]}>
			<Autocomplete.GroupLabel className="sticky top-0 z-10 bg-popover/95 px-2.5 pt-2.5 pb-1 text-xs font-medium text-muted-foreground backdrop-blur-sm">
				{props.title}
			</Autocomplete.GroupLabel>
			<Autocomplete.Collection>{props.children}</Autocomplete.Collection>
		</Autocomplete.Group>
	);
}

/** An item of the list, shaded while it is highlighted. */
export function CommandItem({ className, ...props }: Autocomplete.Item.Props) {
	return (
		<Autocomplete.Item
			className={cn("flex cursor-pointer items-center gap-2.5 rounded-md px-2.5 text-sm outline-none data-highlighted:bg-foreground/[0.07]", className)}
			{...props}
		/>
	);
}

/** The hints of the list's keys at its foot: each its caps and what they do — none where the pointer is a finger, as a phone has no keys to press. */
export function CommandHints(props: { readonly hints: readonly { readonly keys: readonly string[]; readonly label: string }[] }): ReactNode {
	return (
		<div className="flex items-center gap-3 border-t border-foreground/[0.07] bg-foreground/[0.025] px-4 py-2.5 text-xs text-muted-foreground pointer-coarse:hidden">
			{props.hints.map((hint) => (
				<span key={hint.label} className="flex items-center gap-1">
					{hint.keys.map((key) => (
						<Kbd key={key}>{key}</Kbd>
					))}
					{hint.label}
				</span>
			))}
		</div>
	);
}
