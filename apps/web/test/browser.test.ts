/** The browser as the interface shows it. */
import { describe, expect, it } from "bun:test";
import { addressOf, editingOf, modifiersOf, pageName, shownAddress, typedBy } from "../src/core/browser.ts";

describe("the address bar", () => {
	it("takes an address as it is, gives a host its scheme, and searches for the rest", () => {
		expect(addressOf("https://example.com/a")).toBe("https://example.com/a");
		expect(addressOf("about:blank")).toBe("about:blank");
		expect(addressOf("example.com/docs")).toBe("https://example.com/docs");
		expect(addressOf("localhost:5173")).toBe("http://localhost:5173");
		expect(addressOf("127.0.0.1:8080/x")).toBe("http://127.0.0.1:8080/x");
		expect(addressOf("zig std io")).toBe("https://duckduckgo.com/?q=zig%20std%20io");
		expect(addressOf("octoii")).toBe("https://duckduckgo.com/?q=octoii");
	});

	it("shows no address for a blank page", () => {
		expect(shownAddress("about:blank")).toBe("");
		expect(shownAddress("https://a.dev/")).toBe("https://a.dev/");
	});
});

describe("a page on its tab", () => {
	const page = { id: "p", url: "https://docs.example.com/a", title: "", loading: false, back: false, forward: false };
	it("is named by its title, else its host, else New tab", () => {
		expect(pageName({ ...page, title: "Docs" })).toBe("Docs");
		expect(pageName(page)).toBe("docs.example.com");
		expect(pageName({ ...page, url: "about:blank" })).toBe("New tab");
	});
});

describe("a key and its modifiers", () => {
	it("are told as the browser's protocol counts them", () => {
		expect(modifiersOf({ altKey: true, ctrlKey: false, metaKey: true, shiftKey: true })).toBe(13);
		expect(typedBy("a")).toBe("a");
		expect(typedBy("中")).toBe("中");
		expect(typedBy("Enter")).toBe("\r");
		expect(typedBy("ArrowLeft")).toBeUndefined();
	});
});

describe("a shortcut in a page", () => {
	const plain = { altKey: false, ctrlKey: false, metaKey: false, shiftKey: false };
	it("stands for the editing Cmd or Ctrl binds, and nothing else does", () => {
		expect(editingOf({ ...plain, metaKey: true, code: "KeyA" })).toEqual(["selectAll"]);
		expect(editingOf({ ...plain, ctrlKey: true, code: "KeyZ" })).toEqual(["undo"]);
		expect(editingOf({ ...plain, metaKey: true, shiftKey: true, code: "KeyZ" })).toEqual(["redo"]);
		expect(editingOf({ ...plain, code: "KeyA" })).toBeUndefined();
		expect(editingOf({ ...plain, metaKey: true, altKey: true, code: "KeyA" })).toBeUndefined();
		expect(editingOf({ ...plain, metaKey: true, code: "KeyQ" })).toBeUndefined();
	});
});
