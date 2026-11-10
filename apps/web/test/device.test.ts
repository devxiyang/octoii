/** What a device has set, read from what the browser kept: each field that fits, the defaults for the rest. */
import { describe, expect, it } from "bun:test";
import { DEVICE_DEFAULTS, deviceOf, isDark } from "../src/core/device.ts";
import { duration, mintedAt, pastLabel, runningTime, shortAgo } from "../src/core/time.ts";

describe("a device's settings", () => {
	it("keep each field the browser kept that fits, and the defaults for what it did not keep or keeps wrong", () => {
		expect(deviceOf(undefined)).toEqual(DEVICE_DEFAULTS);
		expect(deviceOf("not an object")).toEqual(DEVICE_DEFAULTS);
		const device = deviceOf({ theme: "dark", palette: "nowhere", sidebar_width: "wide", chat_width: "wide", other: 1 });
		expect(device).toEqual({ ...DEVICE_DEFAULTS, theme: "dark", chat_width: "wide" });
		expect([isDark("dark", false), isDark("system", true), isDark("light", true)]).toEqual([true, true, false]);
	});
});

describe("times as the page writes them", () => {
	it("read when an id was minted, how long something took or has run, and how long ago", () => {
		expect(mintedAt("018bcfe5-6800-7000-8000-000000000001")).toBe(0x018bcfe56800);
		expect(mintedAt("not an id")).toBe(0);
		expect([duration(12_400), duration(123_000), duration(3_840_000)]).toEqual(["12s", "2m 3s", "1h 4m"]);
		expect([runningTime(24_000), runningTime(725_000)]).toEqual(["0:24", "12:05"]);
		expect([shortAgo(30_000), shortAgo(240_000), shortAgo(3 * 3_600_000), shortAgo(2 * 86_400_000), shortAgo(35 * 86_400_000)]).toEqual([
			"now",
			"4m",
			"3h",
			"2d",
			"5w",
		]);
	});

	it("tell when a turn ended: the time alone that day, the day before it on another, and the year in another year", () => {
		const now = new Date(2026, 10, 10, 18, 30).getTime();
		const time = (at: Date): string => at.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
		const sameDay = new Date(2026, 10, 10, 9, 5);
		expect(pastLabel(sameDay.getTime(), now)).toBe(time(sameDay));
		const dayBefore = new Date(2026, 10, 9, 23, 59);
		expect(pastLabel(dayBefore.getTime(), now)).toBe(`${dayBefore.toLocaleDateString([], { month: "short", day: "numeric" })}, ${time(dayBefore)}`);
		const lastYear = new Date(2025, 11, 31, 8, 0);
		const label = pastLabel(lastYear.getTime(), now);
		expect(label).toContain("2025");
		expect(label.endsWith(time(lastYear))).toBe(true);
	});
});
