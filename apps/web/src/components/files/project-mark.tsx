/**
 * A project's mark: its monogram in the hue it holds among the person's projects, as their threads list them, so two
 * projects read apart wherever they are named; greyed, of no project, where a thread works in none.
 */
import { type ReactNode, useMemo } from "react";
import { useThreads } from "@octoii-works/octoii-client/react";
import { type Project, projectHues } from "../../core/threads.ts";
import { Monogram } from "../ui/monogram.tsx";

/** The mark of `project`, greyed where `faded` or where there is no project. */
export function ProjectMark(props: { readonly project: Project | undefined; readonly size?: "sm" | "md"; readonly faded?: boolean }): ReactNode {
	const rows = useThreads();
	const hues = useMemo(() => projectHues(rows ?? []), [rows]);
	const size = props.size === undefined ? {} : { size: props.size };
	if (props.project === undefined) return <Monogram name="No project" faded {...size} />;
	return <Monogram name={props.project.name} hue={hues.get(props.project.folder)} faded={props.faded === true} {...size} />;
}
