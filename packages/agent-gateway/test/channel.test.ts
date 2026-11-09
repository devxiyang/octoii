/** The channel the node holds the gateway by: HTTP carried as JSON-RPC, a message a line. */
import { describe, expect, it } from "bun:test";
import { serve } from "../src/channel.ts";

/** Lines a test gives as it goes, ended when it says. */
function linesOf(): { lines: AsyncIterable<string>; push: (message: object) => void; end: () => void } {
	const queue: string[] = [];
	let wake: (() => void) | undefined;
	let ended = false;
	return {
		lines: {
			async *[Symbol.asyncIterator]() {
				for (;;) {
					const next = queue.shift();
					if (next !== undefined) {
						yield next;
						continue;
					}
					if (ended) return;
					await new Promise<void>((resolve) => {
						wake = resolve;
					});
				}
			},
		},
		push: (message) => {
			queue.push(JSON.stringify(message));
			wake?.();
		},
		end: () => {
			ended = true;
			wake?.();
		},
	};
}

/** Lets the event loop turn till `done` holds, as the channel's work is all in memory: no time passes. */
async function until(done: () => boolean): Promise<void> {
	for (let turns = 0; !done(); turns += 1) {
		if (turns > 1_000) throw new Error("the channel never came to what the test waits for");
		await new Promise((resolve) => setTimeout(resolve, 0));
	}
}

describe("the channel", () => {
	it("carries a request whole and answers it by its id: its head, its body piece by piece, then its result", async () => {
		const { lines, push, end } = linesOf();
		const written: Record<string, unknown>[] = [];
		const served = serve(
			lines,
			(line) => written.push(JSON.parse(line)),
			async (request) => {
				expect(request.method).toBe("POST");
				expect(new URL(request.url).pathname).toBe("/claude/v1/messages");
				expect(request.headers.get("content-type")).toBe("application/json");
				expect(await request.json()).toEqual({ model: "m" });
				return new Response(new ReadableStream({ start: (controller) => (controller.enqueue(new TextEncoder().encode("event: a\n\n")), controller.close()) }), {
					status: 200,
					headers: { "content-type": "text/event-stream" },
				});
			},
		);
		push({
			jsonrpc: "2.0",
			id: 7,
			method: "http",
			params: { method: "POST", path: "/claude/v1/messages", headers: [["content-type", "application/json"]], body: '{"model":"m"}' },
		});
		push({ jsonrpc: "2.0", id: 8, method: "http", params: { path: "/no-method" } });
		await until(() => written.some((message) => message["id"] === 7) && written.some((message) => message["id"] === 8));
		end();
		await served;
		expect(written).toContainEqual({ jsonrpc: "2.0", method: "http/head", params: { id: 7, status: 200, headers: [["content-type", "text/event-stream"]] } });
		expect(written).toContainEqual({ jsonrpc: "2.0", method: "http/body", params: { id: 7, data: "event: a\n\n" } });
		expect(written.at(-1)).toEqual({ jsonrpc: "2.0", id: 7, result: {} });
		expect(written).toContainEqual({ jsonrpc: "2.0", id: 8, error: { code: -32_602, message: "an http request names its method and path" } });
	});

	it("ends a request cancelled, its handler's signal aborted and nothing more said of it", async () => {
		const { lines, push, end } = linesOf();
		const written: Record<string, unknown>[] = [];
		let aborted = false;
		const served = serve(
			lines,
			(line) => written.push(JSON.parse(line)),
			async (request) => {
				request.signal.addEventListener("abort", () => {
					aborted = true;
				});
				return new Response(new ReadableStream({ start: (controller) => controller.enqueue(new TextEncoder().encode("first")) }), { status: 200 });
			},
		);
		push({ jsonrpc: "2.0", id: "x", method: "http", params: { method: "POST", path: "/claude/v1/messages", body: "{}" } });
		await until(() => written.length === 2);
		push({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: "x" } });
		await until(() => aborted);
		end();
		await served;
		expect(aborted).toBe(true);
		expect(written.map((message) => message["method"] ?? "answer")).toEqual(["http/head", "http/body"]);
	});
});
