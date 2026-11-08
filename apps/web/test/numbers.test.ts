/** The interface's numbers as it writes them, in its own language whatever the browser's. */
import { describe, expect, it } from "bun:test";
import { dollarsFormat, NUMBERS_LOCALE, tokens } from "../src/core/numbers.ts";

describe("the numbers", () => {
	it("count tokens shortly", () => {
		expect([tokens(812), tokens(12_345), tokens(400_000), tokens(999_990), tokens(1_500_000)]).toEqual(["812", "12.3K", "400K", "1M", "1.5M"]);
	});

	it("write dollars to the hundredth of a cent below a dollar, to the cent above", () => {
		const written = (dollars: number): string => new Intl.NumberFormat(NUMBERS_LOCALE, dollarsFormat(dollars)).format(dollars);
		expect(written(0.0042)).toBe("$0.0042");
		expect(written(1.234)).toBe("$1.23");
	});
});
