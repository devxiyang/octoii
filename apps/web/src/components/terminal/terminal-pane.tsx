/** A terminal of the thread's, filling its tab of the right panel: drawn, typed into and sized as its view. */
import type { ReactNode } from "react";
import { useTerminalView } from "../effects/terminal.ts";

/** The terminal `terminal`. */
export function TerminalPane(props: { readonly terminal: string }): ReactNode {
	const ref = useTerminalView(props.terminal);
	return (
		<div className="relative min-h-0 flex-1">
			<div ref={ref} className="absolute inset-0 bg-background text-foreground" />
		</div>
	);
}
