/* oxlint-disable octoii/no-palette-colors -- a scheme's picture draws the light and the dark palettes whatever the page's theme is */
/**
 * A color scheme's picture: a small window of the app in its colors — a sidebar, lines of a reply, a card and the
 * composer with its button — light, dark, or for the system's, light on the left and dark on the right.
 */
import type { ReactNode } from "react";

/** The colors of one scheme's picture. */
type Tones = { readonly page: string; readonly side: string; readonly line: string; readonly card: string; readonly border: string };

const LIGHT: Tones = { page: "bg-zinc-50", side: "bg-zinc-100", line: "bg-zinc-200", card: "bg-white", border: "border-zinc-200" };
const DARK: Tones = { page: "bg-neutral-950", side: "bg-neutral-900", line: "bg-neutral-800", card: "bg-neutral-900", border: "border-neutral-800" };

/** The picture of `scheme`. */
export function SchemePreview(props: { readonly scheme: "system" | "light" | "dark" }): ReactNode {
	if (props.scheme === "light") return <Window tones={LIGHT} />;
	if (props.scheme === "dark") return <Window tones={DARK} />;
	return (
		<div className="relative">
			<Window tones={LIGHT} />
			<div className="absolute inset-0 [clip-path:inset(0_0_0_50%)]">
				<Window tones={DARK} />
			</div>
		</div>
	);
}

/** The small window in `tones`. */
function Window(props: { readonly tones: Tones }): ReactNode {
	const { tones } = props;
	return (
		<div className={`flex aspect-[2/1] overflow-hidden rounded-md border ${tones.border} ${tones.page}`}>
			<div className={`flex w-1/4 flex-col gap-1.5 border-r p-2 ${tones.border}`}>
				<span className={`h-2.5 w-4/5 rounded-full border ${tones.border} ${tones.card}`} />
				<span className={`h-1.5 w-3/5 rounded-full ${tones.side}`} />
				<span className={`h-1.5 w-4/5 rounded-full ${tones.side}`} />
				<span className={`h-1.5 w-3/5 rounded-full ${tones.side}`} />
			</div>
			<div className="relative flex flex-1 flex-col gap-1.5 p-3">
				<span className={`ml-auto h-2.5 w-1/4 rounded-full ${tones.line}`} />
				<span className={`h-1.5 w-1/2 rounded-full ${tones.line}`} />
				<span className={`h-1.5 w-2/5 rounded-full ${tones.line}`} />
				<div className={`absolute top-2 right-2 flex w-1/5 flex-col gap-1 rounded border p-1.5 ${tones.border} ${tones.card}`}>
					<span className="flex items-center gap-1">
						<span className="size-1 rounded-full bg-emerald-500" />
						<span className={`h-1 flex-1 rounded-full ${tones.line}`} />
					</span>
					<span className="flex items-center gap-1">
						<span className="size-1 rounded-full bg-violet-500" />
						<span className={`h-1 flex-1 rounded-full ${tones.line}`} />
					</span>
					<span className="flex items-center gap-1">
						<span className="size-1 rounded-full bg-amber-500" />
						<span className={`h-1 flex-1 rounded-full ${tones.line}`} />
					</span>
				</div>
				<div className={`mt-auto flex h-4 items-center justify-between rounded-md border px-1.5 ${tones.border} ${tones.card}`}>
					<span className={`h-1 w-1/3 rounded-full ${tones.line}`} />
					<span className="size-2 rounded-full bg-primary" />
				</div>
			</div>
		</div>
	);
}
