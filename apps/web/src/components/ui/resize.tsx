/**
 * Dragging a column's or a drawer's edge to make it wider or narrower, taller or shorter: the size follows the pointer
 * while it is held, within its bounds, and is kept once it is let go; until the kept size comes back from where it is
 * kept, the dragged one shows.
 */
import { type ReactNode, useState } from "react";

/**
 * A pane's bounds, and which way its edge grows it: `right` for a column on the left, `left` for one on the right, `up`
 * for a drawer at the bottom.
 */
export type Bounds = { readonly min: number; readonly max: number; readonly grows: "right" | "left" | "up" };

/** A drag under way or just let go: the size it started from, the size now, whether it is held, and where it began. */
type Drag = { readonly from: number; readonly size: number; readonly held: boolean; readonly start: number };

/** Each way's edge: where it sits, its cursor and its orientation. */
const EDGES: Readonly<Record<Bounds["grows"], { readonly className: string; readonly orientation: "vertical" | "horizontal" }>> = {
	right: { className: "inset-y-0 -right-0.75 w-1.5 cursor-col-resize", orientation: "vertical" },
	left: { className: "inset-y-0 -left-0.75 w-1.5 cursor-col-resize", orientation: "vertical" },
	up: { className: "inset-x-0 -top-0.75 h-1.5 cursor-row-resize", orientation: "horizontal" },
};

/** The size a pane shows, and the edge that drags it. */
export function useDragSize(kept: number, bounds: Bounds, keep: (size: number) => void): { readonly size: number; readonly edge: ReactNode } {
	const [drag, setDrag] = useState<Drag | undefined>(undefined);
	const size = drag !== undefined && (drag.held || kept === drag.from) ? drag.size : kept;
	const along = (event: { readonly clientX: number; readonly clientY: number }): number => (bounds.grows === "up" ? event.clientY : event.clientX);
	const sizeAt = (position: number, from: Drag): number => {
		const moved = bounds.grows === "right" ? position - from.start : from.start - position;
		return Math.round(Math.min(bounds.max, Math.max(bounds.min, from.from + moved)));
	};
	const { className, orientation } = EDGES[bounds.grows];
	const edge = (
		<div
			role="separator"
			aria-orientation={orientation}
			aria-label="Drag to resize"
			onPointerDown={(event) => {
				event.currentTarget.setPointerCapture(event.pointerId);
				setDrag({ from: kept, size: kept, held: true, start: along(event) });
			}}
			onPointerMove={(event) => {
				if (drag?.held === true) setDrag({ ...drag, size: sizeAt(along(event), drag) });
			}}
			onPointerUp={(event) => {
				if (drag?.held !== true) return;
				const final = sizeAt(along(event), drag);
				setDrag({ ...drag, size: final, held: false });
				if (final !== kept) keep(final);
			}}
			className={`absolute z-20 bg-primary ${className} ${drag?.held === true ? "opacity-40" : "opacity-0 hover:opacity-30"}`}
		/>
	);
	return { size, edge };
}
