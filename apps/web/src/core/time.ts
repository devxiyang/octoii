/** Times as the page writes them: when an id was minted, how long something took or has run, and how long ago. */

/** The milliseconds an id was minted at: a UUIDv7's first 48 bits. */
export function mintedAt(id: string): number {
	const time = Number.parseInt(id.replaceAll("-", "").slice(0, 12), 16);
	return Number.isFinite(time) ? time : 0;
}

/** How long something took, as a turn's line says it: "12s", "2m 3s", "1h 4m". */
export function duration(ms: number): string {
	const seconds = Math.max(0, Math.round(ms / 1000));
	if (seconds < 60) return `${seconds}s`;
	const minutes = Math.floor(seconds / 60);
	if (minutes < 60) return `${minutes}m ${seconds % 60}s`;
	return `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
}

/** How long a call took, as its line says it: nothing under a tenth of a second; to a tenth under ten, "0.4s", "1.5s"; then as a turn's. */
export function callDuration(ms: number): string | undefined {
	if (ms < 100) return undefined;
	return ms < 10_000 ? `${(ms / 1000).toFixed(1)}s` : duration(ms);
}

/** How long something has run, as the design writes it: 0:24, 12:05. */
export function runningTime(ms: number): string {
	const seconds = Math.max(0, Math.floor(ms / 1000));
	return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

/** How long ago something moved, as a row says it: now, 4m, 3h, 2d, 5w. */
export function shortAgo(ms: number): string {
	const minutes = Math.floor(ms / 60_000);
	if (minutes < 1) return "now";
	if (minutes < 60) return `${minutes}m`;
	const hours = Math.floor(minutes / 60);
	if (hours < 24) return `${hours}h`;
	const days = Math.floor(hours / 24);
	return days < 7 ? `${days}d` : `${Math.floor(days / 7)}w`;
}

/** When a time to come is, as a snooze names it: its hour and minute that day, its weekday before them on another. */
export function wakeLabel(at: number, now: number): string {
	const day = new Date(at);
	const time = day.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
	if (day.toDateString() === new Date(now).toDateString()) return time;
	return `${day.toLocaleDateString([], { weekday: "short" })} ${time}`;
}
