/**
 * What came after a component was first drawn: of the keys it is given, those it was not first drawn with — what
 * arrived while it was shown, which animates as it comes, and never again where the component is drawn anew, as a list
 * that draws what is in view alone draws it again as it is scrolled back to.
 */
import { useState } from "react";

/** Whether each key came after the first draw of the component that calls this, which was first drawn with `keys`. */
export function useArrived(keys: readonly string[]): (key: string) => boolean {
	const [first] = useState(() => new Set(keys));
	return (key) => !first.has(key);
}
