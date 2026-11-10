/** Words as a provider tells them, what stands between backquotes — a command to run — set as code, whole to select. */
import type { ReactNode } from "react";

/** `text`, each part between backquotes set as code. */
export function CodedWords(props: { readonly text: string }): ReactNode {
	return props.text.split("`").map((part, place) =>
		place % 2 === 1 ? (
			<code key={`${String(place)}:${part}`} className="rounded-sm bg-muted px-1 py-px font-mono text-xs text-foreground select-all">
				{part}
			</code>
		) : (
			part
		),
	);
}
