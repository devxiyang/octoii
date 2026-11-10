/**
 * The timeline's rows: each turn laid out flat — its words, each part of its work, its reply and its end — with the
 * room each leaves above it, what is the thread's own between turns a row each; and rows that did not change kept as
 * the same objects.
 */
import { describe, expect, it } from "bun:test";
import { rowsOf, steadyRows, type TimelineRow } from "../src/core/rows.ts";
import type { CallLine, Said, TimelineItem, TimelineTurn } from "../src/core/timeline.ts";

const said = (key: string, text: string): Said => ({ key, delivery: `d-${key}`, at: 0, from: undefined, text, attachments: [] });

const callOf = (id: string): CallLine => ({
	kind: "call",
	id,
	fiber: undefined,
	step: "s1",
	thread: undefined,
	tool: "read",
	work: "read",
	verb: "Read",
	subject: "a.ts",
	code: false,
	aside: undefined,
	trouble: undefined,
	arguments: "{}",
	output: "",
	printed: undefined,
	began: 1_000,
	ended: 2_000,
	state: "done",
	ask: undefined,
	calls: [],
});

/** A turn as the page shows it: `given` over one that the person began with "Fix it" and that replied. */
const turnOf = (given: Partial<TimelineTurn> = {}): TimelineTurn => ({
	key: "t1",
	said: [said("i1", "Fix it")],
	work: [],
	answer: undefined,
	changes: [],
	writing: { request: undefined, words: "", calls: [] },
	asking: undefined,
	asks: [],
	ending: { state: "replied" },
	startedAt: 1_000,
	endedAt: 9_000,
	...given,
});

const shape = (rows: readonly TimelineRow[]): readonly string[] => rows.map((row) => `${row.kind} ${row.room} ${row.key}`);

describe("the timeline's rows", () => {
	it("lays a turn out flat — its words, each part of its work, its reply and its end — each with the room above it", () => {
		const turn = turnOf({
			said: [said("i1", "Fix it"), said("i2", "And test it")],
			work: [
				{ kind: "thought", key: "r1:thought", text: "Look first.", took: 900 },
				callOf("c1"),
				{ kind: "words", key: "r2", text: "Reading on." },
				callOf("c2"),
			],
			answer: { key: "r3", text: "Fixed." },
		});
		expect(shape(rowsOf([{ kind: "turn", key: turn.key, turn }]))).toEqual([
			"said turn said:i1",
			"said message said:i2",
			"work message work:r1:thought",
			"work line work:c1",
			"work line words:r2",
			"work line work:c2",
			"reply part words:r3",
			"end part end:t1",
		]);
	});

	it("ends a turn that works with what it does now, one that ended with its changes and foot, and a part the person steered on with neither", () => {
		const working = turnOf({ ending: { state: "working" }, endedAt: undefined, asking: 2_000, changes: [{ path: "a.ts", added: 1, removed: 0 }] });
		const [, workingEnd] = rowsOf([{ kind: "turn", key: "t1", turn: working }]);
		expect(workingEnd?.kind === "end" ? [workingEnd.end.doing?.words, workingEnd.end.foot, workingEnd.end.changes.length] : []).toEqual([
			"Thinking",
			undefined,
			0,
		]);
		const ended = turnOf({ answer: { key: "r1", text: "Done." }, changes: [{ path: "a.ts", added: 1, removed: 0 }] });
		const endedEnd = rowsOf([{ kind: "turn", key: "t1", turn: ended }]).at(-1);
		expect(endedEnd?.kind === "end" ? [endedEnd.end.doing, endedEnd.end.foot?.reply, endedEnd.end.foot?.worked, endedEnd.end.changes.length] : []).toEqual([
			undefined,
			"Done.",
			"Worked for 8s",
			1,
		]);
		const steered = turnOf({ ending: { state: "steered" } });
		expect(shape(rowsOf([{ kind: "turn", key: "t1", turn: steered }]))).toEqual(["said turn said:i1"]);
	});

	it("gives what is the thread's own between turns a row each, with a turn's room above it", () => {
		const items: TimelineItem[] = [
			{ kind: "turn", key: "t1", turn: turnOf() },
			{ kind: "summed-up", key: "k1" },
			{ kind: "limited", key: "limited", limited: { reason: "used-up" } as never, resumingAt: undefined },
		];
		expect(shape(rowsOf(items)).slice(-2)).toEqual(["summed-up turn summed-up:k1", "limited turn limited"]);
	});

	it("keeps each row that did not change the same object, and gives a changed one anew", () => {
		// The client keeps an input and a call the same objects, and the page reads each once: the words and the line are the same.
		const words = said("i1", "Fix it");
		const line = callOf("c1");
		const working = (given: Partial<TimelineTurn>): TimelineItem => ({
			kind: "turn",
			key: "t1",
			turn: turnOf({ said: [words], ending: { state: "working" }, endedAt: undefined, ...given }),
		});
		const held = steadyRows(rowsOf([working({ work: [line] })]), new Map());
		// Words being written are a reply row of their own, known by the request writing them; the rows that were stay the same objects.
		const writing = steadyRows(rowsOf([working({ work: [line], writing: { request: "q1", words: "Fix", calls: [] } })]), held.byKey).rows;
		expect(writing.map((row) => row.key)).toEqual(["said:i1", "work:c1", "words:q1", "end:t1"]);
		expect(writing[2]?.kind === "reply" ? [writing[2].text, writing[2].writing] : []).toEqual(["Fix", true]);
		expect([writing[0], writing[1], writing[3]]).toEqual([held.rows[0], held.rows[1], held.rows[2]] as TimelineRow[]);
		[writing[0], writing[1], writing[3]].forEach((row, place) => expect(row).toBe(held.rows[place] as TimelineRow));
		// A call that joins makes a row of its own; the rows that were stay the same objects.
		const grown = steadyRows(rowsOf([working({ work: [line, { kind: "web-search", key: "w1", query: "zig" }] })]), held.byKey).rows;
		expect(grown.map((row) => row.key)).toEqual(["said:i1", "work:c1", "work:w1", "end:t1"]);
		expect(grown[0]).toBe(held.rows[0] as TimelineRow);
		expect(grown[1]).toBe(held.rows[1] as TimelineRow);
		expect(grown[3]).toBe(held.rows[2] as TimelineRow);
	});
});
