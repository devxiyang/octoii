/** What the window does as it is focused again, as the person comes back to it from another: the latest of it, the window listening once. */
import { useEffect, useEffectEvent } from "react";

export function useOnFocus(act: () => void): void {
	const focused = useEffectEvent(act);
	useEffect(() => {
		const onFocus = (): void => focused();
		window.addEventListener("focus", onFocus);
		return () => window.removeEventListener("focus", onFocus);
	}, []);
}
