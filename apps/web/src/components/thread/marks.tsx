/**
 * The marks lines of work lead with: a call's, its kind of work's icon on a round — a tool the page has no icon for, its
 * name's first letter — red where it went wrong; and the marks of what a line gathers, stacked as the avatars of a
 * group are, each over the one before, at most four in view — where there are more, how many more first, then the
 * latest — each that joins after the stack was first drawn pushed in from its end.
 */
import type { ReactNode } from "react";
import { Code, FilePen, FileText, Globe, type LucideIcon, MessageCircleQuestion, Search, Split, SquareTerminal } from "lucide-react";
import type { WorkKind } from "../../core/tools.ts";
import { useArrived } from "../effects/arrived.ts";
import { cn } from "../ui/cn.ts";

/** Each kind of work's icon; a tool of no kind the page knows is marked by its name. */
const ICONS: Readonly<Record<Exclude<WorkKind, "other">, LucideIcon>> = {
	read: FileText,
	edit: FilePen,
	search: Search,
	command: SquareTerminal,
	script: Code,
	browse: Globe,
	ask: MessageCircleQuestion,
	delegate: Split,
};

/** A line's mark: `children` on a round, red where what it marks went wrong. */
export function Mark(props: { readonly children: ReactNode; readonly troubled?: boolean; readonly className?: string }): ReactNode {
	return <span className={cn("tool-mark", props.troubled === true && "text-error-foreground", props.className)}>{props.children}</span>;
}

/** A call's mark: its kind of work's icon, or its tool's first letter, in capitals. */
export function CallMark(props: {
	readonly call: { readonly work: WorkKind; readonly tool: string; readonly state: string; readonly trouble: string | undefined };
}): ReactNode {
	const { call } = props;
	const troubled = call.state === "failed" || call.trouble !== undefined;
	if (call.work === "other") {
		return (
			<Mark troubled={troubled} className="text-3xs font-semibold">
				{call.tool.charAt(0).toUpperCase()}
			</Mark>
		);
	}
	const Icon = ICONS[call.work];
	return (
		<Mark troubled={troubled}>
			<Icon />
		</Mark>
	);
}

/** A mark of a stack, known by its key. */
export type Stacked = { readonly key: string; readonly mark: ReactNode };

/** How many marks a stack shows at most. */
const SHOWN = 4;

/** `marks`, stacked: the latest in view, each that joins after the stack was first drawn pushed in. */
export function MarkStack(props: { readonly marks: readonly Stacked[] }): ReactNode {
	const { marks } = props;
	const arrived = useArrived(marks.map((each) => each.key));
	const shown = marks.length > SHOWN ? marks.slice(-(SHOWN - 1)) : marks;
	const more = marks.length - shown.length;
	return (
		<span className="tool-marks">
			{more === 0 ? null : <Mark className="text-3xs tabular-nums">+{more}</Mark>}
			{shown.map((each) => (
				<span key={each.key} className={cn("inline-flex", arrived(each.key) && "animate-push-in motion-reduce:animate-none")}>
					{each.mark}
				</span>
			))}
		</span>
	);
}
