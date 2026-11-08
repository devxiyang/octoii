/**
 * The address a sign-in sent this page back to, where the page was opened at one: kept as the page starts, and taken
 * once by the page that finishes it.
 */

let returned: string | undefined;

/** Keeps the address the page was opened at, as it starts. */
export function keepSignInReturn(address: string): void {
	returned = address;
}

/** The address kept, taken: none after the first take. */
export function takeSignInReturn(): string | undefined {
	const taken = returned;
	returned = undefined;
	return taken;
}
