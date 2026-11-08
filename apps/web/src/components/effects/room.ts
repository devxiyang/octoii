/**
 * Room kept at a list's end for what floats over it: the floating element's height, as it changes, written as
 * `--room` on the element that holds both — so the list's end stands as tall at once, with no draw of the page between
 * — and, where the reader is at the list's end, its scroller followed on to its end, so the last of it rises above what
 * grew, as the composer grows with lines typed into it.
 */
import { type RefObject, useCallback } from "react";

/** A ref to give the floating element: its height kept as `--room` on `holder`, `scroller` followed to its end where `atEnd` holds. */
export function useRoomKept(
	holder: RefObject<HTMLElement | null>,
	scroller: RefObject<HTMLElement | null>,
	atEnd: RefObject<boolean>,
): (element: HTMLElement | null) => (() => void) | undefined {
	return useCallback(
		(element: HTMLElement | null) => {
			if (element === null) return undefined;
			const observer = new ResizeObserver(() => {
				holder.current?.style.setProperty("--room", `${String(Math.ceil(element.getBoundingClientRect().height))}px`);
				const list = scroller.current;
				if (list !== null && atEnd.current) list.scrollTo({ top: list.scrollHeight });
			});
			observer.observe(element);
			return () => observer.disconnect();
		},
		[holder, scroller, atEnd],
	);
}
