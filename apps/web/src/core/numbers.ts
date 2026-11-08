/**
 * How the interface writes its numbers, in its own language whatever the browser's: a count of tokens — 812, 12.3K,
 * 400K, 1.5M — and an amount of dollars, to the hundredth of a cent below a dollar and to the cent above; as text, and
 * as the formats rolling numbers take.
 */

/** The language numbers are written in: the page's own. */
export const NUMBERS_LOCALE = "en-US";

/** How a count of tokens is written. */
export const TOKENS_FORMAT = { notation: "compact", maximumFractionDigits: 1 } as const satisfies Intl.NumberFormatOptions;

/** A count of tokens, written. */
export function tokens(count: number): string {
	return new Intl.NumberFormat(NUMBERS_LOCALE, TOKENS_FORMAT).format(count);
}

/** How an amount of `dollars` is written. */
export function dollarsFormat(dollars: number) {
	const digits = dollars >= 1 ? 2 : 4;
	return { style: "currency", currency: "USD", minimumFractionDigits: digits, maximumFractionDigits: digits } as const satisfies Intl.NumberFormatOptions;
}

/** An amount of dollars, written. */
export function dollars(amount: number): string {
	return new Intl.NumberFormat(NUMBERS_LOCALE, dollarsFormat(amount)).format(amount);
}
