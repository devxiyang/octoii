/** An image the node keeps, drawn from wherever the page can read it. */
import type { ComponentProps, ReactNode } from "react";
import { useFileSource } from "../effects/file-source.ts";

/** The image at `address`. */
export function KeptImage(props: Omit<ComponentProps<"img">, "src"> & { readonly address: string }): ReactNode {
	const { address, alt, ...image } = props;
	return <img {...image} alt={alt} src={useFileSource(address)} />;
}
