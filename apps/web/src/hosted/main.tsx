/**
 * The entry of the page at the app's address, which any browser opens to reach the computer it is paired with. Opened at
 * a pairing link, it pairs first; with no computer yet, it shows how to pair.
 */
import { pageRoot, pairFromAddress, showApp, showPairing } from "../app/page.tsx";
import { tunnelReach } from "./reach.ts";

const root = pageRoot();
const { reach, paired } = tunnelReach("https://octoii.com");
const failed = await pairFromAddress(reach);
if (failed === undefined && paired()) showApp(root, reach);
else showPairing(root, reach, failed);
