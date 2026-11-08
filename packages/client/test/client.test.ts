/**
 * The client against a node in memory: greeted as the session its socket holds, its calls answered by their ids, a thread it
 * follows fed from where its reader stood after a drop, a person's input delivered once though the drop cut its answer
 * off, and what the node sends that the protocol does not hold reported, never taken.
 */
import { describe, expect, test } from "bun:test";
import { type Client, ClientError, createClient, InvalidValueError } from "../src/index.ts";
import { FakeClock, FakeNode, settle } from "./fake-node.ts";

/** A client of `node`, its operations' ids counted, what fails no caller kept in `reported`, keeping `entriesKept` of a thread's entries. */
function clientOf(node: FakeNode, clock: FakeClock, reported: unknown[] = [], entriesKept?: number): Client {
	let minted = 0;
	return createClient({
		open: () => node.open(),
		randomUUID: () => `op-${++minted}`,
		clock,
		report: (error) => reported.push(error),
		...(entriesKept === undefined ? {} : { entriesKept }),
	});
}

describe("a client of the node's protocol", () => {
	test("says hello as the session its socket holds, and its calls are answered by their ids", async () => {
		const node = new FakeNode();
		const client = clientOf(node, new FakeClock());
		await settle();
		expect(client.status.value).toEqual({ status: "open", session: "s1", scopes: ["threads.read", "threads.operate"], environment: "Test Mac" });
		expect(node.received[0]).toEqual({ id: "1", method: "hello", params: { protocol: 1 } });
		const thread = await client.create({ title: "First" });
		const listed = await client.threads();
		expect(listed.map((each) => [each.id, each.manifest.title])).toEqual([[thread, "First"]]);
		client.close();
	});

	test("a thread followed is fed its entries and its state, and followed again from where its reader stood after a drop", async () => {
		const node = new FakeNode();
		const clock = new FakeClock();
		const client = clientOf(node, clock);
		await settle();
		const thread = await client.create({});
		const following = client.follow(thread);
		await client.deliver(thread, { message: { role: "user", content: "one" } });
		await settle();
		expect(following.view().entries.map((entry) => entry.id)).toEqual(["e1"]);
		expect(following.view().state?.status).toBe("created");

		// Away, the client misses an entry; back, it is fed that one alone.
		node.drop();
		await settle();
		expect(client.status.value.status).toBe("waiting");
		node.append(thread, "two");
		clock.advance(500);
		await settle();
		expect(client.status.value.status).toBe("open");
		expect(node.follows.map((each) => each.from)).toEqual([undefined, { segment: "s", offset: 1 }]);
		expect(following.view().entries.map((entry) => entry.id)).toEqual(["e1", "e2"]);
		following.release();
		client.close();
	});

	test("a thread followed keeps its latest entries alone, as many as the client keeps, and reads older ones back on asking", async () => {
		const node = new FakeNode();
		const client = clientOf(node, new FakeClock(), [], 3);
		await settle();
		const thread = await client.create({});
		for (const said of ["1", "2", "3", "4", "5"]) node.append(thread, said);
		const following = client.follow(thread);
		await settle();
		const ids = (): string[] => following.view().entries.map((entry) => entry.id);
		expect(ids()).toEqual(["e3", "e4", "e5"]);
		expect(following.view().complete).toBe(false);
		// Past its bound, the oldest is let go as an entry is appended.
		node.append(thread, "6");
		await settle();
		expect(ids()).toEqual(["e4", "e5", "e6"]);
		// Read back on asking, the older entries are kept too, to the log's start.
		await client.readOlder(thread);
		expect(ids()).toEqual(["e1", "e2", "e3", "e4", "e5", "e6"]);
		expect(following.view().complete).toBe(true);
		node.append(thread, "7");
		await settle();
		expect(ids()).toEqual(["e2", "e3", "e4", "e5", "e6", "e7"]);
		expect(following.view().complete).toBe(false);
		following.release();
		client.close();
	});

	test("an input whose answer a drop cut off is asked again under the same operation, and taken once", async () => {
		const node = new FakeNode();
		const clock = new FakeClock();
		const client = clientOf(node, clock);
		await settle();
		const thread = await client.create({});
		node.dropAfter = "threads.deliver";
		const delivered = client.deliver(thread, { message: { role: "user", content: "once" } });
		await settle();
		expect(client.status.value.status).toBe("waiting");
		clock.advance(500);
		await settle();
		expect(await delivered).toBe("e1");
		expect(node.entriesOf(thread)).toHaveLength(1);
		const operations = node.received.filter((asked) => asked.method === "threads.deliver").map((asked) => asked.params?.["operation"]);
		expect(operations).toEqual(["op-2", "op-2"]);
		client.close();
	});

	test("a client that holds no session is told so while it waits, and a version the node does not speak stops it", async () => {
		const stranger = new FakeNode();
		stranger.session = undefined;
		const clock = new FakeClock();
		const waiting = createClient({ open: () => stranger.open(), randomUUID: () => "op", clock, report: () => undefined });
		await settle();
		const status = waiting.status.value;
		expect(status.status === "waiting" ? status.error?.code : undefined).toBe("not-admitted");
		waiting.close();

		const newer = new FakeNode();
		newer.greeting = "refuse-protocol";
		const stopped = clientOf(newer, new FakeClock());
		await settle();
		const ended = stopped.status.value;
		expect(ended.status === "stopped" ? ended.error.code : undefined).toBe("protocol");
		await expect(stopped.threads()).rejects.toBeInstanceOf(ClientError);
	});

	test("the threads watched are the list as it stood, then each row as it changes, and the list anew after a drop", async () => {
		const node = new FakeNode();
		const clock = new FakeClock();
		const client = clientOf(node, clock);
		await settle();
		const first = await client.create({ title: "first" });
		const watching = client.watchThreads();
		await settle();
		expect(watching.view()?.map((row) => row.id)).toEqual([first]);
		const second = await client.create({ title: "second" });
		await settle();
		expect(watching.view()?.map((row) => row.id)).toEqual([second, first]);

		// Away, the client misses a thread another made; back, the list it watches anew holds it.
		node.drop();
		await settle();
		const third = node.make("third");
		clock.advance(500);
		await settle();
		expect(watching.view()?.map((row) => [row.id, row.manifest.title])).toEqual([
			[third, "third"],
			[second, "second"],
			[first, "first"],
		]);
		watching.release();
		await settle();
		expect(node.received.at(-1)?.method).toBe("threads.unwatch");
		client.close();
	});

	test("the settings watched are one watch for all who read them, each change as it comes, watched anew after a drop", async () => {
		const node = new FakeNode();
		const clock = new FakeClock();
		const client = clientOf(node, clock);
		await settle();
		const one = client.watchSettings();
		const other = client.watchSettings();
		await settle();
		expect(node.received.filter((asked) => asked.method === "settings.watch")).toHaveLength(1);
		expect(one.view()?.environment.thread_mode).toBe("default");
		await client.setSettings({ device: { theme: "dark" }, environment: { thread_mode: "auto" } });
		await settle();
		expect(other.view()).toEqual({ environment: { thread_mode: "auto", favorite_models: [] }, device: { theme: "dark" } });

		// Away, the client misses a change another device made; back, the settings it watches anew hold it.
		node.drop();
		await settle();
		node.setSettings({ environment: { thread_mode: "full-access", favorite_models: [] }, device: { theme: "dark" } });
		clock.advance(500);
		await settle();
		expect(one.view()?.environment.thread_mode).toBe("full-access");
		one.release();
		other.release();
		await settle();
		expect(node.received.at(-1)?.method).toBe("settings.unwatch");
		client.close();
	});

	test("what streams of a request is taken by its offset: sent again from its start after a drop, it is held once", async () => {
		const node = new FakeNode();
		const clock = new FakeClock();
		const client = clientOf(node, clock);
		await settle();
		const thread = await client.create({});
		const following = client.follow(thread);
		await settle();
		node.publish(thread, "r1", "a");
		node.publish(thread, "r1", "b");
		await settle();
		expect(following.view().streaming.get("r1")).toEqual(["a", "b"]);
		node.drop();
		await settle();
		clock.advance(500);
		await settle();
		node.publish(thread, "r1", "c");
		await settle();
		expect(following.view().streaming.get("r1")).toEqual(["a", "b", "c"]);
		following.release();
		client.close();
	});

	test("what streams of a request is kept while the state holds the request open, and let go once it does not", async () => {
		const node = new FakeNode();
		const clock = new FakeClock();
		const client = clientOf(node, clock);
		await settle();
		const thread = await client.create({});
		const following = client.follow(thread);
		// Till its latest entries are read, what it holds is not the thread yet.
		expect(following.view().read).toBe(false);
		await settle();
		expect(following.view().read).toBe(true);
		const stateWith = (requests: { key: string; name: string }[]): string =>
			JSON.stringify({
				event: "state",
				thread,
				state: { status: "running", inbox: [], processes: [{ key: "k1", program: "siphon.call", state: "sleeping", requests }] },
			});
		node.sendRaw(stateWith([{ key: "r1", name: "tool" }]));
		node.publish(thread, "r1", { text: "one\n" });
		await settle();
		expect(following.view().streaming.get("r1")).toEqual([{ text: "one\n" }]);
		// Answered, the request is open no more: what came of it is the log's.
		node.sendRaw(stateWith([]));
		await settle();
		expect(following.view().streaming.has("r1")).toBe(false);
		following.release();
		client.close();
	});

	test("what the node sends that the protocol does not hold is reported, never taken", async () => {
		const node = new FakeNode();
		const reported: unknown[] = [];
		const client = clientOf(node, new FakeClock(), reported);
		await settle();
		const thread = await client.create({});
		const following = client.follow(thread);
		await settle();
		node.sendRaw(JSON.stringify({ event: "entries", thread, entries: [{ id: "x", type: "no-such-type" }] }));
		await settle();
		expect(reported).toHaveLength(1);
		expect(reported[0]).toBeInstanceOf(InvalidValueError);
		expect(following.view().entries).toEqual([]);
		following.release();
		client.close();
	});

	test("follows a terminal, its screen drawn first, then what it writes, and from where its view stood after a drop", async () => {
		const node = new FakeNode();
		const clock = new FakeClock();
		const client = clientOf(node, clock);
		await settle();
		node.terminalWrites("x1", "before ");
		const told: string[] = [];
		const text = (bytes: Uint8Array): string => new TextDecoder().decode(bytes);
		const view = client.terminal(
			"x1",
			{ rows: 24, cols: 80 },
			{
				screen: (drawn, size) => told.push(`screen ${text(drawn)}${String(size.cols)}`),
				output: (bytes) => told.push(`output ${text(bytes)}`),
			},
		);
		await settle();
		node.terminalWrites("x1", "after");
		await settle();
		expect(told).toEqual(["screen before 80", "output after"]);

		// Followed again from where its view stood once a connection opens anew: what it wrote meanwhile, and no screen.
		node.drop();
		await settle();
		node.terminalWrites("x1", " meanwhile");
		clock.advance(500);
		await settle();
		expect(told.at(-1)).toBe("output  meanwhile");

		// Resized meanwhile, its view is followed again at the size it is shown at now.
		view.resize({ rows: 30, cols: 100 });
		await settle();
		node.drop();
		await settle();
		clock.advance(500);
		await settle();
		expect(node.terminalFollows).toEqual([
			{ terminal: "x1", rows: 24, cols: 80, from: undefined },
			{ terminal: "x1", rows: 24, cols: 80, from: 12 },
			{ terminal: "x1", rows: 30, cols: 100, from: 22 },
		]);
		view.write("ls\n");
		await settle();
		expect(node.received.at(-1)).toEqual({ id: expect.any(String), method: "terminals.write", params: { terminal: "x1", data: "ls\n" } });
		view.stop();
		client.close();
	});

	test("follows a page, its newest frame handed to its view, and follows it again at its view's size after a drop", async () => {
		const node = new FakeNode();
		const clock = new FakeClock();
		const client = clientOf(node, clock);
		await settle();
		const frames: string[] = [];
		const view = client.page("p1", { width: 800, height: 600, scale: 2 }, { frame: (frame) => frames.push(`${String(frame.number)} ${String(frame.width)}`) });
		await settle();
		expect(frames).toEqual(["1 800"]);
		view.resize({ width: 640, height: 480, scale: 2 });
		await settle();
		node.drop();
		await settle();
		clock.advance(500);
		await settle();
		expect(node.pageFollows).toEqual([
			{ page: "p1", width: 800, height: 600, scale: 2 },
			{ page: "p1", width: 640, height: 480, scale: 2 },
		]);
		expect(frames.at(-1)).toBe("2 640");
		view.stop();
		client.close();
	});
});
