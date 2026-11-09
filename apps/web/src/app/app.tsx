/**
 * The app: the sidebar, which ⌘B hides or shows — a drawer over the page where it is narrow, swiped in from its left
 * edge; the chat — a thread beside the right panel ⌘⌥B shows, or over it where the page is narrow, or a new one, at
 * home; settings over it where the route opens them; the command palette, ⌘K; and the notices of what failed, over
 * everything. The device's theme applies throughout; where the node knows this browser by no session, the pairing page.
 */
import { type ReactNode, useState } from "react";
import { useConnection } from "@octoii-works/octoii-client/react";
import { type Overlay, routeAddress, settingsOf, withOverlay } from "../core/route.ts";
import { NARROW, useMedia } from "../components/effects/media.ts";
import { useShortcut } from "../components/effects/shortcut.ts";
import { useAppearance } from "../components/effects/theme.ts";
import { Palette } from "../components/palette/palette.tsx";
import { Settings } from "../components/settings/settings.tsx";
import { Sidebar, SidebarDrawer } from "../components/sidebar/sidebar.tsx";
import { useDevice } from "../components/state/device.ts";
import { go, useRoute } from "../components/state/navigation.ts";
import { placePanel, usePanelPlace } from "../components/state/panel.ts";
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
	const narrow = useMedia(NARROW);
	const [sidebarHidden, setSidebarHidden] = useState(false);
	// Where the page is narrow, the sidebar is a drawer over it, open at the place it was opened at: going elsewhere closes it.
	const [drawerAt, setDrawerAt] = useState<string | undefined>(undefined);
	const drawerOpen = narrow && drawerAt === routeAddress(route);
	const [paletteOpen, setPaletteOpen] = useState(false);
	const panelPlace = usePanelPlace();
	const openDrawer = (open: boolean): void => setDrawerAt(open ? routeAddress(route) : undefined);
	useShortcut("mod+b", () => (narrow ? openDrawer(!drawerOpen) : setSidebarHidden(!sidebarHidden)));
	useShortcut("mod+alt+b", () => placePanel(panelPlace === "hidden" ? "beside" : "hidden"));
	useShortcut("mod+k", () => setPaletteOpen(!paletteOpen));
	useShortcut("mod+n", () => go({ place: "new" }));
	if (unpaired(connection)) return <PairingPage />;
	const showSidebar = (): void => (narrow ? openDrawer(true) : setSidebarHidden(false));
	const overlay = (over: Overlay): void => go(withOverlay(route, over));
	// The sidebar stands beside the chat where the page is wide enough and the person has not hidden it.
	const sidebarBeside = !narrow && !sidebarHidden;
	return (
		<NoticesProvider>
			<TooltipProvider>
				{/* The page keeps clear of the screen's own edges — a notch, a phone's status bar — its ground the chat's where the sidebar is not beside it. */}
				<div className="flex h-dvh flex-col overflow-hidden bg-sidebar pt-[env(safe-area-inset-top)] pr-[env(safe-area-inset-right)] pl-[env(safe-area-inset-left)] max-md:bg-background">
					<ConnectionLine connection={connection} />
					<div className="flex min-h-0 flex-1">
						{sidebarBeside ? <Sidebar route={route} onHide={() => setSidebarHidden(true)} onOverlay={overlay} /> : null}
						{narrow ? <SidebarDrawer open={drawerOpen} onOpenChange={openDrawer} route={route} onHide={() => openDrawer(false)} onOverlay={overlay} /> : null}
						{/* The page's panes meet the window's edges and each other, a hairline between them. */}
						<main className="relative flex min-w-0 flex-1">
							{route.place === "thread" ? (
								<ThreadScreen key={route.thread} thread={route.thread} device={device} sidebarHidden={!sidebarBeside} onShowSidebar={showSidebar} />
							) : (
								<NewThreadScreen key={route.project ?? ""} project={route.project} device={device} sidebarHidden={!sidebarBeside} onShowSidebar={showSidebar} />
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
