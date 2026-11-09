/**
 * The app: the sidebar, which ⌘B hides — a drawer over the page where it is narrow; the chat — a thread beside the
 * right panel ⌘⌥B shows, or over it where the page is narrow, or a new one, at home; settings
 * over it where the route opens them; the command palette, ⌘K; and the notices of what failed, over everything. The
 * device's theme applies throughout; where the node knows this browser by no session, the pairing page.
 */
import { type ReactNode, useState } from "react";
import { useConnection } from "@octoii-works/octoii-client/react";
import { routeAddress, settingsOf, withOverlay } from "../core/route.ts";
import { useShortcut } from "../components/effects/shortcut.ts";
import { useAppearance } from "../components/effects/theme.ts";
import { Palette } from "../components/palette/palette.tsx";
import { Settings } from "../components/settings/settings.tsx";
import { Sidebar } from "../components/sidebar/sidebar.tsx";
import { useDevice } from "../components/state/device.ts";
import { go, useRoute } from "../components/state/navigation.ts";
import { placePanel, usePanelPlace } from "../components/state/panel.ts";
import { cn } from "../components/ui/cn.ts";
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
	const [sidebarHidden, setSidebarHidden] = useState(false);
	// Where the page is narrow, the sidebar is a drawer over it, open at the place it was opened at: going elsewhere closes it.
	const [drawerAt, setDrawerAt] = useState<string | undefined>(undefined);
	const drawerOpen = drawerAt === routeAddress(route);
	const [paletteOpen, setPaletteOpen] = useState(false);
	const panelPlace = usePanelPlace();
	useShortcut("mod+b", () => setSidebarHidden(!sidebarHidden));
	useShortcut("mod+alt+b", () => placePanel(panelPlace === "hidden" ? "beside" : "hidden"));
	useShortcut("mod+k", () => setPaletteOpen(!paletteOpen));
	useShortcut("mod+n", () => go({ place: "new" }));
	if (unpaired(connection)) return <PairingPage />;
	const showSidebar = (): void => {
		setSidebarHidden(false);
		setDrawerAt(routeAddress(route));
	};
	return (
		<NoticesProvider>
			<TooltipProvider>
				<div className="flex h-dvh flex-col overflow-hidden bg-sidebar">
					<ConnectionLine connection={connection} />
					<div className="flex min-h-0 flex-1">
						{sidebarHidden && !drawerOpen ? null : (
							<Sidebar
								route={route}
								onHide={() => {
									setSidebarHidden(true);
									setDrawerAt(undefined);
								}}
								onOverlay={(over) => go(withOverlay(route, over))}
								className={drawerOpen ? "max-md:fixed max-md:inset-y-0 max-md:left-0 max-md:z-40 max-md:max-w-[85vw] max-md:shadow-dialog" : "max-md:hidden"}
							/>
						)}
						{drawerOpen ? (
							<button
								type="button"
								aria-label="Close the sidebar"
								onClick={() => setDrawerAt(undefined)}
								className="fixed inset-0 z-30 bg-black/20 md:hidden"
							/>
						) : null}
						{/* The page's panels stand on the canvas as cards, an inset of it around them. */}
						<main className={cn("relative flex min-w-0 flex-1 gap-1.5 py-1.5 pe-1.5 max-md:ps-1.5", sidebarHidden && "ps-1.5")}>
							{route.place === "thread" ? (
								<ThreadScreen key={route.thread} thread={route.thread} device={device} sidebarHidden={sidebarHidden} onShowSidebar={showSidebar} />
							) : (
								<NewThreadScreen key={route.project ?? ""} project={route.project} device={device} sidebarHidden={sidebarHidden} onShowSidebar={showSidebar} />
							)}
						</main>
					</div>
					<Settings
						section={settingsOf(route)}
						onSection={(section) => go(withOverlay(route, section === undefined ? undefined : { kind: "settings", section }))}
					/>
					<Palette route={route} isOpen={paletteOpen} onClose={() => setPaletteOpen(false)} onGo={go} />
				</div>
			</TooltipProvider>
		</NoticesProvider>
	);
}
