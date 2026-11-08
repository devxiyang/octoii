/** A terminal as the interface names it on its tab. */
import { describe, expect, it } from "bun:test";
import { terminalName } from "../src/core/terminal.ts";

describe("a terminal's name", () => {
	it("is the title its program set, else its number in the thread", () => {
		expect(terminalName({ id: "t1", number: 2, title: "  npm run dev " })).toBe("npm run dev");
		expect(terminalName({ id: "t1", number: 2 })).toBe("Terminal 2");
		expect(terminalName({ id: "t1", number: 3, title: "   " })).toBe("Terminal 3");
	});
});
