/**
 * A floating surface's positioner that holds its place while it closes: the anchor may move or go as the surface fades,
 * so the surface fades where it was rather than jumping.
 */
import { type ComponentProps, type CSSProperties, useState } from "react";

const PLACEMENT_KEYS = ["position", "top", "right", "bottom", "left", "transform"] as const;

type Placement = Pick<CSSProperties, (typeof PLACEMENT_KEYS)[number]>;

function ClosingPositioner({ open, style, ...props }: ComponentProps<"div"> & { readonly open: boolean }) {
	const [openPlacement, setOpenPlacement] = useState<Placement>({});
	if (open && style !== undefined && PLACEMENT_KEYS.some((key) => style[key] !== openPlacement[key])) {
		const { position, top, right, bottom, left, transform } = style;
		setOpenPlacement({ position, top, right, bottom, left, transform });
	}
	return <div {...props} style={open ? style : { ...style, ...openPlacement }} />;
}

/** The `render` of a Base UI positioner that holds its place while it closes. */
export function renderClosingPositioner(props: ComponentProps<"div">, state: { readonly open: boolean }) {
	return <ClosingPositioner {...props} open={state.open} />;
}
