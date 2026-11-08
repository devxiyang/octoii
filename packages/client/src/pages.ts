/**
 * The browser's pages the client follows, as views of what the node draws: each handed every frame the browser paints
 * of it, the newest, those painted while it could not take them passed over. The view clicks, types into and scrolls
 * the page, tells the size it is shown at, and lets it go.
 */
import type { Connection } from "./connection.ts";
import type { Event, PageKey, PageMouse } from "./protocol.ts";
import { ViewFollows } from "./views.ts";

/** A page's view: CSS pixels across and down, and how many device pixels it draws each with. */
export type PageSize = { readonly width: number; readonly height: number; readonly scale: number };

/** A frame of a page: JPEG in base64, its size in the page's CSS pixels, and its number among the page's. */
export type PageFrame = { readonly data: string; readonly width: number; readonly height: number; readonly number: number };

/** What a page's view is told: each frame painted of it, the newest. */
export type PageHandlers = { readonly frame: (frame: PageFrame) => void };

/** A page as its view drives it: the person's mouse, keys and pasted text, the size the view shows it at, and letting it go. */
export type PageView = {
	mouse(event: PageMouse): void;
	key(event: PageKey): void;
	text(text: string): void;
	resize(size: PageSize): void;
	stop(): void;
};

/** A page's events. */
type PageEvent = Extract<Event, { readonly event: "page-frame" }>;

/** A page followed: its view's handlers, and the size its view shows it at. */
type Followed = { readonly handlers: PageHandlers; size: PageSize };

export class PageFollows {
	readonly #views: ViewFollows<Followed>;

	constructor(connection: Connection, told: (error: unknown) => void) {
		this.#views = new ViewFollows<Followed>(connection, told, (id, followed) => {
			connection.call("browser.follow", { page: id, ...followed.size }).catch(told);
		});
	}

	/** Follows each page again, as a connection opens. */
	again(): void {
		this.#views.again();
	}

	/** Gives a page's view a frame of it, where it is followed. */
	take(event: PageEvent): void {
		const followed = this.#views.get(event.page);
		if (followed === undefined) return;
		followed.handlers.frame({ data: event.data, width: event.width, height: event.height, number: event.frame });
	}

	/** Follows the page `id` for a view `size` big, told through `handlers`: its newest frame first, then each it paints. */
	follow(id: string, size: PageSize, handlers: PageHandlers): PageView {
		const followed: Followed = { handlers, size };
		this.#views.add(id, followed);
		return {
			mouse: (event) => this.#views.send("browser.mouse", { page: id, event }),
			key: (event) => this.#views.send("browser.key", { page: id, event }),
			text: (text) => this.#views.send("browser.text", { page: id, text }),
			resize: (next) => this.#views.resize(followed, next, "browser.resize", { page: id, ...next }),
			stop: () => this.#views.stop(id, followed, "browser.unfollow", { page: id }),
		};
	}
}
