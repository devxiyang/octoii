/**
 * Where an element reads a kept file from: its address, where the browser can fetch it itself; else what the page's
 * reach makes of it, once it has read it.
 */
import { useContext, useEffect, useState } from "react";
import { ReachContext } from "../state/reach.ts";

/** What `address` is read from now; none till it has been read. */
export function useFileSource(address: string): string | undefined {
	const fileSource = useContext(ReachContext)?.fileSource;
	const [read, setRead] = useState<{ readonly address: string; readonly source: string } | undefined>(undefined);
	useEffect(() => {
		if (fileSource === undefined) return undefined;
		let current = true;
		fileSource(address).then(
			(source) => {
				if (current) setRead({ address, source });
			},
			// A file that cannot be read stays undrawn, as an image the browser could not fetch does.
			() => undefined,
		);
		return () => {
			current = false;
		};
	}, [address, fileSource]);
	if (fileSource === undefined) return address;
	return read?.address === address ? read.source : undefined;
}
