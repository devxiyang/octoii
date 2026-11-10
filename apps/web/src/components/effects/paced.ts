/**
 * Words shown at an even pace as they are written: a model and the way to it send words in bursts — a few, then many at
 * once — and words shown as they come jump forward in those bursts. While words are written, what is shown follows them
 * a frame at a time, taking in a share of what it is behind each frame, so a burst is spread over a few frames and the
 * words move forward smoothly; what was there as the words were first drawn shows at once, and all of them once they
 * are written.
 */
import { useEffect, useState } from "react";

/** How many frames a burst of words is spread over, about: what is shown takes in this share of what it is behind each frame. */
const PACE_FRAMES = 6;

/** Of `text`, what is shown now: all of it, or, while it is `writing`, as far as the pace has come. */
export function usePaced(text: string, writing: boolean): string {
	const [shown, setShown] = useState(text.length);
	const behind = writing && shown < text.length;
	useEffect(() => {
		if (!behind) return undefined;
		const frame = requestAnimationFrame(() => setShown((was) => Math.min(text.length, was + Math.ceil((text.length - was) / PACE_FRAMES))));
		return () => cancelAnimationFrame(frame);
	}, [behind, shown, text.length]);
	if (!behind) return text;
	// A character written as two code units is not cut in half.
	const end = isHighSurrogate(text.charCodeAt(shown - 1)) ? shown + 1 : shown;
	return text.slice(0, end);
}

/** Whether a code unit is the first of two that write one character. */
function isHighSurrogate(unit: number): boolean {
	return unit >= 0xd800 && unit <= 0xdbff;
}
