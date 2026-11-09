/** The threads as the sidebar shows them, read from their rows as the node lists them. */
import { describe, expect, it } from "bun:test";
import type { Listed, State } from "@octoii-works/octoii-client";
import { monogramHue } from "../src/core/monogram.ts";
import {
	activeAt,
	arrivedAt,
	canMarkUnread,
	folderName,
	isOpen,
	isUnread,
	lineOf,
	matchingRows,
	OPEN_FOR_MS,
	projectHues,
	projectOf,
	projectsOf,
	rowsBySection,
	snoozeTimes,
	standingsOf,
	statusOf,
	subThreadOf,
	subThreadsBy,
	subThreadsOf,
	threadTitle,
	titleOf,
} from "../src/core/threads.ts";

const idle: State = { status: "replied", inbox: [], processes: [] };

/** A thread working in `project`'s folder, its project that folder. */
const row = (id: string, project: string | undefined, state: State = idle, title?: string): Listed => ({
	id,
	manifest: { vocabulary: 1, mode: "default", ...(project === undefined ? {} : { workspace: project, project }), ...(title === undefined ? {} : { title }) },
	state,
});

/** `sub`, delegated to by the thread `parent`. */
const delegated = (sub: Listed, parent: string): Listed => ({ ...sub, manifest: { ...sub.manifest, parent: { thread: parent, call: `call-${sub.id}` } } });

/** An id minted at `ms`, as a UUIDv7 holds its time in its first 48 bits. */
function idAt(ms: number): string {
	const time = ms.toString(16).padStart(12, "0");
	return `${time.slice(0, 8)}-${time.slice(8)}-7000-8000-000000000001`;
}

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

/** A thread a call of which asks the person to let it, the ask minted at `at`. */
const asking = (at: number): State => ({
	...idle,
	status: "running",
	began_at: at - 10,
	processes: [{ key: "call", program: "siphon.call", state: "sleeping", requests: [{ key: idAt(at), name: "permission", answer: {} }] }],
});

describe("the threads", () => {
	it("stand as what waits on the person first, then work, then how the last turn ended", () => {
		const asking: State = {
			status: "running",
			inbox: [],
			processes: [{ key: "trust-1", program: "siphon.trust", state: "sleeping", requests: [{ key: "a", name: "trust", answer: {} }] }],
		};
		expect(statusOf(row("1", undefined, asking))).toBe("asks");
		expect(statusOf(row("2", undefined, { ...idle, status: "running" }))).toBe("working");
		expect(statusOf(row("3", undefined, { ...idle, inbox: [{ id: "i", actor: "person", message: { role: "user", content: "hi" } }] }))).toBe("working");
		expect(statusOf(row("4", undefined, { ...idle, status: "failed" }))).toBe("failed");
		expect(statusOf(row("5", undefined))).toBe("ready");
	});

	it("belong to their project, the repository they work in, the projects in the order of their newest threads", () => {
		const rows = [row("3", "/w/b/"), row("2", "/w/a"), row("1", "/w/b"), row("0", undefined)];
		expect(projectOf(rows[1] ?? row("x", undefined))).toEqual({ folder: "/w/a", name: "a" });
		const within = row("4", "/w/a");
		expect(projectOf({ ...within, manifest: { ...within.manifest, workspace: "/w/a/docs" } })).toEqual({ folder: "/w/a", name: "a" });
		expect(projectsOf(rows).map((project) => project.folder)).toEqual(["/w/b/", "/w/a", "/w/b"]);
		expect([folderName("/w/b/"), folderName("C:\\work\\app")]).toEqual(["b", "app"]);
	});

	it("draw each project in a hue of its own, the one whose first thread was made first choosing first", () => {
		const older = row(idAt(1_000), "/w/octoii");
		const newer = row(idAt(2_000), "/w/octoii-cloud");
		const hues = projectHues([newer, older]);
		expect(hues.get("/w/octoii")).toBe(monogramHue("octoii"));
		expect(hues.get("/w/octoii-cloud")).not.toBe(hues.get("/w/octoii"));
		// A project that comes later leaves the hues of those before it as they were.
		const later = projectHues([row(idAt(3_000), "/w/beak"), newer, older]);
		expect([later.get("/w/octoii"), later.get("/w/octoii-cloud")]).toEqual([hues.get("/w/octoii"), hues.get("/w/octoii-cloud")]);
	});

	it("are found by their titles and projects, and those that work are kept apart", () => {
		const rows = [row("2", "/w/octoii", { ...idle, ended_at: 900 }, "Fix the build"), row("1", undefined, { ...idle, status: "running" })];
		expect(matchingRows(rows, "BUILD").map((each) => each.id)).toEqual(["2"]);
		expect(matchingRows(rows, "octo").map((each) => each.id)).toEqual(["2"]);
		const { open, working } = rowsBySection(rows, 1_000, standingsOf(rows));
		expect([open.map((each) => each.id), working.map((each) => each.id)]).toEqual([["2"], ["1"]]);
		expect([threadTitle(rows[0] ?? row("x", undefined)), threadTitle(rows[1] ?? row("x", undefined))]).toEqual(["Fix the build", "New thread"]);
	});

	it("stand open while they ask the person, or brought them something within a week; else among the earlier, by themselves", () => {
		const now = 30 * DAY;
		const rows = [
			row("never ran", undefined),
			row("last week", undefined, { ...idle, ended_at: now - 8 * DAY }),
			row("this morning", undefined, { ...idle, ended_at: now - HOUR }),
			row("asked long ago", undefined, asking(now - 20 * DAY)),
			row("a minute ago", undefined, { ...idle, status: "failed", ended_at: now - MINUTE }),
			row("last month", undefined, { ...idle, ended_at: now - 25 * DAY }),
		];
		const { open, earlier } = rowsBySection(rows, now, standingsOf(rows));
		// What asks the person stands first, however long it has waited; then what came, the latest first.
		expect(open.map((each) => each.id)).toEqual(["asked long ago", "a minute ago", "this morning"]);
		expect(earlier.map((each) => each.id)).toEqual(["last week", "last month", "never ran"]);
		expect(isOpen(rows[2] ?? row("x", undefined), standingsOf(rows)(rows[2] ?? row("x", undefined)), now + OPEN_FOR_MS)).toBe(false);
	});

	it("pinned stand atop, snoozed apart till their time comes, and archived in no section", () => {
		const now = 1_000_000;
		const resting: State = { ...idle, ended_at: now - 1 };
		const rows = [
			{ ...row("5", undefined), manifest: { ...row("5", undefined).manifest, pinned: true } },
			{ ...row("4", undefined, resting), manifest: { ...row("4", undefined).manifest, snoozed_until: now + 1 } },
			{ ...row("3", undefined, resting), manifest: { ...row("3", undefined).manifest, snoozed_until: now - 1 } },
			{ ...row("2", undefined, resting), manifest: { ...row("2", undefined).manifest, archived: true } },
			row("1", undefined, resting),
		];
		const sections = rowsBySection(rows, now, standingsOf(rows));
		expect(sections.pinned.map((each) => each.id)).toEqual(["5"]);
		expect(sections.snoozed.map((each) => each.id)).toEqual(["4"]);
		expect(sections.open.map((each) => each.id)).toEqual(["3", "1"]);
		expect([sections.working, sections.earlier]).toEqual([[], []]);
	});

	it("brought the person something as they asked, or as their last turn ended; unread till the person has seen it", () => {
		const resting = row("1", undefined, { ...idle, ended_at: 5_000 });
		const standingOf = standingsOf([resting]);
		expect(arrivedAt(resting, standingOf(resting))).toBe(5_000);
		expect(isUnread(resting, standingOf(resting))).toBe(true);
		const seen = { ...resting, manifest: { ...resting.manifest, seen_until: 5_000 } };
		expect([isUnread(seen, standingOf(seen)), canMarkUnread(seen, standingOf(seen))]).toEqual([false, true]);
		// A turn that ends after what was seen brings something new.
		const again = { ...seen, state: { ...seen.state, ended_at: 9_000 } };
		expect([isUnread(again, standingOf(again)), canMarkUnread(again, standingOf(again))]).toEqual([true, false]);
		// What works, or never ran, brought nothing yet: never unread, nothing to mark unread.
		const working = row("2", undefined, { ...idle, status: "running", began_at: 9_500 });
		const never = row("3", undefined);
		for (const each of [working, never]) {
			expect(arrivedAt(each, standingsOf([each])(each))).toBe(0);
			expect([isUnread(each, standingsOf([each])(each)), canMarkUnread(each, standingsOf([each])(each))]).toEqual([false, false]);
		}
		// What a sub-thread asks the person is its parent's to bring: the parent's card stands for it.
		const parent = row("4", undefined, { ...idle, ended_at: 1_000 });
		const sub = delegated(row("5", undefined, asking(7_000)), "4");
		const tree = standingsOf([parent, sub]);
		expect(arrivedAt(parent, tree(parent))).toBe(7_000);
	});

	it("stand for their sub-threads, which are in no section where they are among the rows", () => {
		const parent = row("2", undefined);
		const sub = delegated(row("3", undefined, { ...idle, status: "running", began_at: 50 }), "2");
		const orphan = delegated(row("4", undefined, { ...idle, ended_at: 60 }), "9");
		const rows = [orphan, sub, parent];
		const sections = rowsBySection(rows, 100, standingsOf(rows));
		// The parent works while its sub-thread does, though it is at rest itself.
		expect(sections.working.map((each) => each.id)).toEqual(["2"]);
		expect(sections.open.map((each) => each.id)).toEqual(["4"]);
		expect(subThreadsOf(rows, "2").map((each) => each.id)).toEqual(["3"]);
		expect(
			subThreadsBy(rows)
				.get("2")
				?.map((each) => each.id),
		).toEqual(["3"]);
	});

	it("stand with their sub-threads at any depth: waiting on the person first, since the newest ask; then working, since the first began", () => {
		const top = row("1", undefined, { ...idle, status: "running", began_at: 100 });
		const middle = delegated(row("2", undefined, { ...idle, status: "running", began_at: 200 }), "1");
		const deepest = delegated(row("3", undefined, asking(5_000)), "2");
		const resting = row("4", undefined, { ...idle, began_at: 300 });
		const background = delegated(row("5", undefined, { ...idle, status: "running", began_at: 400 }), "4");
		const archived = delegated({ ...row("6", undefined, asking(9_000)), manifest: { ...row("6", undefined).manifest, archived: true } }, "4");
		const standingOf = standingsOf([top, middle, deepest, resting, background, archived]);
		expect(standingOf(top)).toEqual({ status: "asks", since: 5_000 });
		expect(standingOf(middle)).toEqual({ status: "asks", since: 5_000 });
		// An archived sub-thread's ask is none of its parent's.
		expect(standingOf(resting)).toEqual({ status: "working", since: 400 });
		// One at rest stands so since its last turn ended, or since it began where the end is not told.
		expect(standingOf(row("7", undefined, { ...idle, status: "failed", began_at: 700, ended_at: 750 }))).toEqual({ status: "failed", since: 750 });
		expect(standingOf(row("8", undefined, { ...idle, began_at: 800 }))).toEqual({ status: "ready", since: 800 });
	});

	it("are marked with those above them: the thread a sub-thread works for, and on up", () => {
		const rows = [delegated(row("3", undefined), "2"), delegated(row("2", undefined), "1"), row("1", undefined)];
		expect(lineOf(rows, "3")).toEqual(["3", "2", "1"]);
		expect(lineOf(rows, "1")).toEqual(["1"]);
		// A line of parents that came back on itself ends where it would.
		expect(lineOf([delegated(row("8", undefined), "9"), delegated(row("9", undefined), "8")], "8")).toEqual(["8", "9"]);
	});

	it("were last at work as their latest turn began, else as they were made", () => {
		const made = row("01900000-0000-7000-8000-000000000001", undefined);
		expect(activeAt(made)).toBe(0x01900000_0000);
		expect(activeAt({ ...made, state: { ...made.state, began_at: 1_700_000_000_000, ended_at: 1_700_000_005_000 } })).toBe(1_700_000_000_000);
	});

	it("find the sub-thread a delegating call gave its task to among the thread's own: the one it names, or the one it made", () => {
		const parent = row("2", undefined);
		const sub = { ...row("3", undefined), manifest: { ...row("3", undefined).manifest, parent: { thread: "2", call: "c1" } } };
		const others = { ...row("4", undefined), manifest: { ...row("4", undefined).manifest, parent: { thread: "9", call: "c2" } } };
		const rows = [others, sub, parent];
		expect(subThreadOf(rows, "2", { fiber: "c1", thread: undefined })?.id).toBe("3");
		expect(subThreadOf(rows, "2", { fiber: "c7", thread: "3" })?.id).toBe("3");
		// Another thread's sub-thread, or the thread itself, is none of its own.
		expect(subThreadOf(rows, "2", { fiber: "c7", thread: "4" })).toBeUndefined();
		expect(subThreadOf(rows, "2", { fiber: "c7", thread: "2" })).toBeUndefined();
		expect(subThreadOf(rows, "2", { fiber: undefined, thread: undefined })).toBeUndefined();
	});

	it("are snoozed till an hour on, this evening before five, tomorrow at nine, or next Monday at nine", () => {
		const wednesday = new Date(2026, 10, 4, 10, 30).getTime();
		const times = snoozeTimes(wednesday);
		expect(times.map((each) => each.label)).toEqual(["In an hour", "This evening", "Tomorrow", "Next week"]);
		expect(new Date(times[1]?.until ?? 0).getHours()).toBe(18);
		expect(new Date(times[2]?.until ?? 0).getDate()).toBe(5);
		expect(new Date(times[3]?.until ?? 0).getDay()).toBe(1);
		expect(new Date(times[3]?.until ?? 0).getDate()).toBe(9);
		const late = snoozeTimes(new Date(2026, 10, 4, 20, 0).getTime());
		expect(late.map((each) => each.label)).toEqual(["In an hour", "Tomorrow", "Next week"]);
	});

	it("take their title from the first line of their first message, its links by their words, cut at a word", () => {
		expect(titleOf("  Fix the build\nIt fails on Linux")).toBe("Fix the build");
		const long = `${"word ".repeat(30)}end`;
		expect(titleOf(long).endsWith("…")).toBe(true);
		expect(titleOf(long).length).toBeLessThanOrEqual(81);
		expect(titleOf("What does [fuzzy.zig](packages/siphon/src/protocol/fuzzy.zig) do?")).toBe("What does fuzzy.zig do?");
	});
});
