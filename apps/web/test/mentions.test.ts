/** A file mentioned as the person writes, and the text with a link to the one chosen in its place. */
import { describe, expect, it } from "bun:test";
import { mentionAt, withMention } from "../src/core/mentions.ts";

describe("a mention", () => {
	it("is the `@` the caret ends, at the start or after a space, with what follows it", () => {
		expect(mentionAt("@src/ma", 7)).toEqual({ query: "src/ma", start: 0 });
		expect(mentionAt("look at @", 9)).toEqual({ query: "", start: 8 });
		expect(mentionAt("look at @main and", 13)).toEqual({ query: "main", start: 8 });
		expect(mentionAt("mail me@home", 12)).toBeUndefined();
		expect(mentionAt("look at @main and", 17)).toBeUndefined();
	});

	it("is replaced by a link to the path chosen, and a space after it", () => {
		const text = "read @ma please";
		const mention = mentionAt(text, 8);
		if (mention === undefined) throw new Error("no mention");
		const file = withMention(text, mention, 8, { path: "src/main.zig", kind: "file" });
		expect(file).toEqual({ text: "read [main.zig](src/main.zig) please", caret: 30 });
		expect(withMention("@sr", { query: "sr", start: 0 }, 3, { path: "src", kind: "directory" })).toEqual({ text: "[src/](src/) ", caret: 13 });
	});
});
