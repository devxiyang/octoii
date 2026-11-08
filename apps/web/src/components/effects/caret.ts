/**
 * The caret put where it is to go in a box whose words a choice changed, as a mention chosen puts it after the path:
 * once the words are drawn, as the box has them only then.
 */
import { type RefObject, useLayoutEffect } from "react";

/** Where the caret is to go, each placing its own. */
export type Placement = { readonly caret: number };

/** Puts the caret of `box` where `placement` says, as each placement is drawn. */
export function usePlacedCaret(box: RefObject<HTMLTextAreaElement | null>, placement: Placement | undefined): void {
	useLayoutEffect(() => {
		if (placement !== undefined) box.current?.setSelectionRange(placement.caret, placement.caret);
	}, [box, placement]);
}
