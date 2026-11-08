/**
 * A message's Markdown as the page draws it: its directives — a page of the thread's as its card, any other as it was
 * written, and the words a line holds whole however many colons they hold — and an image of the web as a link, never
 * fetched.
 */
import { describe, expect, it } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { Prose } from "../src/components/thread/markdown.tsx";

const drawn = (text: string): string => renderToStaticMarkup(<Prose text={text} />);

describe("a message's Markdown", () => {
	it("keeps the words a line holds whole, however many colons they hold", () => {
		const html = drawn("Error:failed at 10:30, mode:auto on example.com/a:b");
		expect(html).toContain("Error:failed at 10:30, mode:auto on example.com/a:b");
	});

	it("draws a page the reply points at as its card, and gives any other directive back as it was written", () => {
		expect(drawn('::page{id="p1"}')).toContain("A page no longer open");
		expect(drawn('::video{src="a.mp4"}')).toContain("<p>::video{src=&quot;a.mp4&quot;}</p>");
		expect(drawn(":::note\nsome words\n:::")).toContain("<p>:::note\nsome words\n:::</p>");
		expect(drawn("::page")).toContain("<p>::page</p>");
	});

	it("draws an image of the web as a link to it, never fetching it", () => {
		const html = drawn("![the logo](https://example.com/logo.png)");
		expect(html).toContain('href="https://example.com/logo.png"');
		expect(html).toContain("the logo");
		expect(html).not.toContain("<img");
	});
});
