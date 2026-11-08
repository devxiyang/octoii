/**
 * A sign-in finished from the address the browser was sent back to, once the connection is open: how it went — under
 * way, done to its provider, or failed with the node's words.
 */
import { useEffect, useState } from "react";
import { useClient, useConnection } from "@octoii-works/octoii-client/react";

/** How a sign-in being finished stands. */
export type Finishing =
	| { readonly state: "finishing" }
	| { readonly state: "done"; readonly provider: string }
	| { readonly state: "failed"; readonly message: string };

/** Finishes the sign-in from `returned`, where there is one; how it went. */
export function useSignInFinish(returned: string | undefined): Finishing | undefined {
	const client = useClient();
	const open = useConnection().status === "open";
	const [finishing, setFinishing] = useState<Finishing | undefined>(returned === undefined ? undefined : { state: "finishing" });
	useEffect(() => {
		if (returned === undefined || !open || finishing?.state !== "finishing") return;
		client.finishSignIn(returned).then(
			(provider) => setFinishing({ state: "done", provider }),
			(error: unknown) => setFinishing({ state: "failed", message: error instanceof Error ? error.message : String(error) }),
		);
	}, [client, returned, open, finishing?.state]);
	return finishing;
}
