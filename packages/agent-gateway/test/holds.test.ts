/** Which session each conversation holds, as a file of lines keeps them across starts. */
import { describe, expect, it } from "bun:test";
import { appendFile, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Holds } from "../src/holds.ts";

describe("holds", () => {
	it("tells the session a conversation left where no other holds it, and keeps them all across a start", async () => {
		const folder = await mkdtemp(join(tmpdir(), "holds-"));
		try {
			const path = join(folder, "holds.jsonl");
			const holds = await Holds.open(path);
			expect(await holds.hold("thread-1", "S1")).toBeUndefined();
			expect(await holds.hold("thread-2", "S1")).toBeUndefined();
			// The other conversation still holds the session the first left.
			expect(await holds.hold("thread-1", "S2")).toBeUndefined();
			expect(await holds.hold("thread-2", "S3")).toBe("S1");
			expect(await holds.release("thread-1")).toBe("S2");
			// A crash cut the last line short; what came before it is kept, and what comes after begins on a line of its own.
			await appendFile(path, '{"conversation":"thread-9","sess');
			const reopened = await Holds.open(path);
			expect(reopened.sessionOf("thread-1")).toBeUndefined();
			expect(reopened.sessionOf("thread-2")).toBe("S3");
			expect(reopened.isHeld("S1")).toBe(false);
			await reopened.hold("thread-4", "S4");
			const again = await Holds.open(path);
			expect(again.sessionOf("thread-4")).toBe("S4");
			expect(again.sessionOf("thread-2")).toBe("S3");
		} finally {
			await rm(folder, { recursive: true, force: true });
		}
	});

	it("lets every conversation go of a session that is gone, and writes the file again once it holds far more lines than holds", async () => {
		const folder = await mkdtemp(join(tmpdir(), "holds-"));
		try {
			const path = join(folder, "holds.jsonl");
			const holds = await Holds.open(path);
			await holds.hold("thread-1", "S1");
			await holds.hold("thread-2", "S1");
			await holds.drop("S1");
			expect(holds.isHeld("S1")).toBe(false);
			for (let turn = 0; turn < 100; turn += 1) await holds.hold("thread-3", `S${turn % 2}`);
			const lines = (await readFile(path, "utf8")).split("\n").filter((line) => line !== "");
			expect(lines.length).toBeLessThan(70);
			expect((await Holds.open(path)).sessionOf("thread-3")).toBe("S1");
		} finally {
			await rm(folder, { recursive: true, force: true });
		}
	});
});
