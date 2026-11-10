/** Bringing what a place names into view: the element of an anchor, at the top of what scrolls it, once the page that holds it is drawn. */
import { useEffect } from "react";

/** Brings the element whose id is `anchor` into view as `anchor` names it, gliding to it; nothing where it names none. */
export function useIntoView(anchor: string | undefined): void {
	useEffect(() => {
		if (anchor === undefined) return;
		document.getElementById(anchor)?.scrollIntoView({ block: "start", behavior: "smooth" });
	}, [anchor]);
}
