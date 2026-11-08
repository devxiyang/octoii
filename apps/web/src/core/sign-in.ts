/**
 * A provider's sign-in in a browser, as the page sees it: the node's own address the issuer sends the browser back to,
 * from which the page finishes the sign-in — or, from a browser of another device, which cannot reach it, the address
 * the person copies from its address bar and pastes.
 */

/** The path the node's sign-ins send the browser back to. */
export const SIGN_IN_PATH = "/auth/callback";

/** Whether `text` is an address a sign-in sent a browser back to: the node's path, with what the issuer gave it. */
export function isSignInReturn(text: string): boolean {
	const given = text.trim();
	if (!URL.canParse(given)) return false;
	const address = new URL(given);
	return address.pathname === SIGN_IN_PATH && address.search.length > 1;
}
