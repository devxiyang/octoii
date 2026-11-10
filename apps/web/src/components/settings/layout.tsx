/**
 * The pieces of a settings page, one anatomy for every one: the page's title and what it is for; its sections, each a
 * heading — what it is for under it where it needs saying — over its rows on a card; and a row's title and words on the
 * left, its control on the right, or, for a control that needs the width, under them. A row the search finds stands at
 * its anchor, so the search can bring it into view.
 */
import type { ReactNode } from "react";

/** A page of settings: its title and what it is for, then its sections, one under another, at a reading width. */
export function Page(props: { readonly title: string; readonly description: string; readonly children: ReactNode }): ReactNode {
	return (
		<div className="mx-auto flex w-full max-w-[52rem] flex-col gap-8 px-6 pt-2 pb-16 @max-xl/pane:px-4">
			<div className="flex flex-col gap-1 px-1">
				<h1 className="text-title font-semibold tracking-tight">{props.title}</h1>
				<p className="text-ui text-muted-foreground">{props.description}</p>
			</div>
			{props.children}
		</div>
	);
}

/** A section's heading: its title, an icon before it, and an action beside it. */
export function SectionHeading(props: { readonly title: string; readonly icon?: ReactNode; readonly action?: ReactNode }): ReactNode {
	return (
		<div className="flex min-h-control-sm items-center justify-between px-1">
			<h2 className="flex items-center gap-2 text-ui font-semibold">
				{props.icon}
				{props.title}
			</h2>
			{props.action}
		</div>
	);
}

/** A section: its heading, what it is for where that needs saying, and its rows on a card; at its anchor, where the search finds it. */
export function Section(props: {
	readonly title: string;
	readonly description?: string | undefined;
	readonly anchor?: string | undefined;
	readonly action?: ReactNode;
	readonly children: ReactNode;
}): ReactNode {
	return (
		<section id={props.anchor} className="flex scroll-mt-4 flex-col gap-2">
			<div>
				<SectionHeading title={props.title} action={props.action} />
				{props.description === undefined ? null : <p className="px-1 text-xs text-balance text-muted-foreground">{props.description}</p>}
			</div>
			<div className="card [&>*+*]:border-t [&>*+*]:border-border">{props.children}</div>
		</section>
	);
}

/** What a row is given: its title and words, the anchor the search finds it at, and its control. */
type RowProps = { readonly title: string; readonly description?: ReactNode; readonly anchor?: string | undefined; readonly children?: ReactNode };

/** A row: its title and words on the left, its control on the right — under them where the row is narrow. */
export function Row(props: RowProps): ReactNode {
	return (
		<div id={props.anchor} className="@container scroll-mt-4">
			<div className="grid grid-cols-1 items-center gap-2 px-3.5 py-2.5 @md:grid-cols-[minmax(0,1fr)_auto] @md:gap-6">
				<RowWords title={props.title} description={props.description} />
				{props.children === undefined ? null : <div className="flex items-center gap-2 @md:justify-end">{props.children}</div>}
			</div>
		</div>
	);
}

/** A row whose control needs the width: its title and words, the control under them, as wide as it is or takes. */
export function BlockRow(props: RowProps): ReactNode {
	return (
		<div id={props.anchor} className="flex scroll-mt-4 flex-col items-start gap-3 px-3.5 py-3">
			<RowWords title={props.title} description={props.description} />
			{props.children}
		</div>
	);
}

/** A row's title, and its words under it. */
function RowWords(props: { readonly title: string; readonly description?: ReactNode }): ReactNode {
	return (
		<div className="min-w-0">
			<p className="text-ui font-medium">{props.title}</p>
			{props.description === undefined ? null : <p className="mt-0.5 text-xs text-balance text-muted-foreground">{props.description}</p>}
		</div>
	);
}
