/**
 * A list's end, as its reader stands to it: whether they are at it, as the list tells while it scrolls, and how to
 * bring them there — the list's own scrolling, which only the list itself reaches, given to this as the list's ref.
 */
import { useCallback, useRef, useState } from "react";
import type { LegendListRef } from "@legendapp/list/react";

/** What gives the list, as its ref; whether the reader is at its end; what it is told as it scrolls; and what brings the reader to its end. */
export type ListEnd = {
	readonly attach: (list: LegendListRef | null) => void;
	readonly atEnd: boolean;
	readonly onScroll: () => void;
	readonly toEnd: (animated: boolean) => void;
};

/** A list's end, the reader at it till the list tells otherwise; each function the same from one draw to the next. */
export function useListEnd(): ListEnd {
	const list = useRef<LegendListRef | null>(null);
	const [atEnd, setAtEnd] = useState(true);
	const attach = useCallback((given: LegendListRef | null) => {
		list.current = given;
	}, []);
	const onScroll = useCallback(() => setAtEnd(list.current?.getState().isAtEnd !== false), []);
	const toEnd = useCallback((animated: boolean) => void list.current?.scrollToEnd({ animated }), []);
	return { attach, atEnd, onScroll, toEnd };
}
