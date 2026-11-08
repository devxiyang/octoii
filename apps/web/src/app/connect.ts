/**
 * The page's client of the node: one WebSocket to the node, by the page's reach of it, opened again as it drops.
 * Everything the page shows and does goes over it, but the bytes of the files a message gives, posted to the node.
 */
import { type Client, type Clock, createClient } from "@octoii-works/octoii-client";
import { keepFile } from "./files.ts";
import { failed } from "../components/state/notices.ts";
import type { Reach } from "../components/state/reach.ts";

const clock: Clock = {
	now: () => Date.now(),
	setTimer: (callback, ms) => {
		const timer = setTimeout(callback, ms);
		return () => clearTimeout(timer);
	},
};

/** A client of the node `reach` reaches. */
export function connect(reach: Reach): Client {
	return createClient({
		open: reach.open,
		randomUUID: () => crypto.randomUUID(),
		clock,
		report: (error) => failed("Something asked of the node failed", error),
		keepFile: (bytes) => keepFile(reach.send, bytes),
	});
}
