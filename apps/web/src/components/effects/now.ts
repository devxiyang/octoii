/**
 * The time, counted again every `intervalMs` while a component that reads it is drawn: one clock for each interval,
 * however many components read it, so what counts the same seconds turns at once; and none ticks while nothing reads it.
 */
import { type ReactNode, useSyncExternalStore } from "react";

/** A clock as React reads it: what listens to it, and the time it last read. */
type Clock = { readonly subscribe: (listener: () => void) => () => void; readonly read: () => number };

const clocks = new Map<number, Clock>();

/** The clock of `intervalMs`, made as it is first read: its timer runs while something listens, the time read anew as it starts. */
function clockOf(intervalMs: number): Clock {
	const known = clocks.get(intervalMs);
	if (known !== undefined) return known;
	const listeners = new Set<() => void>();
	let now = Date.now();
	let timer: ReturnType<typeof setInterval> | undefined;
	const tick = (): void => {
		now = Date.now();
		for (const listener of [...listeners]) listener();
	};
	const clock: Clock = {
		subscribe: (listener) => {
			listeners.add(listener);
			if (timer === undefined) {
				now = Date.now();
				timer = setInterval(tick, intervalMs);
			}
			return () => {
				listeners.delete(listener);
				if (listeners.size > 0) return;
				clearInterval(timer);
				timer = undefined;
			};
		},
		read: () => now,
	};
	clocks.set(intervalMs, clock);
	return clock;
}

export function useNow(intervalMs: number): number {
	const clock = clockOf(intervalMs);
	return useSyncExternalStore(clock.subscribe, clock.read);
}

/**
 * How long it has been since `since`, in ms, as `written` writes it, counted again each second: this component alone
 * drawn again as it counts, not the line around it.
 */
export function Counting(props: { readonly since: number; readonly written: (ms: number) => ReactNode }): ReactNode {
	return props.written(useNow(1_000) - props.since);
}
