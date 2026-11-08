/** The machine's files as the interface shows them, and the folders a folder is chosen among. */
import { describe, expect, it } from "bun:test";
import type { FolderEntry } from "@octoii-works/octoii-client";
import { bytesText, childPath, crumbsOf, folderOf, foldersAmong, isWholePath, lookOf, nameOf, shownEntries, wayTo } from "../src/core/files.ts";

const entry = (name: string, kind: FolderEntry["kind"] = "file", ignored = false): FolderEntry => ({ name, kind, ignored });

describe("the machine's files", () => {
	it("take a path whole from the root, a drive's, or the home folder", () => {
		expect(["/Users/me/app", "C:\\work", "~", "~/app", "app", "~app"].map(isWholePath)).toEqual([true, true, true, true, false, false]);
	});

	it("show a folder's names folders first, each in the node's order, .git left out", () => {
		const shown = shownEntries([
			entry(".git", "directory", true),
			entry(".gitignore"),
			entry("README.md"),
			entry("src", "directory"),
			entry("zig-out", "directory", true),
		]);
		expect(shown.map((each) => each.name)).toEqual(["src", "zig-out", ".gitignore", "README.md"]);
	});

	it("name the way from the folder the tree shows to a path under it", () => {
		expect(childPath("/work/app", "src")).toBe("/work/app/src");
		expect(childPath("/", "etc")).toBe("/etc");
		expect(nameOf("/work/app/")).toBe("app");
		expect([folderOf("src/protocol/fuzzy.zig"), folderOf("AGENTS.md")]).toEqual(["src/protocol", ""]);
		expect(crumbsOf("/work/app", "/work/app/src/main.zig")).toEqual([
			{ name: "app", path: "/work/app" },
			{ name: "src", path: "/work/app/src" },
			{ name: "main.zig", path: "/work/app/src/main.zig" },
		]);
		expect(crumbsOf("/work/app", "/work/app")).toEqual([{ name: "app", path: "/work/app" }]);
	});

	it("tell a length as a person reads it", () => {
		expect([bytesText(12), bytesText(2048), bytesText(1536), bytesText(5 * 1024 * 1024)]).toEqual(["12 bytes", "2 KB", "1.5 KB", "5 MB"]);
	});

	it("tell a file by its extension", () => {
		expect(["main.zig", "package.json", "README.md", "logo.png", "Makefile", ".env"].map(lookOf)).toEqual(["code", "data", "text", "image", "other", "other"]);
	});
});

describe("a folder chosen", () => {
	it("is reached by a way from the home folder where it is under it, else from the root", () => {
		expect(wayTo("/Users/me/code/app", "/Users/me").map((step) => [step.name, step.path])).toEqual([
			["~", "/Users/me"],
			["code", "/Users/me/code"],
			["app", "/Users/me/code/app"],
		]);
		expect(wayTo("/opt/tools", "/Users/me").map((step) => [step.name, step.path])).toEqual([
			["/", "/"],
			["opt", "/opt"],
			["tools", "/opt/tools"],
		]);
		expect(wayTo("/", undefined)).toEqual([{ name: "/", path: "/" }]);
	});

	it("is chosen among the folders and the links, which may be folders, hidden ones as asked", () => {
		const entries = [entry("code", "directory"), entry("code.txt"), entry("codex", "link"), entry(".config", "directory")];
		expect(foldersAmong(entries, false).map((each) => each.name)).toEqual(["code", "codex"]);
		expect(foldersAmong(entries, true).map((each) => each.name)).toEqual(["code", "codex", ".config"]);
	});
});
