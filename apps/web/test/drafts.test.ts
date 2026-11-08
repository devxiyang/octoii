import { describe, expect, it } from "bun:test";
import { draftKey } from "../src/core/drafts.ts";

describe("a draft's place", () => {
	it("is its thread, or a new thread of its project or of none", () => {
		expect(draftKey({ thread: "t1" })).toBe("t1");
		expect(draftKey({ project: "/work/octoii" })).toBe("new:/work/octoii");
		expect(draftKey({ project: undefined })).toBe("new:");
	});
});
