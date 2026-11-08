/**
 * What the client follows of what the node draws for a thread — a terminal's screen, a page's frames — as tmux's
 * clients attach to its panes and a VNC viewer to a framebuffer: each followed at the size its view shows it in, which
 * the node fits the drawing to with every other client's view; followed again as each connection opens; and driven
 * only while it is followed and the connection open, as it is followed again on the next.
 */
import type { Connection } from "./connection.ts";
import type { MethodName, ParamsOf } from "./protocol.ts";

/** What a view followed holds: at least the size it is shown at. */
type Viewed = { size: unknown };

export class ViewFollows<Followed extends Viewed> {
	readonly #followed = new Map<string, Followed>();
	readonly #connection: Connection;
	/** Tells of a failure that is not the connection's own. */
	readonly #told: (error: unknown) => void;
	/** Asks the node to follow `id` for what `followed` holds, telling a failure as `told` does. */
	readonly #follow: (id: string, followed: Followed) => void;

	constructor(connection: Connection, told: (error: unknown) => void, follow: (id: string, followed: Followed) => void) {
		this.#connection = connection;
		this.#told = told;
		this.#follow = follow;
	}

	/** Follows each view again, from where it stood, as a connection opens. */
	again(): void {
		for (const [id, followed] of this.#followed) this.followAgain(id, followed);
	}

	/** The view of `id`, where one is followed. */
	get(id: string): Followed | undefined {
		return this.#followed.get(id);
	}

	/** Follows `id` for `followed`, in place of any view before: at once where the connection is open, else as it opens. */
	add(id: string, followed: Followed): void {
		this.#followed.set(id, followed);
		if (this.#isOpen()) this.followAgain(id, followed);
	}

	/** Asks the node to follow `id` again for `followed`, as its view stands now. */
	followAgain(id: string, followed: Followed): void {
		this.#follow(id, followed);
	}

	/** Calls `method` where the connection is open: a view drives what it shows only while it is followed. */
	send<Name extends MethodName>(method: Name, params: ParamsOf<Name>): void {
		if (this.#isOpen()) this.#connection.call(method, params).catch(this.#told);
	}

	/** The view `followed` of `id` shown at `size` now, told by `method`. */
	resize<Name extends MethodName>(followed: Followed, size: Followed["size"], method: Name, params: ParamsOf<Name>): void {
		followed.size = size;
		this.send(method, params);
	}

	/** Lets go of the view `followed` of `id`, where it is still the one followed, told by `method`. */
	stop<Name extends MethodName>(id: string, followed: Followed, method: Name, params: ParamsOf<Name>): void {
		if (this.#followed.get(id) !== followed) return;
		this.#followed.delete(id);
		this.send(method, params);
	}

	#isOpen(): boolean {
		return this.#connection.status.value.status === "open";
	}
}
