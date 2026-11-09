/**
 * What came after a component was first drawn: of the keys it is given, those it was not first drawn with — what
 * arrived while it was shown, which animates as it comes, and never again where the component is drawn anew, as a list
 * that draws what is in view alone draws it again as it is scrolled back to. A component whose keys are not known yet
 * at its first draw — what it shows not read yet — counts from the first draw that knows them.
 */
import { useState } from "react";

/**
 * Whether each key came after the first draw of the component that calls this that knew its keys — `keys`, or none
 * where they are not known yet, when nothing arrived.
 */
export function useArrived(keys: readonly string[] | undefined): (key: string) => boolean {
	const [first, setFirst] = useState<ReadonlySet<string> | undefined>(() => (keys === undefined ? undefined : new Set(keys)));
	// The keys known at last are kept as the first, as React keeps what a render learnt of the one before.
	if (first === undefined && keys !== undefined) setFirst(new Set(keys));
	return (key) => first !== undefined && !first.has(key);
}
