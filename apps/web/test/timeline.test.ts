/**
 * A thread's timeline, read from the conversation the client puts together: each turn's words, its work — calls by
 * their tools, the calls a script made under its own, words on the way — its answer, the files it changed, what
 * streams while it works, and how and when it ended; a turn that ended read once, a call's line kept while its call
 * is; and its work as the page lays it out.
 */
import { describe, expect, it } from "bun:test";
import { conversationOf, type Entry, type Process, type ThreadView } from "@octoii-works/octoii-client";
import {
	type CallLine,
	declinedText,
	doingOf,
	firstSaid,
	laidOut,
	replyOf,
	rowsOf,
	type TimelineTurn,
	waitsOnPerson,
	type Work,
	workedText,
} from "../src/core/timeline.ts";

/** The turns among the rows of `conversation`, in their order. */
const turnsOf = (conversation: Parameters<typeof rowsOf>[0]): readonly TimelineTurn[] =>
	rowsOf(conversation).flatMap((row) => (row.kind === "turn" ? [row.turn] : []));

/** A call's line of `tool`, made at the step `step`, done. */
const callOf = (id: string, tool: string, step: string): CallLine => ({
	kind: "call",
	id,
	fiber: undefined,
	step,
	thread: undefined,
	tool,
	work: "other",
	verb: undefined,
	subject: undefined,
	code: true,
	aside: undefined,
	trouble: undefined,
	arguments: "{}",
	output: undefined,
	printed: undefined,
	began: undefined,
	ended: undefined,
	state: "done",
	ask: undefined,
	calls: [],
});

/** A JSON value, as the log holds what a model said. */
type Json = string | number | boolean | null | readonly Json[] | { readonly [key: string]: Json };

/** An id minted at `ms`, as a UUIDv7 holds its time in its first 48 bits. */
function idAt(ms: number, serial: number): string {
	const time = ms.toString(16).padStart(12, "0");
	return `${time.slice(0, 8)}-${time.slice(8)}-7000-8000-${String(serial).padStart(12, "0")}`;
}

const START = 1_700_000_000_000;
const id = (seconds: number, serial: number): string => idAt(START + seconds * 1000, serial);
const said = (at: string, text: string): Entry => ({ id: at, type: "input", delivery_id: `d${at}`, actor: "person", message: { role: "user", content: text } });
const words = (text: string): Json => ({ type: "message", id: "m", role: "assistant", content: [{ type: "output_text", text, annotations: [] }] });
const call = (callId: string, name: string, args: Json): Json => ({ type: "function_call", call_id: callId, name, arguments: JSON.stringify(args) });
const reply = (at: string, request: string, output: Json[]): Entry => ({ id: at, type: "reply", request, response: { id: "r", status: "completed", output } });
const result = (at: string, callId: string, status: "ok" | "tool-error" | "rejected"): Entry => ({
	id: at,
	type: "result",
	status,
	call_output: { call_id: callId, output: "…" },
});
const fiber = (key: string, program: string, parent: string | undefined, input?: Json, requests: Process["requests"] = []): Process => ({
	key,
	program,
	state: "sleeping",
	requests,
	...(parent === undefined ? {} : { parent }),
	...(input === undefined ? {} : { input }),
});

function viewOf(entries: Entry[], processes: Process[] = [], streaming: [string, unknown[]][] = []): ThreadView {
	const status = processes.some((each) => each.program === "siphon.turn") ? "running" : "replied";
	return {
		entries,
		read: true,
		complete: true,
		state: { status, inbox: [], processes },
		streaming: new Map(streaming),
		failure: undefined,
		terminals: [],
		pages: [],
	};
}

describe("a thread's timeline", () => {
	it("stands every row where its id puts it: a compaction within a turn among its work, one between turns and an ask a row of its own", () => {
		const recap = (at: string): Entry => ({
			id: at,
			type: "compaction",
			request: "qr",
			response: { id: "r", status: "completed", output: [words("Recap.")] },
			kept: at,
			from: at,
		});
		const asking = fiber("trust-1", "siphon.trust", "main", undefined, [
			{ key: id(8, 9), name: "trust", payload: { folder: "/w" }, answer: { type: "object" } },
		]);
		const rows = rowsOf(
			conversationOf(
				viewOf(
					[
						said(id(0, 1), "Build it"),
						recap(id(1, 2)),
						reply(id(2, 3), "q1", [words("Built.")]),
						{ id: id(3, 4), type: "turn-end", turn: "t1", outcome: "replied" },
						recap(id(4, 5)),
						said(id(5, 6), "And test it"),
						reply(id(6, 7), "q2", [words("Tested.")]),
						{ id: id(7, 8), type: "turn-end", turn: "t2", outcome: "replied" },
						recap(id(9, 10)),
					],
					[asking],
				),
			),
		);
		expect(rows.map((row) => row.kind)).toEqual(["turn", "summed-up", "turn", "ask", "summed-up"]);
		const [within] = rows;
		expect(within?.kind === "turn" ? within.turn.work.map((each) => each.kind) : []).toEqual(["compaction"]);
		// A turn is known by the entry it began with, which it has from the first.
		expect(rows.map((row) => row.key).slice(1)).toEqual([id(4, 5), id(5, 6), id(8, 9), id(9, 10)]);
	});

	it("gives an ended turn's words, its work by its tools, the words on the way, its answer, and how long it took", () => {
		const [turn] = turnsOf(
			conversationOf(
				viewOf([
					said(id(0, 1), "Fix the build"),
					reply(id(2, 2), "q1", [words("Let me look."), call("c1", "read", { path: "build.zig" }), call("c2", "shell", { command: "zig build" })]),
					result(id(3, 3), "c1", "ok"),
					result(id(4, 4), "c2", "tool-error"),
					reply(id(5, 5), "q2", [words("Fixed it.")]),
					{ id: id(12, 6), type: "turn-end", turn: "t1", outcome: "replied" },
				]),
			),
		);
		// Known by the words it began with, which it has from the first, not by its fiber's key, learnt after.
		expect(turn?.key).toBe(id(0, 1));
		expect(turn?.said.map((each) => each.text)).toEqual(["Fix the build"]);
		expect(turn?.work).toMatchObject([
			{ kind: "words", text: "Let me look." },
			{ kind: "call", tool: "read", work: "read", subject: "build.zig", state: "done" },
			{ kind: "call", tool: "shell", work: "command", subject: "zig build", state: "failed" },
		]);
		expect(turn?.answer?.text).toBe("Fixed it.");
		expect(turn?.ending).toEqual({ state: "replied" });
		expect([turn?.startedAt, turn?.endedAt]).toEqual([START, START + 12_000]);
		expect(turn === undefined ? undefined : workedText(turn)).toBe("Worked for 12s");
		// Each call keeps its step, its arguments and what the model was told, the calls of one reply sharing the step.
		expect(turn?.work).toMatchObject([
			{ kind: "words" },
			{ step: "q1", arguments: JSON.stringify({ path: "build.zig" }), output: "…", ended: START + 3_000 },
			{ step: "q1", output: "…", ended: START + 4_000 },
		]);
	});

	it("gives a working turn's calls as they run, the calls a script made under its own, and the reply being written", () => {
		const made = (callId: string, name: string, args: Json) => ({ type: "function_call" as const, call_id: callId, name, arguments: JSON.stringify(args) });
		const [turn] = turnsOf(
			conversationOf(
				viewOf(
					[
						said(id(0, 1), "Run it"),
						reply(id(1, 2), "q1", [call("c1", "execute", { code: "await tools.read({ path: 'a' })" })]),
						{ id: id(2, 3), type: "calls", under: "c1", calls: [made(id(2, 4), "glob", { pattern: "*.md" }), made(id(2, 5), "read", { path: "a.md" })] },
						{ id: id(3, 6), type: "result", call: id(2, 4), under: "c1", status: "ok", call_output: { call_id: id(2, 4), output: "a.md\nb.md" } },
					],
					[
						fiber("main", "siphon.thread", undefined),
						fiber("t1", "siphon.turn", "main", undefined, [{ key: "q2", name: "model" }]),
						fiber("k1", "siphon.call", "t1", { call_id: "c1", name: "execute", arguments: "{}" }),
						fiber("s1", "siphon.script", "k1"),
						fiber(id(2, 5), "siphon.call", "s1", { call_id: id(2, 5), name: "read", arguments: '{"path":"a.md"}' }, [{ key: "a5", name: "tool" }]),
					],
					[
						[
							"q2",
							[
								{ type: "response.output_text.delta", output_index: 0, delta: "Hel" },
								{ type: "response.output_text.delta", output_index: 0, delta: "lo" },
								{ type: "response.output_item.added", output_index: 1, item: { type: "function_call", call_id: "c3", name: "grep", arguments: "" } },
							],
						],
						["a5", [{ text: "reading" }]],
					],
				),
			),
		);
		expect(turn?.ending).toEqual({ state: "working" });
		expect(turn?.work).toMatchObject([
			{
				kind: "call",
				tool: "execute",
				work: "script",
				verb: "Running a script",
				state: "running",
				aside: { kind: "words", text: "searched 1 time and reading 1 file" },
				calls: [
					{ tool: "glob", subject: "*.md", state: "done", aside: { kind: "words", text: "2 files" }, began: START + 2_000, ended: START + 3_000 },
					{ tool: "read", subject: "a.md", state: "running", printed: "reading" },
				],
			},
		]);
		expect(turn?.writing).toEqual({ words: "Hello", calls: [{ id: "c3", tool: "grep" }] });
		// Of the words being written, the reply shows the blocks that are whole: none yet.
		expect(turn === undefined ? undefined : replyOf(turn)).toBe("");
	});

	it("gives a stopped turn's calls that came to no result as stopped, and a failed turn's reason", () => {
		const [stopped, failed] = turnsOf(
			conversationOf(
				viewOf([
					said(id(0, 1), "Search"),
					reply(id(1, 2), "q1", [call("c1", "grep", { pattern: "TODO" })]),
					{ id: id(2, 3), type: "turn-end", turn: "t1", outcome: "stopped" },
					said(id(3, 4), "Again"),
					{ id: id(4, 5), type: "failure", request: "q2", response: { error: { message: "The provider is down." } } },
					{ id: id(5, 6), type: "turn-end", turn: "t2", outcome: "failed", reason: "The model could not be asked." },
				]),
			),
		);
		expect(stopped?.work).toMatchObject([{ kind: "call", subject: "TODO", state: "stopped" }]);
		expect(stopped?.ending).toEqual({ state: "stopped" });
		expect(stopped === undefined ? undefined : workedText(stopped)).toBe("Stopped after 2s");
		expect(failed?.work).toMatchObject([{ kind: "failure", text: "The provider is down." }]);
		expect(failed?.ending).toEqual({ state: "failed", why: "The model could not be asked." });
	});

	it("marks a call that waits for the person's approval, one they rejected, and what a question asks about", () => {
		const [turn] = turnsOf(
			conversationOf(
				viewOf(
					[
						said(id(0, 1), "Clean up"),
						reply(id(1, 2), "q1", [
							call("c1", "shell", { command: "rm -rf build" }),
							call("c2", "question", { questions: [{ question: "Which?", header: "Target" }] }),
						]),
						result(id(2, 3), "c1", "rejected"),
						reply(id(3, 4), "q2", [call("c3", "write", { path: "a.txt", content: "a" })]),
					],
					[
						fiber("main", "siphon.thread", undefined),
						fiber("t1", "siphon.turn", "main"),
						fiber("k2", "siphon.call", "t1", { call_id: "c2", name: "question", arguments: "{}" }),
						fiber("k3", "siphon.call", "t1", { call_id: "c3", name: "write", arguments: "{}" }, [
							{ key: "p1", name: "permission", answer: { type: "object" } },
						]),
					],
				),
			),
		);
		expect(turn?.work).toMatchObject([
			{ kind: "call", tool: "shell", state: "rejected" },
			{ kind: "call", tool: "question", work: "ask", subject: "Target", state: "running" },
			{ kind: "call", tool: "write", state: "waiting" },
		]);
		// A turn whose call waits on the person says so, rather than that it works.
		expect(turn === undefined ? undefined : [waitsOnPerson(turn), doingOf(turn)]).toEqual([true, "Waiting for you"]);
	});

	it("shows a turn the person steered as one from each of their words on, each where it was said", () => {
		const turns = turnsOf(
			conversationOf(
				viewOf([
					said(id(0, 1), "Fix the build"),
					reply(id(2, 2), id(1, 10), [call("c1", "shell", { command: "zig build" })]),
					result(id(3, 3), "c1", "ok"),
					said(id(4, 4), "Also run the tests"),
					reply(id(6, 5), id(5, 11), [words("Built and tested.")]),
					{ id: id(8, 6), type: "turn-end", turn: "t1", outcome: "replied" },
				]),
			),
		);
		expect(turns.map((turn) => turn.said.map((each) => each.text))).toEqual([["Fix the build"], ["Also run the tests"]]);
		expect(turns.map((turn) => turn.ending.state)).toEqual(["steered", "replied"]);
		expect(turns[0]?.work).toMatchObject([{ kind: "call", tool: "shell", state: "done" }]);
		expect(turns[0]?.answer).toBeUndefined();
		expect(turns[0]?.endedAt).toBe(START + 4000);
		expect(turns[1]?.answer?.text).toBe("Built and tested.");
		expect(turns[1]?.startedAt).toBe(START + 4000);
		expect(turns.map((turn) => turn.key)).toEqual([id(0, 1), id(4, 4)]);
	});

	it("gives whose words a turn took: a thread's task by its text, what a sub-thread told by its words after Siphon's note, the person's as theirs", () => {
		const note = { type: "input_text", text: "[the sub-thread C, which you gave a task in the background, finished]" };
		const turns = turnsOf(
			conversationOf(
				viewOf([
					{ id: id(0, 1), type: "input", delivery_id: "d1", actor: "thread.P", message: { role: "user", content: "Check the docs." } },
					reply(id(1, 2), "q1", [call("c1", "delegate", { thread: "C", task: "Also the links." })]),
					result(id(2, 3), "c1", "ok"),
					reply(id(3, 4), "q2", [words("Asked.")]),
					{ id: id(4, 5), type: "turn-end", turn: "t1", outcome: "replied" },
					{
						id: id(5, 6),
						type: "input",
						delivery_id: "d2",
						actor: "thread.C",
						message: { role: "user", content: [note, { type: "input_text", text: "The docs build." }] },
					},
					{ id: id(5, 7), type: "input", delivery_id: "d3", actor: "thread.D", message: { role: "user", content: [note] } },
					said(id(5, 8), "Thanks"),
					reply(id(6, 9), "q3", [words("Both done.")]),
					{ id: id(7, 10), type: "turn-end", turn: "t2", outcome: "replied" },
				]),
			),
		);
		expect(turns[0]?.said.map(({ from, text }) => ({ from, text }))).toEqual([{ from: "P", text: "Check the docs." }]);
		expect(turns[0]?.work).toMatchObject([{ kind: "call", tool: "delegate", thread: "C" }]);
		// What a sub-thread told is shown though it said nothing, as it did not finish.
		expect(turns[1]?.said.map(({ from, text }) => ({ from, text }))).toEqual([
			{ from: "C", text: "The docs build." },
			{ from: "D", text: "" },
			{ from: undefined, text: "Thanks" },
		]);
	});

	it("marks a call the person declined, and gives a thread's first words where it has no title", () => {
		expect(declinedText({ ...callOf("c", "write", "q"), state: "rejected" })).toBe("Rejected");
		expect(declinedText({ ...callOf("c", "question", "q"), work: "ask", state: "rejected" })).toBe("Dismissed");
		expect(firstSaid(rowsOf(conversationOf(viewOf([said(id(0, 1), "First line\nsecond")]))))).toBe("First line");
		expect(firstSaid([])).toBeUndefined();
	});

	it("reads a turn that ended once, and keeps a call's line while its call is the same; and gives the files a turn changed", () => {
		const diff = "--- a.md\n+++ a.md\n@@ -1,2 +1,2 @@\n-old\n+new\n same";
		const entries: Entry[] = [
			said(id(0, 1), "Tidy"),
			reply(id(1, 2), "q1", [call("c1", "edit", { path: "a.md" }), call("c2", "write", { path: "b.md" })]),
			{ id: id(2, 3), type: "result", status: "ok", call_output: { call_id: "c1", output: diff } },
			{ id: id(2, 4), type: "result", status: "ok", call_output: { call_id: "c2", output: "created b.md +3" } },
			{ id: id(3, 5), type: "turn-end", turn: "t1", outcome: "replied" },
			said(id(4, 6), "And c"),
			reply(id(5, 7), "q2", [call("c3", "read", { path: "c.md" })]),
		];
		const running = [fiber("main", "siphon.thread", undefined), fiber("t2", "siphon.turn", "main", undefined, [{ key: "q3", name: "model" }])];
		const before = turnsOf(conversationOf(viewOf(entries, running)));
		const after = turnsOf(conversationOf(viewOf(entries, running, [["q3", [{ type: "response.output_text.delta", output_index: 0, delta: "Hi" }]]])));
		expect(after[0]).toBe(before[0]);
		expect(after[1]?.work[0]).toBe(before[1]?.work[0]);
		expect(before[0]?.changes).toEqual([
			{ path: "a.md", added: 1, removed: 1 },
			{ path: "b.md", added: 3, removed: 0 },
		]);
	});

	it("lays a stretch of calls as one item from its first call on, delegations as sub-threads, every other step on its own", () => {
		const delegation = (id: string): CallLine => ({ ...callOf(id, "delegate", "q4"), work: "delegate" });
		const words: Work = { kind: "words", key: "w", text: "On it." };
		const laid = laidOut([
			{ ...callOf("a", "read", "q1"), work: "read", subject: "shot-1.png" },
			callOf("c", "shell", "q3"),
			callOf("d", "grep", "q3"),
			words,
			callOf("e", "shell", "q3"),
			delegation("f"),
			delegation("g"),
			{ ...callOf("h", "read", "q5"), state: "failed" },
		]);
		const shown = laid.map((each) => (each.kind === "step" ? each.step.kind : [each.kind, ...each.calls.map((call) => call.id)]));
		expect(shown).toEqual([["calls", "a", "c", "d"], "words", ["calls", "e"], ["delegations", "f", "g"], ["calls", "h"]]);
		// What was thought before a stretch's one call stands on its own; once a second call joins, among the stretch's steps.
		const thought: Work = { kind: "thought", key: "t", text: "Hmm.", took: 1 };
		expect(laidOut([thought, callOf("x", "read", "q1")]).map((each) => each.kind)).toEqual(["step", "calls"]);
		expect(
			laidOut([thought, callOf("x", "read", "q1"), callOf("y", "read", "q2")]).map((each) => (each.kind === "calls" ? each.steps.length : each.kind)),
		).toEqual([3]);
	});
});
