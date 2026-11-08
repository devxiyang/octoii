/**
 * What a paged read of the node's answers, read so far: its first page read as any read is, the pages after it as the
 * person asks for more, put together; read again from its first page as a connection opens, the pages after let go
 * with the one they followed — a folder's names, a file's lines.
 */
import { useState } from "react";
import type { MethodName, ParamsOf, ResultOf } from "@octoii-works/octoii-client";
import { useClient } from "@octoii-works/octoii-client/react";
import { failureOf, useOutcome } from "./read.ts";

/**
 * A paged read as read so far: its pages, what reads the next where more follow, and why the last read of one failed,
 * where it did; or why its first page could not be read.
 */
export type Pages<Page> =
	| { readonly pages: readonly [Page, ...Page[]]; readonly readMore: (() => void) | undefined; readonly failure?: string }
	| { readonly failure: string };

/** The pages read after the first, and the first they follow; why the last read of one failed, where it did. */
type After<Page> = { readonly first: Page; readonly pages: readonly Page[]; readonly failure?: string };

/** The pages of `method` from `params`, `next` giving the params of the page after a page, none where none follows; none till the first is answered. */
export function usePages<Name extends MethodName>(
	method: Name,
	params: ParamsOf<Name>,
	next: (last: ResultOf<Name>) => ParamsOf<Name> | undefined,
): Pages<ResultOf<Name>> | undefined {
	const client = useClient();
	const outcome = useOutcome(method, params);
	const [after, setAfter] = useState<After<ResultOf<Name>> | undefined>(undefined);
	if (outcome === undefined) return undefined;
	if ("failure" in outcome) return outcome;
	const first = outcome.result;
	const read = after?.first === first ? after : { first, pages: [] };
	const following = next(read.pages.at(-1) ?? first);
	const readMore =
		following === undefined
			? undefined
			: (): void => {
					client.call(method, following).then(
						(page) => setAfter({ first, pages: [...read.pages, page] }),
						(error: unknown) => setAfter({ ...read, failure: failureOf(error) }),
					);
				};
	return { pages: [first, ...read.pages], readMore, ...(read.failure === undefined ? {} : { failure: read.failure }) };
}
