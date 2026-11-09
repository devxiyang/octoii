/**
 * What waits for the person's answer, as a card where it is asked in the timeline, the composer free beside it: trust
 * in what a folder's configuration would run, with the servers it names; a call's permission, with what it does — once,
 * always, or not, with words for the model; a model's questions, one at a time, each with its choices and the person's
 * own words, or dismissed all at once; one of some answers, with the fields each takes; an object's own fields; or
 * what this page cannot ask, shown as it came. While an answer goes to the node nothing more is answered on its card;
 * what the node refused is said.
 */
import { type FormEvent, type KeyboardEvent, type ReactNode, useState, useTransition } from "react";
import type { Ask } from "@octoii-works/octoii-client";
import { useClient, useThreads } from "@octoii-works/octoii-client/react";
import { FilePen, MessageCircleQuestion, ShieldAlert, ShieldQuestion, SquareTerminal, Wrench, X } from "lucide-react";
import {
	type Access,
	alwaysText,
	type Choice,
	choiceAnswer,
	choose,
	type DetailLine,
	DISMISSED,
	type Draft,
	type Field as AskField,
	fieldsAnswer,
	formOf,
	type Given,
	type Json,
	missingField,
	permissionDetail,
	permissionTitle,
	type Question,
	questionsAnswer,
	type ServerShown,
	UNANSWERED,
	write,
} from "../../core/asks.ts";
import { folderName } from "../../core/threads.ts";
import { useShortcuts } from "../effects/shortcut.ts";
import { Button, IconButton } from "../ui/button.tsx";
import { CheckboxBox, CheckboxChoice, CheckboxGroup, RadioChoice, RadioDot, RadioGroup } from "../ui/choices.tsx";
import { IconTile } from "../ui/icon-tile.tsx";
import { Field } from "../ui/input.tsx";
import { Kbd } from "../ui/kbd.tsx";
import { Pill } from "../ui/pill.tsx";
import { Segmented } from "../ui/segmented.tsx";
import { Switch } from "../ui/switch.tsx";

/**
 * What waits on the person in `thread`, as a card where it is asked in the timeline — at the call it is made for, or
 * at the thread's last turn where no call made it — the folder the thread works in and its project's read from its row.
 */
export function AskInline(props: { readonly thread: string; readonly ask: Ask }): ReactNode {
	const manifest = useThreads()?.find((row) => row.id === props.thread)?.manifest;
	return (
		<div className="card flex w-full flex-col p-4">
			<AskForm thread={props.thread} workspace={manifest?.workspace} project={manifest?.project} ask={props.ask} />
		</div>
	);
}

/** The answer of one request, by what its form asks. */
function AskForm(props: {
	readonly thread: string;
	readonly workspace: string | undefined;
	readonly project: string | undefined;
	readonly ask: Ask;
}): ReactNode {
	const client = useClient();
	const [refused, setRefused] = useState<string | undefined>(undefined);
	const [answering, startAnswering] = useTransition();
	const answer = (value: Json): void =>
		startAnswering(async () => {
			try {
				await client.answer(props.thread, props.ask.request.key, value);
			} catch (error) {
				setRefused(error instanceof Error ? error.message : String(error));
			}
		});
	const form = formOf(props.ask);
	return (
		// While an answer goes to the node, every button and field of the card waits.
		<fieldset disabled={answering} className="contents">
			{form.kind === "trust" ? <Trust folder={form.folder} servers={form.servers} onAnswer={answer} /> : null}
			{form.kind === "permission" ? (
				<Permission
					tool={form.tool}
					arguments={form.arguments}
					access={form.access}
					doubt={form.doubt}
					workspace={props.workspace}
					project={props.project}
					onAnswer={answer}
				/>
			) : null}
			{form.kind === "question" ? <Questions questions={form.questions} onAnswer={answer} /> : null}
			{form.kind === "choices" ? <Choices name={props.ask.request.name} property={form.key} choices={form.choices} onAnswer={answer} /> : null}
			{form.kind === "fields" ? <Fields name={props.ask.request.name} fields={form.fields} onAnswer={answer} /> : null}
			{form.kind === "shown" ? <Shown ask={props.ask} /> : null}
			{refused === undefined ? null : <p className="mt-2 text-xs text-error-foreground">{refused}</p>}
		</fieldset>
	);
}

/** A heading with its icon, and what stands beside it, over what it asks. */
function Asked(props: { readonly icon: ReactNode; readonly title: string; readonly aside?: ReactNode; readonly children: ReactNode }): ReactNode {
	return (
		<div>
			<div className="mb-2 flex items-center gap-2">
				<span className="text-muted-foreground">{props.icon}</span>
				<span className="min-w-0 flex-1 truncate text-sm font-medium">{props.title}</span>
				{props.aside}
			</div>
			{props.children}
		</div>
	);
}

/** Trust in what a folder's configuration names to run: each server as it would be run, then trust or not. */
function Trust(props: { readonly folder: string; readonly servers: readonly ServerShown[]; readonly onAnswer: (value: Json) => void }): ReactNode {
	return (
		<Asked icon={<ShieldQuestion className="size-4 text-warning-foreground" />} title={`Trust what ${folderName(props.folder)} runs?`}>
			<p className="text-sm text-muted-foreground">Its configuration names servers Octoii would run on this computer, as you:</p>
			<ul className="mt-2 flex max-h-40 flex-col gap-1 overflow-auto rounded-lg border border-border/70 px-3 py-2 font-mono text-xs">
				{props.servers.map((server) => (
					<li key={server.name} className="truncate">
						<span className="text-foreground">{server.name}</span>
						<span className="text-muted-foreground"> — {[server.command, ...(server.args ?? [])].join(" ")}</span>
					</li>
				))}
			</ul>
			<div className="mt-3 flex gap-2">
				<Button size="sm" variant="default" onClick={() => props.onAnswer({ trusted: true })}>
					Trust
				</Button>
				<Button size="sm" variant="outline" onClick={() => props.onAnswer({ trusted: false })}>
					Don't trust
				</Button>
			</div>
		</Asked>
	);
}

/** Each action's icon: a terminal for a command, a pen for an edit, a wrench for a tool. */
const ACTION_ICONS: Readonly<Record<Access["action"], typeof Wrench>> = { command: SquareTerminal, edit: FilePen, tool: Wrench };

/**
 * A call's permission, as a request to the person: what it asks to do, and a mark where it must go beyond the sandbox
 * or the model that judged it doubted it; what will happen, line by line; why it must go further, and what the judge
 * doubted. Then how long the person lets it — just once, or always in the thread's project as its patterns say — and
 * allowed, ⌘↵, or denied: Esc at once, or with words for the model of what to do instead.
 */
function Permission(props: {
	readonly tool: string;
	readonly arguments: unknown;
	readonly access: Access;
	readonly doubt: string | undefined;
	readonly workspace: string | undefined;
	readonly project: string | undefined;
	readonly onAnswer: (value: Json) => void;
}): ReactNode {
	const [scope, setScope] = useState<"once" | "always">("once");
	const [denying, setDenying] = useState(false);
	const [message, setMessage] = useState("");
	const Icon = ACTION_ICONS[props.access.action];
	const always = alwaysText(props.access, props.project);
	const allow = (): void => props.onAnswer({ reply: always !== undefined && scope === "always" ? "always" : "once" });
	const deny = (words: string): void => props.onAnswer(words.trim() === "" ? { reply: "reject" } : { reply: "reject", message: words.trim() });
	const keys = (event: KeyboardEvent): void => {
		// The words for the model are a form of their own, which Enter sends and Esc leaves.
		if (denying) return;
		if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
			event.preventDefault();
			allow();
		} else if (event.key === "Escape") {
			event.preventDefault();
			deny("");
		}
	};
	return (
		<div onKeyDown={keys} className="outline-none">
			<div className="mb-2 flex items-center gap-2">
				<IconTile>
					<Icon />
				</IconTile>
				<span className="min-w-0 flex-1 truncate text-sm font-medium">{permissionTitle(props.tool, props.access)}</span>
				{props.access.escalate === true ? (
					<Pill tone="waiting" icon={<ShieldAlert />}>
						Beyond the sandbox
					</Pill>
				) : null}
				{props.doubt === undefined ? null : (
					<Pill tone="waiting" icon={<ShieldAlert />}>
						Doubted
					</Pill>
				)}
			</div>
			<p className="mb-1 text-xs text-muted-foreground">What will happen</p>
			<Detail lines={permissionDetail(props.tool, props.arguments, props.access, props.workspace)} />
			{props.access.justification === undefined ? null : <p className="mt-2 text-sm text-muted-foreground">{props.access.justification}</p>}
			{props.doubt === undefined ? null : <p className="mt-2 text-sm text-warning-foreground">{props.doubt}</p>}
			{denying ? (
				<form
					onSubmit={(event: FormEvent) => {
						event.preventDefault();
						deny(message);
					}}
					onKeyDown={(event) => {
						if (event.key === "Escape") setDenying(false);
					}}
					className="mt-3 flex items-center gap-2"
				>
					<Field
						label="What to do instead"
						placeholder="What to do instead (optional)"
						value={message}
						onValueChange={setMessage}
						className="flex-1"
						autoFocus
					/>
					<Button size="sm" variant="outline" onClick={() => setDenying(false)}>
						Back
					</Button>
					<Button type="submit" size="sm" variant="default">
						Deny
					</Button>
				</form>
			) : (
				<div className="mt-3 flex flex-col gap-2">
					{always === undefined ? null : (
						<div className="flex flex-col gap-1">
							<Segmented
								label="How long to allow it"
								value={scope}
								onValueChange={setScope}
								items={[
									{ value: "once", label: "Just once" },
									{ value: "always", label: `Always in ${props.project === undefined ? "the project" : folderName(props.project)}` },
								]}
							/>
							{scope === "always" ? <p className="truncate px-0.5 text-xs text-muted-foreground">{always}</p> : null}
						</div>
					)}
					<div className="flex items-center justify-end gap-2">
						<Button size="sm" variant="outline" onClick={() => setDenying(true)}>
							Deny <Kbd>Esc</Kbd>
						</Button>
						<Button size="sm" variant="default" onClick={allow}>
							Allow <Kbd className="bg-primary-foreground/15 text-primary-foreground/80">⌘↵</Kbd>
						</Button>
					</div>
				</div>
			)}
		</div>
	);
}

/** What a call does, line by line, an edit's lines taken out and put in marked as a diff marks them. */
function Detail(props: { readonly lines: readonly DetailLine[] }): ReactNode {
	return (
		<pre className="well max-h-48 overflow-auto px-3 py-2 font-mono text-xs leading-5 whitespace-pre-wrap [overflow-wrap:anywhere]">
			{props.lines.map((line) => (
				<div key={line.number} className={LINE_CLASSES[line.kind]}>
					{line.kind === "removed" ? "- " : line.kind === "added" ? "+ " : ""}
					{line.text}
				</div>
			))}
		</pre>
	);
}

/** How each line of a call's detail reads. */
const LINE_CLASSES: Readonly<Record<DetailLine["kind"], string>> = {
	text: "text-foreground",
	removed: "bg-error/8 text-error-foreground",
	added: "bg-success/8 text-success-foreground",
};

/** The keys that choose a question's choices, as they are numbered. */
const DIGITS: readonly string[] = ["1", "2", "3", "4", "5", "6", "7", "8", "9"];

/**
 * A model's questions, one at a time, their count beside the heading: the question's choices, each a row with its key,
 * and a field for the person's own words — of a question of one choice, its answer in place of a choice; skipped, a
 * question is left unanswered; at the last, every answer is sent; dismissed, none is.
 */
function Questions(props: { readonly questions: readonly Question[]; readonly onAnswer: (value: Json) => void }): ReactNode {
	const [drafts, setDrafts] = useState<readonly Draft[]>(() => props.questions.map(() => UNANSWERED));
	const [at, setAt] = useState(0);
	const question = props.questions[at];
	const draft = drafts[at] ?? UNANSWERED;
	const options = question?.options ?? [];
	const last = at === props.questions.length - 1;
	const given = (next: Draft): readonly Draft[] => drafts.map((each, index) => (index === at ? next : each));
	const forward = (answered: readonly Draft[]): void => {
		setDrafts(answered);
		if (last) props.onAnswer(questionsAnswer(answered));
		else setAt(at + 1);
	};
	const pick = (label: string): void => {
		if (question !== undefined) setDrafts(given(choose(question, draft, label)));
	};
	useShortcuts(DIGITS.slice(0, options.length), (key) => {
		const option = options[Number(key) - 1];
		if (option !== undefined) pick(option.label);
	});
	if (question === undefined) return null;
	return (
		<Asked
			icon={<MessageCircleQuestion className="size-4" />}
			title={question.header}
			aside={
				<>
					{props.questions.length > 1 ? (
						<span className="text-xs text-muted-foreground tabular-nums">
							{at + 1}/{props.questions.length}
						</span>
					) : null}
					<IconButton label="Dismiss without answering" size="icon-xs" onClick={() => props.onAnswer(DISMISSED)}>
						<X />
					</IconButton>
				</>
			}
		>
			<p className="text-sm text-foreground/90">{question.question}</p>
			{options.length === 0 ? null : (
				<Options
					options={options}
					multiple={question.multiple === true}
					chosen={draft.chosen}
					onPick={pick}
					onChosen={(chosen) => setDrafts(given({ ...draft, chosen }))}
				/>
			)}
			<form
				onSubmit={(event) => {
					event.preventDefault();
					forward(drafts);
				}}
			>
				<Field
					key={at}
					label="Your own answer"
					placeholder={options.length === 0 ? "Your answer" : "Or answer in your own words"}
					value={draft.own}
					onValueChange={(text) => setDrafts(given(write(question, draft, text)))}
					className="mt-2"
				/>
				<div className="mt-3 flex items-center gap-2">
					<Button size="sm" variant="ghost-muted" onClick={() => forward(given(UNANSWERED))}>
						Skip
					</Button>
					<span className="flex-1" />
					{at > 0 ? (
						<Button size="sm" variant="outline" onClick={() => setAt(at - 1)}>
							Back
						</Button>
					) : null}
					<Button type="submit" size="sm" variant="default">
						{last ? "Submit" : "Next"}
					</Button>
				</div>
			</form>
		</Asked>
	);
}

/** A choice a question offers: its label, and what it means. */
type Option = NonNullable<Question["options"]>[number];

/** How a question's choice reads: a row that shades as it is pointed at, its words clear once it is chosen. */
const OPTION_CLASS =
	"flex w-full cursor-pointer items-start gap-2.5 rounded-md px-1.5 py-1.5 text-left text-foreground/75 hover:bg-accent/50 focus-visible:ring-1 focus-visible:ring-ring data-checked:text-foreground";

/**
 * A question's choices, each a row with its mark, its words and its key: of a question of one choice, a radio group the
 * arrow keys walk, picking one; of several, a box each, those checked chosen.
 */
function Options(props: {
	readonly options: readonly Option[];
	readonly multiple: boolean;
	readonly chosen: readonly string[];
	readonly onPick: (label: string) => void;
	readonly onChosen: (chosen: readonly string[]) => void;
}): ReactNode {
	if (props.multiple) {
		return (
			<CheckboxGroup value={[...props.chosen]} onValueChange={props.onChosen} className="mt-2 flex flex-col">
				{props.options.map((option, index) => (
					<CheckboxChoice key={option.label} value={option.label} className={OPTION_CLASS}>
						<span className="flex h-5 shrink-0 items-center">
							<CheckboxBox />
						</span>
						<OptionWords option={option} place={index} />
					</CheckboxChoice>
				))}
			</CheckboxGroup>
		);
	}
	return (
		// The group stays controlled with no choice chosen, as the person's own words take the place of one: a value no choice holds.
		<RadioGroup value={props.chosen[0] ?? ""} onValueChange={(label: string) => props.onPick(label)} className="mt-2 flex flex-col">
			{props.options.map((option, index) => (
				<RadioChoice key={option.label} value={option.label} className={OPTION_CLASS}>
					<span className="flex h-5 shrink-0 items-center">
						<RadioDot />
					</span>
					<OptionWords option={option} place={index} />
				</RadioChoice>
			))}
		</RadioGroup>
	);
}

/** A choice's words — its label and what it means — and the key that picks it, by where it stands. */
function OptionWords(props: { readonly option: Option; readonly place: number }): ReactNode {
	return (
		<>
			<span className="flex min-w-0 flex-1 flex-col gap-0.5">
				<span className="text-sm font-medium">{props.option.label}</span>
				{props.option.description === undefined ? null : <span className="text-xs text-muted-foreground">{props.option.description}</span>}
			</span>
			{props.place < DIGITS.length ? <Kbd>{DIGITS[props.place]}</Kbd> : null}
		</>
	);
}

/** One of some answers: a button for each, and the fields the chosen one takes. */
function Choices(props: {
	readonly name: string;
	readonly property: string;
	readonly choices: readonly Choice[];
	readonly onAnswer: (value: Json) => void;
}): ReactNode {
	const [chosen, setChosen] = useState<Choice | undefined>(undefined);
	const [given, setGiven] = useState<Given>({});
	const fields = chosen?.fields ?? [];
	return (
		<Asked icon={<MessageCircleQuestion className="size-4" />} title={props.name}>
			<div className="flex flex-wrap gap-2">
				{props.choices.map((choice) => (
					<Button
						key={choice.value}
						size="sm"
						variant={choice === chosen ? "default" : "outline"}
						onClick={() => (choice.fields.length === 0 ? props.onAnswer(choiceAnswer(props.property, choice, {})) : setChosen(choice))}
					>
						{choice.label}
					</Button>
				))}
			</div>
			<FieldRows fields={fields} given={given} onGiven={setGiven} />
			{chosen === undefined || fields.length === 0 ? null : (
				<div className="mt-3 flex justify-end">
					<Button
						size="sm"
						variant="default"
						disabled={missingField(fields, given)}
						onClick={() => props.onAnswer(choiceAnswer(props.property, chosen, given))}
					>
						{chosen.label}
					</Button>
				</div>
			)}
		</Asked>
	);
}

/** An object's own fields, and the button that answers with them. */
function Fields(props: { readonly name: string; readonly fields: readonly AskField[]; readonly onAnswer: (value: Json) => void }): ReactNode {
	const [given, setGiven] = useState<Given>({});
	return (
		<Asked icon={<MessageCircleQuestion className="size-4" />} title={props.name}>
			<FieldRows fields={props.fields} given={given} onGiven={setGiven} />
			<div className="mt-3 flex justify-end">
				<Button size="sm" variant="default" disabled={missingField(props.fields, given)} onClick={() => props.onAnswer(fieldsAnswer(props.fields, given))}>
					Answer
				</Button>
			</div>
		</Asked>
	);
}

/** The rows of fields: each its label, and a switch for yes or no, else a field of text. */
function FieldRows(props: { readonly fields: readonly AskField[]; readonly given: Given; readonly onGiven: (given: Given) => void }): ReactNode {
	return props.fields.map((field) => {
		const key = field.path.join(".");
		const value = props.given[key];
		return (
			<div key={key} className="mt-2 flex items-center gap-3">
				<span className="w-32 shrink-0 text-xs text-muted-foreground" title={field.description}>
					{field.label}
				</span>
				{field.takes.kind === "boolean" ? (
					<Switch aria-label={field.label} checked={value === true} onCheckedChange={(on) => props.onGiven({ ...props.given, [key]: on })} />
				) : (
					<Field
						label={field.label}
						value={typeof value === "string" || typeof value === "number" ? String(value) : ""}
						onValueChange={(text) => props.onGiven({ ...props.given, [key]: field.takes.kind === "number" && text !== "" ? Number(text) : text })}
						className="flex-1"
					/>
				)}
			</div>
		);
	});
}

/** A request this page cannot ask: its name and what it was made with, as they came. */
function Shown(props: { readonly ask: Ask }): ReactNode {
	return (
		<Asked icon={<MessageCircleQuestion className="size-4" />} title={props.ask.request.name}>
			<pre className="max-h-40 overflow-auto rounded-lg border border-border/70 px-3 py-2 font-mono text-xs">
				{JSON.stringify(props.ask.request.payload ?? null, null, 2)}
			</pre>
			<p className="mt-2 text-xs text-muted-foreground">This page cannot answer this request.</p>
		</Asked>
	);
}
