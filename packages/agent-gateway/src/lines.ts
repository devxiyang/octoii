/**
 * A file of lines, each a JSON value: appended to as what it keeps changes, and written again whole with what it keeps
 * now once it holds far more lines than that, as an append-only file is rewritten. A line not whole — as a crash leaves
 * the last — is passed over as it is read, and the next line written begins on a line of its own.
 */
import { appendFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import type { Json } from "./anthropic.ts";

export class LineFile {
	readonly #path: string;
	/** How many lines it holds. */
	#lines = 0;
	/** Whether it ends in a line not whole: the next line written begins on a line of its own. */
	#torn = false;

	private constructor(path: string) {
		this.#path = path;
	}

	/** The file at `path`, and the values of its whole lines; none where there is no file yet. */
	static async open(path: string): Promise<{ readonly file: LineFile; readonly values: readonly Json[] }> {
		const file = new LineFile(path);
		const text = await readFile(path, "utf8").catch((error: unknown) => {
			if (isMissing(error)) return "";
			throw error;
		});
		file.#torn = text.length > 0 && !text.endsWith("\n");
		const values: Json[] = [];
		for (const line of text.split("\n")) {
			const value = jsonOf(line);
			if (value === undefined) continue;
			values.push(value);
			file.#lines += 1;
		}
		return { file, values };
	}

	/** How many lines it holds. */
	get lines(): number {
		return this.#lines;
	}

	/** Adds `value` as a line of its own. */
	async append(value: object): Promise<void> {
		await mkdir(dirname(this.#path), { recursive: true });
		const torn = this.#torn;
		this.#torn = false;
		this.#lines += 1;
		await appendFile(this.#path, `${torn ? "\n" : ""}${JSON.stringify(value)}\n`);
	}

	/** Writes the file again with `values` alone. */
	async rewrite(values: readonly object[]): Promise<void> {
		await mkdir(dirname(this.#path), { recursive: true });
		await writeFile(this.#path, values.map((value) => `${JSON.stringify(value)}\n`).join(""));
		this.#lines = values.length;
		this.#torn = false;
	}
}

/** The JSON a whole line holds; none for one that holds none, as a line a crash cut does. */
function jsonOf(line: string): Json | undefined {
	if (line.trim() === "") return undefined;
	try {
		return JSON.parse(line);
	} catch {
		return undefined;
	}
}

function isMissing(error: unknown): boolean {
	return error instanceof Error && "code" in error && error.code === "ENOENT";
}
