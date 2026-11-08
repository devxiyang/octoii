/**
 * What one of the node's read methods answers, read when the component that asks first draws, again when its params
 * change or the revision it is read at does, and again as a connection opens: its result, or the words the node
 * refused it with — for what a picker shows as it opens, such as the models, and what the files and diff views read.
 * What was read stays shown while it is read again at a later revision. Where there is nothing to read yet, as before
 * a mention is written, no params are given and nothing is read.
 */
import { useEffect, useState } from "react";
import type { MethodName, ParamsOf, ResultOf } from "@octoii-works/octoii-client";
import { useClient, useConnection } from "@octoii-works/octoii-client/react";

/** What a read came to: the method's result, or the words the node refused it with. */
export type Outcome<Result> = { readonly result: Result } | { readonly failure: string };

/** The words an error is told in. */
export function failureOf(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

/** What the read came to; none till it is answered, nor where no params are given. */
export function useOutcome<Name extends MethodName>(
	method: Name,
	params: ParamsOf<Name> | undefined,
	revision: string | number = 0,
): Outcome<ResultOf<Name>> | undefined {
	const client = useClient();
	const open = useConnection().status === "open";
	const asked = params === undefined ? undefined : JSON.stringify(params);
	const [read, setRead] = useState<{ readonly asked: string; readonly outcome: Outcome<ResultOf<Name>> } | undefined>(undefined);
	useEffect(() => {
		if (!open || asked === undefined) return undefined;
		let current = true;
		// SAFETY: `asked` is the JSON of the params the caller typed, so it parses back to them.
		const again = JSON.parse(asked) as ParamsOf<Name>;
		client.call(method, again).then(
			(result) => {
				if (current) setRead({ asked, outcome: { result } });
			},
			(error: unknown) => {
				if (current) setRead({ asked, outcome: { failure: failureOf(error) } });
			},
		);
		return () => {
			current = false;
		};
	}, [client, method, asked, open, revision]);
	return asked !== undefined && read?.asked === asked ? read.outcome : undefined;
}

/** What the read answers; none till it is answered, nor where it was refused. */
export function useRead<Name extends MethodName>(method: Name, params: ParamsOf<Name>): ResultOf<Name> | undefined {
	const outcome = useOutcome(method, params);
	return outcome !== undefined && "result" in outcome ? outcome.result : undefined;
}
