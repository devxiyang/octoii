/**
 * The app: the page's frame — the sidebar, the page and its panel — holding a thread or a new one, at home; settings
 * over it where the route opens them; the command palette, ⌘K; and the notices of what failed, over everything. The
 * device's theme applies throughout; where the node knows this browser by no session, the pairing page.
 */
import { type ReactNode, useState } from "react";
import { useConnection } from "@octoii-works/octoii-client/react";
import { routeAddress, settingsOf, withOverlay } from "../core/route.ts";
import { useShortcut } from "../components/effects/shortcut.ts";
import { useAppearance } from "../components/effects/theme.ts";
import { Frame } from "../components/frame/frame.tsx";
import { Palette } from "../components/palette/palette.tsx";
import { Settings } from "../components/settings/settings.tsx";
import { Sidebar } from "../components/sidebar/sidebar.tsx";
import { useDevice } from "../components/state/device.ts";
import { go, useRoute } from "../components/state/navigation.ts";
import { TooltipProvider } from "../components/ui/tooltip.tsx";
import { NewThreadScreen } from "../screens/new-thread.tsx";
import { ThreadScreen } from "../screens/thread.tsx";
import { ConnectionLine, PairingPage, unpaired } from "./access.tsx";
import { NoticesProvider } from "../components/ui/notices.tsx";

/** The app. */
export function App(): ReactNode {
	const route = useRoute();
	const connection = useConnection();
	const { device } = useDevice();
	useAppearance(device);
	const [paletteOpen, setPaletteOpen] = useState(false);
	useShortcut("mod+k", () => setPaletteOpen(!paletteOpen));
	useShortcut("mod+n", () => go({ place: "new" }));
	if (unpaired(connection)) return <PairingPage />;
	return (
		<NoticesProvider>
			<TooltipProvider>
				<Frame
					at={routeAddress(route)}
					banner={<ConnectionLine connection={connection} />}
					sidebar={<Sidebar route={route} onOverlay={(over) => go(withOverlay(route, over))} />}
				>
					{route.place === "thread" ? (
						<ThreadScreen key={route.thread} thread={route.thread} device={device} />
					) : (
						<NewThreadScreen key={route.project ?? ""} project={route.project} device={device} />
					)}
				</Frame>
				<Settings
					section={settingsOf(route)}
					onSection={(section) => go(withOverlay(route, section === undefined ? undefined : { kind: "settings", section }))}
				/>
				<Palette route={route} isOpen={paletteOpen} onClose={() => setPaletteOpen(false)} onGo={go} />
			</TooltipProvider>
		</NoticesProvider>
	);
}
