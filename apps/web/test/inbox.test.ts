/** The inbox: what waits on the person, what runs and what was done of late, each newest first, read from the threads' rows. */
import { describe, expect, it } from "bun:test";
import type { Listed, Manifest, State } from "@octoii-works/octoii-client";
import { DONE_SHOWN, inboxOf } from "../src/core/inbox.ts";
import { askedAt, asksOf } from "../src/core/threads.ts";

/** An id minted at `ms`, as a UUIDv7 holds its time in its first 48 bits. */
function idAt(ms: number, serial: number): string {
	const time = ms.toString(16).padStart(12, "0");
	return `${time.slice(0, 8)}-${time.slice(8)}-7000-8000-${String(serial).padStart(12, "0")}`;
}

const NOW = 1_700_000_000_000;

/** A thread's row: at rest, as its state says otherwise. */
const row = (id: string, state: Partial<State> = {}, manifest: Partial<Manifest> = {}): Listed => ({
	id,
	manifest: { vocabulary: 1, mode: "default", ...manifest },
	state: { status: "replied", inbox: [], processes: [], ...state },
});

/** A turn that ran a minute ago, for half of it. */
const ran: Partial<State> = { began_at: NOW - 60_000, ended_at: NOW - 30_000 };

/** A state that waits on the person for the request minted at `at`. */
const asking = (at: number): Partial<State> => ({
	status: "running",
	began_at: NOW - 60_000,
	processes: [
		{ key: `call-${String(at)}`, program: "siphon.call", state: "sleeping", requests: [{ key: idAt(at, 1), name: "permission", payload: {}, answer: {} }] },
	],
});

describe("the inbox", () => {
	it("holds what waits on the person, a sub-thread's among it, newest first, snoozed or not", () => {
		const rows = [
			row("parent", { status: "running", began_at: NOW - 60_000 }),
			row("sub", asking(NOW - 5_000), { parent: { thread: "parent", call: "c1" } }),
			row("older", asking(NOW - 60_000), { snoozed_until: NOW + 3_600_000 }),
		];
		const inbox = inboxOf(rows, NOW);
		expect(inbox.asking.map((each) => each.id)).toEqual(["sub", "older"]);
		// The parent's work goes on, waiting on the person through its sub-thread.
		expect(inbox.working.map((each) => each.id)).toEqual(["parent"]);
		expect(inbox.standingOf(rows[0] ?? row("x"))).toEqual({ status: "asks", since: NOW - 5_000 });
		expect(askedAt(rows[1] ?? row("x"))).toBe(NOW - 5_000);
		expect(asksOf(rows[1] ?? row("x"))).toMatchObject([{ fiber: `call-${String(NOW - 5_000)}`, call: undefined, request: { name: "permission" } }]);
	});

	it("holds a thread at rest whose sub-thread runs among what runs, since that began, not among what was done", () => {
		const rows = [row("sub", { status: "running", began_at: NOW - 2_000 }, { parent: { thread: "parent", call: "c" } }), row("parent", ran)];
		const inbox = inboxOf(rows, NOW);
		expect(inbox.working.map((each) => each.id)).toEqual(["parent"]);
		expect(inbox.done).toEqual([]);
		expect(inbox.standingOf(rows[1] ?? row("x"))).toEqual({ status: "working", since: NOW - 2_000 });
	});

	it("holds the top threads that run, and those done of late — failed ones among them — newest first, at most as many as it shows", () => {
		const done = Array.from({ length: DONE_SHOWN + 2 }, (_, index) => row(`done-${String(index)}`, { ...ran, ended_at: NOW - index * 1000 }));
		const rows = [
			...done,
			row("failed", { ...ran, status: "failed", ended_at: NOW + 1000 }),
			row("running", { status: "running", began_at: NOW - 1000 }),
			row("running sub", { status: "running", began_at: NOW - 1000 }, { parent: { thread: "running", call: "c" } }),
			row("never ran"),
			row("archived", ran, { archived: true }),
			row("snoozed", ran, { snoozed_until: NOW + 1000 }),
		];
		const inbox = inboxOf(rows, NOW);
		expect(inbox.working.map((each) => each.id)).toEqual(["running"]);
		expect(inbox.done).toHaveLength(DONE_SHOWN);
		expect(inbox.done.slice(0, 3).map((each) => each.id)).toEqual(["failed", "done-0", "done-1"]);
		expect(inbox.done.some((each) => ["never ran", "archived", "snoozed", "running sub"].includes(each.id))).toBe(false);
	});
});
