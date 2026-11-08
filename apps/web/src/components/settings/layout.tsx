/**
 * The pieces of a settings page: a section's heading, a section with its rows on a card under it, and a row's title,
 * words and control — set close, as the rest of the interface is.
 */
import type { ReactNode } from "react";

/** A section's heading: its title, and an action beside it. */
export function SectionHeading(props: { readonly title: string; readonly action?: ReactNode }): ReactNode {
	return (
		<div className="flex min-h-control-sm items-center justify-between px-1">
			<h3 className="text-sm font-semibold">{props.title}</h3>
			{props.action}
		</div>
	);
}

/** A section: its heading, and its rows on a card. */
export function Section(props: { readonly title: string; readonly action?: ReactNode; readonly children: ReactNode }): ReactNode {
	return (
		<section className="flex flex-col gap-2">
			<SectionHeading title={props.title} action={props.action} />
			<div className="rounded-xl border border-border/60 bg-card/40 shadow-xs [&>*+*]:border-t [&>*+*]:border-border/50">{props.children}</div>
		</section>
	);
}

/** A row: its title and what it does on the left, its control on the right — under them where the row is narrow. */
export function Row(props: { readonly title: string; readonly description?: string; readonly children?: ReactNode }): ReactNode {
	return (
		<div className="@container">
			<div className="grid grid-cols-1 items-center gap-2 px-3.5 py-2.5 @md:grid-cols-[minmax(0,1fr)_auto] @md:gap-6">
				<div className="min-w-0">
					<p className="text-ui font-medium">{props.title}</p>
					{props.description === undefined ? null : <p className="mt-0.5 text-xs text-balance text-muted-foreground">{props.description}</p>}
				</div>
				{props.children === undefined ? null : <div className="flex items-center gap-2 @md:justify-end">{props.children}</div>}
			</div>
		</div>
	);
}

/** A page of settings: its sections, one under another. */
export function Page(props: { readonly children: ReactNode }): ReactNode {
	return <div className="mx-auto flex w-full max-w-[40rem] flex-col gap-6 px-6 py-5">{props.children}</div>;
}
