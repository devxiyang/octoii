/**
 * Rows that move glide to their place: each row of a list — an element of it with a `data-glide` key — has where it
 * stands in the list kept, as the list is drawn and as anything in it changes its size, a section folded or the list
 * made wider; drawn in another order, a row that stands elsewhere now, in its section or another, is set back where it
 * stood and glides to its place, by transform alone. A row new to the list, or hidden where it stood, does not glide:
 * it fades in as it arrives. Where the person asks for less motion, nothing glides.
 */
import { type RefObject, useLayoutEffect, useRef } from "react";

/** How long a row glides, in milliseconds, and how it eases in. */
const GLIDE: KeyframeAnimationOptions = { duration: 260, easing: "cubic-bezier(0.2, 0, 0, 1)" };

/** Has the rows of `list` glide to their places as it is drawn in another `order` — its rows' keys, in turn. */
export function useGlide(list: RefObject<HTMLElement | null>, order: string): void {
	const kept = useRef<ReadonlyMap<string, number>>(new Map());
	useLayoutEffect(() => {
		const element = list.current;
		if (element === null) return undefined;
		const places = placesIn(element);
		if (!window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
			for (const [row, top] of places) {
				const was = kept.current.get(row.dataset["glide"] ?? "");
				if (was !== undefined && Math.abs(was - top) >= 1) glide(row, was - top);
			}
		}
		kept.current = new Map([...places].map(([row, top]) => [row.dataset["glide"] ?? "", top]));
		// What changes its size between drawings moves the rows after it: where each stands is kept again then.
		const resized = new ResizeObserver(() => {
			kept.current = new Map([...placesIn(element)].map(([row, top]) => [row.dataset["glide"] ?? "", top]));
		});
		resized.observe(element);
		for (const child of element.querySelectorAll(":scope > *, [data-glide]")) resized.observe(child);
		return () => resized.disconnect();
	}, [list, order]);
}

/** Where each row of `list` that is shown stands in it, from its top, transforms aside. */
function placesIn(list: HTMLElement): ReadonlyMap<HTMLElement, number> {
	const places = new Map<HTMLElement, number>();
	for (const row of list.querySelectorAll<HTMLElement>("[data-glide]")) {
		if (row.offsetParent !== null) places.set(row, topIn(list, row));
	}
	return places;
}

/** How far down `list` the element `row` stands, as laid out, by the offsets on the way up to the list. */
function topIn(list: HTMLElement, row: HTMLElement): number {
	let top = 0;
	for (let at: Element | null = row; at instanceof HTMLElement && at !== list; at = at.offsetParent) top += at.offsetTop;
	return top;
}

/** Sets `row` back by `offset` pixels and lets it glide to its place. */
function glide(row: HTMLElement, offset: number): void {
	row.animate([{ transform: `translateY(${String(offset)}px)` }, { transform: "none" }], GLIDE);
}
