/**
 * The terminals the client follows, as views of what the node draws: each from the offset its view stands at — the
 * bytes it took of what the terminal wrote — its screen drawn anew first where it stands nowhere, and so again as each
 * connection opens, from where it stood; what comes past a gap, which nothing should send, has it drawn anew. The view
 * types into the terminal, tells the size it is shown at, and lets it go.
 */
import type { Connection } from "./connection.ts";
import type { Event } from "./protocol.ts";
import { ViewFollows } from "./views.ts";

/** A terminal's size, in cells. */
export type TerminalSize = { readonly rows: number; readonly cols: number };

/** What a terminal's view is told: its screen drawn anew, at the size the terminal is now; what it wrote. */
export type TerminalHandlers = {
	readonly screen: (drawn: Uint8Array, size: TerminalSize) => void;
	readonly output: (bytes: Uint8Array) => void;
};

/** A terminal as its view drives it: what the person types, the size the view shows it at, and letting it go. */
export type TerminalView = {
	write(data: string): void;
	resize(size: TerminalSize): void;
	stop(): void;
};

/** A terminal's events. */
type TerminalEvent = Extract<Event, { readonly terminal: string }>;

/**
 * A terminal followed: its view's handlers, the size its view shows it at, and the offset its view stands at — none
 * where it is to be drawn anew.
 */
type Followed = { readonly handlers: TerminalHandlers; size: TerminalSize; offset: number | undefined };

export class TerminalFollows {
	readonly #views: ViewFollows<Followed>;

	constructor(connection: Connection, told: (error: unknown) => void) {
		this.#views = new ViewFollows<Followed>(connection, told, (id, followed) => {
			const asked = { terminal: id, ...followed.size };
			connection.call("terminals.follow", followed.offset === undefined ? asked : { ...asked, from: followed.offset }).catch(told);
		});
	}

	/** Follows each terminal again, from where its view stood, as a connection opens. */
	again(): void {
		this.#views.again();
	}

	/** Gives a terminal's view an event of it, where it is followed. */
	take(event: TerminalEvent): void {
		const followed = this.#views.get(event.terminal);
		if (followed === undefined) return;
		switch (event.event) {
			case "terminal-screen":
				followed.offset = event.offset;
				followed.handlers.screen(bytesOf(event.screen), { rows: event.rows, cols: event.cols });
				return;
			case "terminal-output": {
				if (event.offset !== followed.offset) {
					followed.offset = undefined;
					this.#views.followAgain(event.terminal, followed);
					return;
				}
				const bytes = bytesOf(event.data);
				followed.offset = event.offset + bytes.length;
				followed.handlers.output(bytes);
				return;
			}
		}
	}

	/** Follows the terminal `id` for a view `size` big, told through `handlers`: its screen drawn first, then what it writes. */
	follow(id: string, size: TerminalSize, handlers: TerminalHandlers): TerminalView {
		const followed: Followed = { handlers, size, offset: undefined };
		this.#views.add(id, followed);
		return {
			write: (data) => this.#views.send("terminals.write", { terminal: id, data }),
			resize: (next) => this.#views.resize(followed, next, "terminals.resize", { terminal: id, ...next }),
			stop: () => this.#views.stop(id, followed, "terminals.unfollow", { terminal: id }),
		};
	}
}

/** The bytes base64 `text` holds. */
function bytesOf(text: string): Uint8Array {
	const binary = atob(text);
	return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}
