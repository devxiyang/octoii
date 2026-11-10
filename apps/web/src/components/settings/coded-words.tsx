/**
 * Words as a provider tells them, what stands between backquotes — a command to run — set as code, whole to select,
 * with a button that copies it.
 */
import type { ReactNode } from "react";
import { CopyButton } from "../ui/copy-button.tsx";

/** `text`, each part between backquotes set as code and copied by the button after it. */
export function CodedWords(props: { readonly text: string }): ReactNode {
	return props.text.split("`").map((part, place) =>
		place % 2 === 1 ? (
			<span key={`${String(place)}:${part}`}>
				<code className="rounded-sm bg-muted px-1 py-px font-mono text-xs break-all text-foreground select-all">{part}</code>
				<CopyButton text={part} label="Copy the command" className="-my-1 ms-0.5 inline-flex align-middle" />
			</span>
		) : (
			part
		),
	);
}
