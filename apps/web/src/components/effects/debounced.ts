/** A value as it stood once it stopped changing for a while: what is asked of the node as the person types, once they pause. */
import { useEffect, useState } from "react";

/** `value`, once it stood unchanged for `ms`. */
export function useDebounced<Value>(value: Value, ms: number): Value {
	const [settled, setSettled] = useState(value);
	useEffect(() => {
		const timer = setTimeout(() => setSettled(value), ms);
		return () => clearTimeout(timer);
	}, [value, ms]);
	return settled;
}
