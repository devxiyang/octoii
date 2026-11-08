/** Kept files read through a tunnel, and the requests that send and pair, whichever way the page reaches its node. */
import { describe, expect, it } from "bun:test";
import { keepFile } from "../src/app/files.ts";
import { pairBrowser } from "../src/app/pairing.ts";
import type { NodeAnswer, NodeRequest } from "../src/components/state/reach.ts";
import { createFileSources } from "../src/hosted/file-sources.ts";

function answer(status: number, text: string, contentType?: string): NodeAnswer {
	return { status, contentType, bytes: new TextEncoder().encode(text) };
}

describe("kept files read through a tunnel", () => {
	it("reads a file once, and again only after it was let go", async () => {
		const asked: string[] = [];
		const source = createFileSources(async (address) => {
			asked.push(address);
			return answer(200, "bytes", "image/png");
		});
		const first = await source("/files/a");
		expect(await source("/files/a")).toBe(first);
		expect(asked).toEqual(["/files/a"]);
		for (let index = 0; index < 128; index++) await source(`/files/${String(index)}`);
		await source("/files/a");
		expect(asked.filter((address) => address === "/files/a")).toHaveLength(2);
	});

	it("opens nothing that could run in the page as itself", async () => {
		const typed = async (contentType: string): Promise<string> =>
			(await (await fetch(await createFileSources(async () => answer(200, "x", contentType))("/files/a"))).blob()).type;
		expect(await typed("image/png")).toStartWith("image/png");
		expect(await typed("application/pdf")).toStartWith("application/pdf");
		expect(await typed("text/html; charset=utf-8")).toStartWith("text/plain");
		expect(await typed("image/svg+xml")).toStartWith("text/plain");
	});

	it("reads a file again after a failed read", async () => {
		const answers = [answer(404, ""), answer(200, "x", "image/png")];
		const source = createFileSources(async () => answers.shift() ?? answer(500, ""));
		await expect(source("/files/a")).rejects.toThrow("(404)");
		expect(await source("/files/a")).toStartWith("blob:");
	});
});

describe("the requests beside the socket", () => {
	const refusing = async (): Promise<NodeAnswer> => answer(403, JSON.stringify({ message: "That link was spent." }));

	it("tell the node's words where it refuses, and its status where it gives none", async () => {
		await expect(pairBrowser(refusing, "c")).rejects.toThrow("That link was spent.");
		await expect(pairBrowser(async () => answer(502, "<html>"), "c")).rejects.toThrow("(502)");
		await expect(keepFile(refusing, new Blob(["x"]))).rejects.toThrow("That link was spent.");
	});

	it("send a credential as JSON, and give back what was kept", async () => {
		const sent: NodeRequest[] = [];
		await pairBrowser(async (request) => {
			sent.push(request);
			return answer(200, "{}");
		}, "c");
		expect(sent).toEqual([{ method: "POST", path: "/api/auth/session", contentType: "application/json", body: '{"credential":"c"}' }]);
		expect(await keepFile(async () => answer(200, JSON.stringify({ ref: "sha256:a", size: 1 })), new Blob(["x"]))).toEqual({ ref: "sha256:a", size: 1 });
	});
});
