/**
 * A link to a path of the machine, in a message the person or the model wrote: the path's icon and its words, as a link
 * looks, the path on hover; opened in the panel as it is clicked — a file read, a folder opened in the tree — where the
 * thread the message is shown in works in a folder; else its words alone.
 */
import { type ReactNode, useContext } from "react";
import { openPath } from "../state/panel.ts";
import { MessageThreadContext } from "../thread/message-thread.ts";
import { PathIcon } from "./path-icon.tsx";

/** The link to `path`, its words `children`. */
export function PathLink(props: { readonly path: string; readonly children: ReactNode }): ReactNode {
	const shown = useContext(MessageThreadContext);
	const { path } = props;
	const icon = <PathIcon path={path} kind={path.endsWith("/") ? "directory" : "file"} className="mr-0.5 inline size-[1em] -translate-y-px align-middle" />;
	const workspace = shown?.workspace;
	if (shown === undefined || workspace === undefined) {
		return (
			<span title={path}>
				{icon}
				{props.children}
			</span>
		);
	}
	return (
		<button type="button" data-link title={path} onClick={() => openPath(shown.thread, workspace, path)} className="cursor-pointer text-left">
			{icon}
			{props.children}
		</button>
	);
}
