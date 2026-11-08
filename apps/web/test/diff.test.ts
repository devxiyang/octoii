/** Changes as the diff view shows them. */
import { describe, expect, it } from "bun:test";
import { defaultScope, diffTones, pathParts, scopeKey, scopeName, shortCount, totalsOf } from "../src/core/diff.ts";

describe("changes as the diff view shows them", () => {
	it("asks for a branch's changes where the repository has a base, else those not yet committed", () => {
		expect(defaultScope({ root: "/r", ahead: 0, behind: 0, base: "origin/main" })).toEqual({ type: "branch" });
		expect(defaultScope({ root: "/r", ahead: 0, behind: 0 })).toEqual({ type: "uncommitted" });
		expect(scopeKey({ type: "branch" })).toBe(scopeKey({ type: "branch" }));
		expect(scopeKey({ type: "commit", commit: "a" })).not.toBe(scopeKey({ type: "commit", commit: "b" }));
	});

	it("names a scope, a commit by its subject or its short id", () => {
		const commits = [{ commit: "0123456789abcdef", time: 0, subject: "Make it work" }];
		expect(scopeName({ type: "branch" }, commits)).toBe("Changes");
		expect(scopeName({ type: "uncommitted" }, commits)).toBe("Uncommitted");
		expect(scopeName({ type: "commit", commit: "0123456789abcdef" }, commits)).toBe("Make it work");
		expect(scopeName({ type: "commit", commit: "fedcba9876543210" }, commits)).toBe("Commit fedcba9");
	});

	it("tells the lines all the files gained and lost, in thousands past ten thousand", () => {
		const files = [
			{ path: "a", status: "modified", additions: 12_000, deletions: 3, binary: false },
			{ path: "b", status: "added", binary: true },
		] as const;
		expect(totalsOf(files)).toEqual({ additions: 12_000, deletions: 3 });
		expect(shortCount(9_999)).toBe("9999");
		expect(shortCount(21_182)).toBe("21k");
		expect(pathParts("apps/web/src/main.tsx")).toEqual({ folder: "apps/web/src/", name: "main.tsx" });
		expect(pathParts("README.md")).toEqual({ folder: "", name: "README.md" });
	});
	it("reads each line of a diff: within a hunk as its head counts each side, outside any by its first character", () => {
		expect(diffTones(["--- a.sql", "+++ a.sql", "@@ -1,2 +1,1 @@", "--- gone", " kept", "\\ No newline at end of file", "+ written by hand", "-also"])).toEqual(
			["head", "head", "head", "removed", "kept", "head", "added", "removed"],
		);
	});
});
