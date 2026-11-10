/**
 * A color scheme's picture: a small window of the app in its colors — the sidebar, a message, lines of a reply and the
 * composer with its button — light, dark, or for the system's, light on the left and dark on the right. Each is drawn
 * with the design's own tokens, in the scheme its class names, so it shows the palette the device has.
 */
import type { ReactNode } from "react";

/** The picture of `scheme`. */
export function SchemePreview(props: { readonly scheme: "system" | "light" | "dark" }): ReactNode {
	if (props.scheme !== "system") return <Window scheme={props.scheme} />;
	return (
		<div className="relative">
			<Window scheme="light" />
			<div className="absolute inset-0 [clip-path:inset(0_0_0_50%)]">
				<Window scheme="dark" />
			</div>
		</div>
	);
}

/** The small window in `scheme`, whose class sets the tokens within it. */
function Window(props: { readonly scheme: "light" | "dark" }): ReactNode {
	return (
		<div className={`${props.scheme} flex aspect-[2/1] overflow-hidden rounded-md border border-border bg-background`}>
			<div className="flex w-1/4 flex-col gap-1.5 border-r border-border bg-sidebar p-2">
				<span className="h-2.5 w-4/5 rounded-full bg-selected" />
				<span className="h-1.5 w-3/5 rounded-full bg-accent" />
				<span className="h-1.5 w-4/5 rounded-full bg-accent" />
				<span className="h-1.5 w-3/5 rounded-full bg-accent" />
			</div>
			<div className="flex flex-1 flex-col gap-1.5 p-3">
				<span className="ml-auto h-2.5 w-1/4 rounded-full bg-selected" />
				<span className="h-1.5 w-1/2 rounded-full bg-faint-foreground" />
				<span className="h-1.5 w-2/5 rounded-full bg-faint-foreground" />
				<div className="mt-auto flex h-4 items-center justify-between rounded-sm border border-border bg-card px-1.5">
					<span className="h-1 w-1/3 rounded-full bg-accent" />
					<span className="size-2 rounded-full bg-primary" />
				</div>
			</div>
		</div>
	);
}
