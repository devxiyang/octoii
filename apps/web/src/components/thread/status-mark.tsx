/** How a thread stands, as its mark: asking the person, working, failed, or done — each in its colour. */
import type { ReactNode } from "react";
import { CircleAlert, CircleCheck, LoaderCircle, ShieldQuestion } from "lucide-react";
import type { ThreadStatus } from "../../core/threads.ts";
import { cn } from "../ui/cn.ts";

/** The mark of `status`. */
export function StatusMark(props: { readonly status: ThreadStatus }): ReactNode {
	const look = "size-3.5 shrink-0";
	switch (props.status) {
		case "asks":
			return <ShieldQuestion className={cn(look, "text-warning-foreground")} />;
		case "working":
			return <LoaderCircle className={cn(look, "animate-spin text-info-foreground motion-reduce:animate-none")} />;
		case "failed":
			return <CircleAlert className={cn(look, "text-error-foreground")} />;
		case "ready":
			return <CircleCheck className={cn(look, "text-success-foreground")} />;
	}
}
