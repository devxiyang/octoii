/**
 * Changes as the diff view shows them: the scope a view asks for where none was chosen, a scope's key and its name, the
 * lines its files gained and lost all told, a count as the toolbar writes it, a file's path as its row writes it, and
 * how each line of a diff reads.
 */
import type { Changed, ChangesScope, Commit, Repository } from "@octoii-works/octoii-client";

/** The scope a view asks for where none was chosen: the branch's changes where the repository has a base, else those not yet committed. */
export function defaultScope(repository: Repository): ChangesScope {
	return repository.base === undefined ? { type: "uncommitted" } : { type: "branch" };
}

/** A scope as a key, the same for two scopes that ask for the same changes: what a menu's choice of it holds. */
export function scopeKey(scope: ChangesScope): string {
	return JSON.stringify(scope);
}

/** A scope's name: Changes, for a branch's; Uncommitted; or the commit's subject, its short id where it is not known. */
export function scopeName(scope: ChangesScope, commits: readonly Commit[]): string {
	switch (scope.type) {
		case "branch":
			return "Changes";
		case "uncommitted":
			return "Uncommitted";
		case "commit":
			return commits.find((commit) => commit.commit === scope.commit)?.subject ?? `Commit ${scope.commit.slice(0, 7)}`;
	}
}

/** The lines the files gained and lost, all told; those not counted, none. */
export function totalsOf(files: readonly Changed[]): { readonly additions: number; readonly deletions: number } {
	let additions = 0;
	let deletions = 0;
	for (const file of files) {
		additions += file.additions ?? 0;
		deletions += file.deletions ?? 0;
	}
	return { additions, deletions };
}

/** A count as the toolbar writes it: as it is below ten thousand, else in thousands, `21k`. */
export function shortCount(count: number): string {
	return count < 10_000 ? String(count) : `${String(Math.round(count / 1000))}k`;
}

/** A file's path as its row writes it: the folder it is in, ending in a slash, and its name. */
export function pathParts(path: string): { readonly folder: string; readonly name: string } {
	const slash = path.lastIndexOf("/");
	return { folder: path.slice(0, slash + 1), name: path.slice(slash + 1) };
}

/** How a line of a diff reads: added, removed, held by both sides, or a head — a file's, a hunk's, a note. */
export type DiffTone = "added" | "removed" | "kept" | "head";

/**
 * How each of a diff's lines reads, in order: within a hunk as its head counts the lines of each side, so a removed line
 * that begins with dashes is still removed; outside any — as a diff written by hand has none — by its first character,
 * a file's `--- ` and `+++ ` lines heads.
 */
export function diffTones(lines: readonly string[]): readonly DiffTone[] {
	let before = 0;
	let after = 0;
	return lines.map((line): DiffTone => {
		if (line.startsWith("\\")) return "head";
		if (before > 0 || after > 0) {
			const tone = markedTone(line);
			if (tone !== "added") before -= 1;
			if (tone !== "removed") after -= 1;
			return tone;
		}
		const hunk = /^@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@/.exec(line);
		if (hunk !== null) {
			before = Number(hunk[1] ?? 1);
			after = Number(hunk[2] ?? 1);
			return "head";
		}
		return line.startsWith("--- ") || line.startsWith("+++ ") || line.startsWith("@@") ? "head" : markedTone(line);
	});
}

/** How a diff's line reads by its first character: added, removed, else held by both sides. */
function markedTone(line: string): DiffTone {
	return line.startsWith("+") ? "added" : line.startsWith("-") ? "removed" : "kept";
}
