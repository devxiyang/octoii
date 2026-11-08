/**
 * A button that copies words to the clipboard: its tip says what it copies, and for a moment once it did, a check where
 * its icon was, said to assistive technology too; where the clipboard refuses them, the notices say why.
 */
import { type ReactNode, useState } from "react";
import { Check, Copy } from "lucide-react";
import { failed } from "../state/notices.ts";
import { IconButton, type IconButtonProps } from "./button.tsx";

/** How long the check shows once the words are copied. */
const COPIED_MS = 1500;

/** What the button takes: the words it copies, what its tip calls them, and an icon button's look. */
export type CopyButtonProps = Omit<IconButtonProps, "label" | "onClick" | "children"> & { readonly text: string; readonly label?: string };

/** The button. */
export function CopyButton({ text, label = "Copy", size = "icon-xs", ...props }: CopyButtonProps): ReactNode {
	const [copied, setCopied] = useState(false);
	const copy = (): void => {
		navigator.clipboard.writeText(text).then(
			() => {
				setCopied(true);
				window.setTimeout(() => setCopied(false), COPIED_MS);
			},
			(error: unknown) => failed("The words could not be copied", error),
		);
	};
	const Mark = copied ? Check : Copy;
	return (
		<IconButton label={copied ? "Copied" : label} size={size} onClick={copy} {...props}>
			<Mark className="size-3.5" />
			<span role="status" className="sr-only">
				{copied ? "Copied" : ""}
			</span>
		</IconButton>
	);
}
