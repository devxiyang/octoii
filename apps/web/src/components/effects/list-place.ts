/**
 * A list's place, as its reader stands in it: whether they are at its end, as the list tells while it scrolls, and how
 * to bring them there — the list's own scrolling, which only the list reaches, given to this as its ref; and where they
 * left it, by the key of the row at its top and how far that row stood from the top, kept for the page's life by the
 * list's key — none where they left it at its end — so a list shown again opens where its reader left it.
 */
import { useCallback, useLayoutEffect, useRef, useState } from "react";
import type { LegendListRef } from "@legendapp/list/react";

/** Where a reader left a list: the key of the row at its top, and where that row's top stood from the list's top, in pixels — above it, below nought. */
export type LeftPlace = { readonly key: string; readonly viewOffset: number };

/** Where each list was left, by its key: none for one left at its end. */
const places = new Map<string, LeftPlace>();

/**
 * What gives the list, as its ref; whether the reader is at its end; what it is told as it scrolls; what brings the
 * reader to its end; and where they left it when it was last shown, none where they left it at its end.
 */
export type ListPlace = {
	readonly attach: (list: LegendListRef | null) => void;
	readonly atEnd: boolean;
	readonly onScroll: () => void;
	readonly toEnd: (animated: boolean) => void;
	readonly left: LeftPlace | undefined;
};

/** The place in the list of `key`, the reader at its end till the list tells otherwise; each function the same from one draw to the next. */
export function useListPlace(key: string): ListPlace {
	const list = useRef<LegendListRef | null>(null);
	const [left] = useState(() => places.get(key));
	const [atEnd, setAtEnd] = useState(left === undefined);
	const attach = useCallback((given: LegendListRef | null) => {
		list.current = given;
	}, []);
	const onScroll = useCallback(() => setAtEnd(list.current?.getState().isAtEnd !== false), []);
	const toEnd = useCallback((animated: boolean) => void list.current?.scrollToEnd({ animated }), []);
	// Where the reader leaves the list is read as it goes, before the list itself is let go of.
	useLayoutEffect(
		() => () => {
			const shown = list.current;
			// The list tells how far its top has scrolled past the row's top.
			const anchor = shown === null || shown.getState().isAtEnd ? undefined : shown.anchorVisibleContent({ hold: false });
			if (anchor === undefined) places.delete(key);
			else places.set(key, { key: anchor.key, viewOffset: -anchor.offset });
		},
		[key],
	);
	return { attach, atEnd, onScroll, toEnd, left };
}
