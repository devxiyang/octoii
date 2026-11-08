/**
 * The entry of the page a node serves. Opened at a pairing link, it first pairs this browser with the node; opened at
 * the address a provider's sign-in came back to, it keeps that address for the providers' page, which finishes the
 * sign-in, and opens there. Then its client of the node connects over the WebSocket, and the app runs on it.
 */
import { pageRoot, pairFromAddress, showApp, showPairing } from "./app/page.tsx";
import { sameOrigin } from "./app/reach.ts";
import { HOME, routeAddress, withSettings } from "./core/route.ts";
import { SIGN_IN_PATH } from "./core/sign-in.ts";
import { keepSignInReturn } from "./components/state/sign-in.ts";

const root = pageRoot();
const failed = await pairFromAddress(sameOrigin);
if (window.location.pathname === SIGN_IN_PATH) {
	keepSignInReturn(window.location.href);
	// The issuer's code leaves the address, and the page opens where the sign-in is finished.
	window.history.replaceState(null, "", `/${routeAddress(withSettings(HOME, "providers"))}`);
}
if (failed === undefined) showApp(root, sameOrigin);
else showPairing(root, sameOrigin, failed);
