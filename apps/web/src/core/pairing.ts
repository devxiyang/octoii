/**
 * A pairing link, as the node makes one — its pairing page's address, the link's credential in the address's fragment,
 * which a browser never sends to any server — read from the page's own address or from what the person pastes: a
 * whole link, or its credential alone.
 */

/** The path of the node's pairing page. */
export const PAIRING_PATH = "/pair";

/** A link's credential: its id and its secret. */
const CREDENTIAL = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[0-9a-f]{64}$/i;

/** A machine's key, as text: 32 bytes in base32, lowercase and unpadded. */
const MACHINE_KEY = /^[a-z2-7]{52}$/;

/** A computer the app reaches through a tunnel: the relay it is on, and the key that proves it is that computer. */
export type RemoteMachine = { readonly relay: string; readonly key: string };

/** The relay a link names, as an origin; none where it is not a secure WebSocket's whole address. */
function relayOf(text: string): string | undefined {
	if (!URL.canParse(text)) return undefined;
	const address = new URL(text);
	return address.protocol === "wss:" && address.pathname === "/" && address.search === "" && address.hash === "" ? address.origin : undefined;
}

/** What a link for another device gives — the computer and the credential that pairs with it; none where `text` is no such link. */
export function remotePairingOf(text: string): { readonly machine: RemoteMachine; readonly credential: string } | undefined {
	const given = text.trim();
	if (!URL.canParse(given)) return undefined;
	const address = new URL(given);
	if (address.pathname !== PAIRING_PATH) return undefined;
	const fields = new URLSearchParams(address.hash.replace(/^#/, ""));
	const relay = relayOf(fields.get("relay")?.trim() ?? "");
	const key = fields.get("key")?.trim() ?? "";
	const credential = fields.get("token")?.trim() ?? "";
	if (relay === undefined || !MACHINE_KEY.test(key) || !CREDENTIAL.test(credential)) return undefined;
	return { machine: { relay, key }, credential };
}

/** The credential a pairing link or a credential pasted alone gives; none where `text` is neither. */
export function pairingCredentialOf(text: string): string | undefined {
	const given = text.trim();
	if (CREDENTIAL.test(given)) return given;
	if (!URL.canParse(given)) return undefined;
	const address = new URL(given);
	if (address.pathname !== PAIRING_PATH) return undefined;
	const token = new URLSearchParams(address.hash.replace(/^#/, "")).get("token")?.trim() ?? "";
	return CREDENTIAL.test(token) ? token : undefined;
}
