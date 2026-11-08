/**
 * What opens under a call's line, by its shape, read from the call as it opens: a command as a terminal shows it, `$`
 * and the line, then what it printed; an edit's diff, green and red, with a way into the Diff view; a file's text, as
 * read or as written, with a way to open it; the places a search found, each opening its file; a script's code, then
 * what it told; or a call's arguments as fields, then what its tool told. Each well copies what it holds; what its
 * tool noted stands quiet under it.
 */
import { type ReactNode, useMemo } from "react";
import { type CallLine } from "../../core/timeline.ts";
import { prettyArguments, type Told } from "../../core/calls.ts";
import { type Detail, detailOf } from "../../core/tools.ts";
import { DiffLines } from "../diff/diff-lines.tsx";
import { PathLink } from "../files/path-link.tsx";
import { CopyButton } from "../ui/copy-button.tsx";
import { OpenDiff } from "./changes.tsx";

/** What opens under the line of `call`. */
export function CallDetail(props: { readonly call: CallLine }): ReactNode {
	const detail = useMemo(() => detailOf(props.call), [props.call]);
	return (
		<div className="flex flex-col gap-1.5 pt-0.5 pb-2">
			<Shaped detail={detail} />
		</div>
	);
}

/** `detail`, as its shape is drawn. */
function Shaped(props: { readonly detail: Detail }): ReactNode {
	const { detail } = props;
	switch (detail.shape) {
		case "command":
			return (
				<>
					<Well copied={detail.told === undefined ? detail.command : `$ ${detail.command}\n${detail.told.text}`}>
						<span className="text-muted-foreground select-none">$ </span>
						{detail.command}
						{detail.told === undefined || detail.told.text === "" ? null : `\n${detail.told.text}`}
					</Well>
					<Notes notes={detail.told?.notes ?? []} />
				</>
			);
		case "diff":
			return (
				<>
					<Well copied={detail.hunks}>
						<DiffLines text={detail.hunks} />
					</Well>
					<Notes notes={detail.notes} />
					<Action>
						<OpenDiff>Open in Diff</OpenDiff>
					</Action>
				</>
			);
		case "file":
			return (
				<>
					{detail.told === undefined || detail.told.text === "" ? null : <Well copied={detail.told.text}>{detail.told.text}</Well>}
					<Notes notes={detail.told?.notes ?? []} />
					{detail.path === undefined ? null : (
						<Action>
							<PathLink path={detail.path}>Open {detail.path}</PathLink>
						</Action>
					)}
				</>
			);
		case "found":
			return <Found detail={detail} />;
		case "script":
			return (
				<>
					<Well copied={detail.code}>{detail.code}</Well>
					<ToldWell told={detail.told} />
				</>
			);
		case "fields":
			return (
				<>
					{detail.fields === undefined ? (
						<Well copied={detail.arguments}>{prettyArguments(detail.arguments)}</Well>
					) : detail.fields.length === 0 ? null : (
						<dl className="well grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5 px-3 py-2 font-mono text-xs">
							{detail.fields.map((field) => (
								<div key={field.name} className="contents">
									<dt className="text-muted-foreground">{field.name}</dt>
									<dd className="min-w-0 break-words whitespace-pre-wrap text-secondary-label">{field.value}</dd>
								</div>
							))}
						</dl>
					)}
					<ToldWell told={detail.told} />
				</>
			);
	}
}

/** The places a search found, a line each — a file's path, opening it, and the line and its words where it found one — and its notes. */
function Found(props: { readonly detail: Extract<Detail, { shape: "found" }> }): ReactNode {
	const { detail } = props;
	return (
		<>
			{detail.found.length === 0 ? null : (
				<div className="well flex max-h-64 flex-col overflow-auto px-3 py-2 font-mono text-xs">
					{detail.found.map((place) => (
						<span key={`${place.path}:${String(place.line ?? 0)}`} className="flex min-w-0 gap-2 leading-5">
							<span className="shrink-0">
								<PathLink path={place.path}>{place.path}</PathLink>
								{place.line === undefined ? null : <span className="text-muted-foreground">:{place.line}</span>}
							</span>
							{place.text === undefined ? null : <span className="min-w-0 truncate text-secondary-label">{place.text}</span>}
						</span>
					))}
				</div>
			)}
			<Notes notes={detail.notes} />
		</>
	);
}

/** What a tool told, in a well, and its notes; nothing before it told anything. */
function ToldWell(props: { readonly told: Told | undefined }): ReactNode {
	const { told } = props;
	if (told === undefined) return null;
	return (
		<>
			{told.text === "" ? null : <Well copied={told.text}>{told.text}</Well>}
			<Notes notes={told.notes} />
		</>
	);
}

/** Text as it is, in a well — its lines kept, long ones wrapped, scrolled past a height — and a button that copies `copied`, seen as the well is pointed at. */
function Well(props: { readonly copied: string; readonly children: ReactNode }): ReactNode {
	return (
		<div className="well group/well relative">
			<pre className="max-h-64 overflow-auto px-3 py-2 font-mono text-xs leading-relaxed break-words whitespace-pre-wrap text-secondary-label select-text">
				{props.children}
			</pre>
			<span className="absolute top-1 right-1 opacity-0 transition-opacity group-hover/well:opacity-100 group-focus-within/well:opacity-100 pointer-coarse:opacity-100">
				<CopyButton text={props.copied} />
			</span>
		</div>
	);
}

/** What a tool noted of what it told, quiet, a line each. */
function Notes(props: { readonly notes: readonly string[] }): ReactNode {
	if (props.notes.length === 0) return null;
	return (
		<p className="flex flex-col px-3 font-mono text-2xs text-muted-foreground">
			{props.notes.map((note) => (
				<span key={note}>{note}</span>
			))}
		</p>
	);
}

/** A way on from what opened, quiet under it. */
function Action(props: { readonly children: ReactNode }): ReactNode {
	return <p className="px-3 text-xs text-muted-foreground [&_button]:hover:text-foreground">{props.children}</p>;
}
