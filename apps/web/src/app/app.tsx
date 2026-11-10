/**
 * The app: the page's frame — the sidebar, the page and its panel — holding a thread or a new one, at home, or, where
 * the route opens them, settings, their sections in the sidebar's place; the command palette, ⌘K; and the notices of
 * what failed, over everything. The device's theme applies throughout; where the node knows this browser by no session,
 * the pairing page.
 */
import { type ReactNode, useState } from "react";
import { useConnection } from "@octoii-works/octoii-client/react";
import { routeAddress, type SettingsSection, settingsOf, withOverlay } from "../core/route.ts";
import { useShortcut } from "../components/effects/shortcut.ts";
import { useAppearance } from "../components/effects/theme.ts";
import { Frame } from "../components/frame/frame.tsx";
import { Palette } from "../components/palette/palette.tsx";
import { SettingsNav, SettingsPage } from "../components/settings/settings.tsx";
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
	const settings = settingsOf(route);
	const onSection = (section: SettingsSection | undefined, at?: string): void =>
		go(withOverlay(route, section === undefined ? undefined : { kind: "settings", section, ...(at === undefined ? {} : { at }) }));
	return (
		<NoticesProvider>
			<TooltipProvider>
				<Frame
					at={routeAddress(route)}
					banner={<ConnectionLine connection={connection} />}
					sidebar={
						settings === undefined ? (
							<Sidebar route={route} onOverlay={(over) => go(withOverlay(route, over))} />
						) : (
							<SettingsNav section={settings} at={route.over?.at} onSection={onSection} />
						)
					}
				>
					{settings !== undefined ? (
						<SettingsPage section={settings} at={route.over?.at} onSection={onSection} />
					) : route.place === "thread" ? (
						<ThreadScreen key={route.thread} thread={route.thread} device={device} />
					) : (
						<NewThreadScreen key={route.project ?? ""} project={route.project} device={device} />
					)}
				</Frame>
				<Palette route={route} isOpen={paletteOpen} onClose={() => setPaletteOpen(false)} onGo={go} />
			</TooltipProvider>
		</NoticesProvider>
	);
}
