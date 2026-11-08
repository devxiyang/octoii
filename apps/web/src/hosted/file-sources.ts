/**
 * Kept files read through the tunnel for elements to draw: each read once into an address of this page, and the ones
 * read longest ago let go, as a page may show a long thread's every picture.
 */
import type { NodeAnswer } from "../components/state/reach.ts";
import { succeeded } from "../components/state/reach.ts";

/** How many files are kept read. */
const KEPT = 128;

/** The types a file opens as itself. A machine's other files open as plain text, so what they hold never runs in this page's origin. */
function safeType(contentType: string | undefined): string {
	const type = contentType?.split(";")[0]?.trim().toLowerCase() ?? "";
	return (type.startsWith("image/") && type !== "image/svg+xml") || type === "application/pdf" ? type : "text/plain";
}

/** Reads files at their addresses by `read`, into addresses of this page. */
export function createFileSources(read: (address: string) => Promise<NodeAnswer>): (address: string) => Promise<string> {
	const sources = new Map<string, Promise<string>>();
	const readOnce = async (address: string): Promise<string> => {
		const answer = await read(address);
		if (!succeeded(answer)) throw new Error(`The node did not give the file (${String(answer.status)}).`);
		return URL.createObjectURL(new Blob([new Uint8Array(answer.bytes)], { type: safeType(answer.contentType) }));
	};
	const letGoOfOldest = (): void => {
		const oldest = sources.keys().next().value;
		if (oldest === undefined) return;
		const going = sources.get(oldest);
		sources.delete(oldest);
		void going?.then(
			(source) => URL.revokeObjectURL(source),
			() => undefined,
		);
	};
	return (address) => {
		const kept = sources.get(address);
		if (kept !== undefined) {
			sources.delete(address);
			sources.set(address, kept);
			return kept;
		}
		const reading = readOnce(address).catch((error: unknown) => {
			sources.delete(address);
			throw error;
		});
		sources.set(address, reading);
		if (sources.size > KEPT) letGoOfOldest();
		return reading;
	};
}
