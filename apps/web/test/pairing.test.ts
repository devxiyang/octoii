/** A pairing link read from the page's address or from what the person pastes. */
import { describe, expect, it } from "bun:test";
import { pairingCredentialOf, remotePairingOf } from "../src/core/pairing.ts";

const CREDENTIAL = `0199f0c2-7a10-7000-8000-000000000001.${"ab".repeat(32)}`;
const KEY = "a".repeat(52);
const RELAY = "wss://x3k9.octoiitunnel.com";
const remote = (fields: string): string => `https://app.octoii.com/pair#${fields}`;

describe("a link for another device", () => {
	it("gives the computer and the credential", () => {
		expect(remotePairingOf(`  ${remote(`relay=${RELAY}&key=${KEY}&token=${CREDENTIAL}`)}\n`)).toEqual({
			machine: { relay: RELAY, key: KEY },
			credential: CREDENTIAL,
		});
	});

	it("reads no relay but a secure WebSocket's whole address, and no malformed key or credential", () => {
		expect(remotePairingOf(remote(`relay=ws://x3k9.octoiitunnel.com&key=${KEY}&token=${CREDENTIAL}`))).toBeUndefined();
		expect(remotePairingOf(remote(`relay=https://x3k9.octoiitunnel.com&key=${KEY}&token=${CREDENTIAL}`))).toBeUndefined();
		expect(remotePairingOf(remote(`relay=${RELAY}/home&key=${KEY}&token=${CREDENTIAL}`))).toBeUndefined();
		expect(remotePairingOf(remote(`relay=${RELAY}&key=nope&token=${CREDENTIAL}`))).toBeUndefined();
		expect(remotePairingOf(remote(`relay=${RELAY}&key=${KEY}&token=nope`))).toBeUndefined();
		expect(remotePairingOf(`https://app.octoii.com/#relay=${RELAY}&key=${KEY}&token=${CREDENTIAL}`)).toBeUndefined();
		expect(remotePairingOf(CREDENTIAL)).toBeUndefined();
	});
});

describe("a pairing link", () => {
	it("gives the credential in its fragment, on the pairing page alone, or a credential pasted alone", () => {
		expect(pairingCredentialOf(`http://127.0.0.1:7600/pair#token=${CREDENTIAL}`)).toBe(CREDENTIAL);
		expect(pairingCredentialOf(`  ${CREDENTIAL}\n`)).toBe(CREDENTIAL);
		expect(pairingCredentialOf(`http://127.0.0.1:7600/#token=${CREDENTIAL}`)).toBeUndefined();
		expect(pairingCredentialOf("http://127.0.0.1:7600/pair#token=not-a-credential")).toBeUndefined();
		expect(pairingCredentialOf("http://127.0.0.1:7600/pair")).toBeUndefined();
		expect(pairingCredentialOf("")).toBeUndefined();
	});
});
