/**
 * The page's frame: the sidebar, the page's own column and the panel, and where each stands at the window's width —
 * the one place that knows the window's. The sidebar stands beside the page, its right edge dragged wider or narrower,
 * and ⌘B hides or shows it; where the window is narrow, as a phone's, it is a drawer over the page instead, swiped in
 * from the left edge, closed as the person goes elsewhere. The panel, ⌘⌥B, stands beside the page's column where the
 * window has room for both, its left edge dragged; over the column where it has not, the whole of it on a phone; or in
 * the column's place, as the person has it fill it. What shows, hides or fills either is the frame's own button, set
 * wherever a page wants it. What a page holds measures itself against its column, `@container/pane`, never the window.
 */
import { createContext, type ReactNode, useContext, useState } from "react";
import { Maximize2, Minimize2, PanelLeft, PanelRight } from "lucide-react";
import { NARROW, useMedia } from "../effects/media.ts";
import { useShortcut } from "../effects/shortcut.ts";
import { useDevice } from "../state/device.ts";
import { placePanel, usePanelPlace } from "../state/panel.ts";
import { IconButton, ToggleButton } from "../ui/button.tsx";
import { cn } from "../ui/cn.ts";
import { Drawer, DrawerPopup, DrawerSwipeArea, DrawerTitle } from "../ui/drawer.tsx";
import { useDragSize } from "../ui/resize.tsx";

declare module "react" {
	interface CSSProperties {
		/** The panel's width, as the person dragged it, which it keeps where it stands beside the page's column. */
		"--panel-width"?: string;
	}
}

/** How narrow and how wide the sidebar may be dragged. */
const SIDEBAR_BOUNDS = { min: 200, max: 480, grows: "right" } as const;

/** How narrow and how wide the panel may be dragged. */
const PANEL_BOUNDS = { min: 360, max: 1400, grows: "left" } as const;

/** How the sidebar stands: whether beside the page, and what shows and hides it. */
type SidebarStanding = { readonly beside: boolean; readonly show: () => void; readonly hide: () => void };

const SidebarContext = createContext<SidebarStanding>({ beside: true, show: () => undefined, hide: () => undefined });

/** What the frame is given: the place shown, what stands over the whole, the sidebar, and the page. */
export type FrameProps = {
	/** The place shown, by its address: the sidebar's drawer closes as it changes. */
	readonly at: string;
	/** What stands over the whole, as the line that tells of the connection does. */
	readonly banner: ReactNode;
	readonly sidebar: ReactNode;
	/** The page: its column, and its panel after it where it has one. */
	readonly children: ReactNode;
};

/** The frame. */
export function Frame(props: FrameProps): ReactNode {
	const narrow = useMedia(NARROW);
	const [hidden, setHidden] = useState(false);
	// The drawer is open at the place it was opened at: going elsewhere closes it.
	const [drawerAt, setDrawerAt] = useState<string | undefined>(undefined);
	const drawerOpen = narrow && drawerAt === props.at;
	const openDrawer = (open: boolean): void => setDrawerAt(open ? props.at : undefined);
	const beside = !narrow && !hidden;
	const sidebar: SidebarStanding = {
		beside,
		show: () => (narrow ? openDrawer(true) : setHidden(false)),
		hide: () => (narrow ? openDrawer(false) : setHidden(true)),
	};
	const panelPlace = usePanelPlace();
	useShortcut("mod+b", () => (beside || drawerOpen ? sidebar.hide() : sidebar.show()));
	useShortcut("mod+alt+b", () => placePanel(panelPlace === "hidden" ? "beside" : "hidden"));
	return (
		<SidebarContext value={sidebar}>
			{/* The frame keeps clear of the screen's own edges — a notch, a phone's status bar — its ground the sidebar's where the sidebar stands beside the page. */}
			<div
				className={cn(
					"flex h-dvh flex-col overflow-hidden pt-[env(safe-area-inset-top)] pr-[env(safe-area-inset-right)] pl-[env(safe-area-inset-left)]",
					beside ? "bg-sidebar" : "bg-background",
				)}
			>
				{props.banner}
				<div className="flex min-h-0 flex-1">
					{beside ? <SidebarColumn>{props.sidebar}</SidebarColumn> : null}
					{narrow ? (
						<Drawer open={drawerOpen} onOpenChange={openDrawer}>
							<DrawerSwipeArea />
							<DrawerPopup className="bg-sidebar text-foreground">
								<DrawerTitle className="sr-only">Sidebar</DrawerTitle>
								{props.sidebar}
							</DrawerPopup>
						</Drawer>
					) : null}
					{/* The panes meet the window's edges and each other, a hairline between them. */}
					<main className="relative flex min-w-0 flex-1">{props.children}</main>
				</div>
			</div>
		</SidebarContext>
	);
}

/** The sidebar beside the page, its right edge dragged to make it wider or narrower, the width kept for the device. */
function SidebarColumn(props: { readonly children: ReactNode }): ReactNode {
	const { device, set } = useDevice();
	const { size: width, edge } = useDragSize(device.sidebar_width, SIDEBAR_BOUNDS, (sidebar_width) => set({ sidebar_width }));
	return (
		<aside style={{ width }} className="relative flex h-full shrink-0 flex-col border-e border-border bg-sidebar text-foreground">
			{edge}
			{props.children}
		</aside>
	);
}

/**
 * The page's own column: its header, what it shows and what docks at its foot, one under another, never narrower than
 * a phone's page, the panel beside it giving way; gone while the panel after it fills its place.
 */
export function Pane(props: { readonly children: ReactNode }): ReactNode {
	return (
		<div className="@container/pane relative flex min-h-0 min-w-90 flex-1 flex-col overflow-hidden bg-background has-[+[data-fills]]:hidden max-lg:min-w-0">
			{props.children}
		</div>
	);
}

/**
 * The panel where it stands beside the page's column: beside it where the window has room for both, as wide as it was
 * dragged or what the column leaves it; over the column where the window has not, the whole of it on a phone.
 */
const BESIDE =
	"relative flex h-full w-(--panel-width) min-w-0 flex-col border-s border-border bg-background max-lg:absolute max-lg:inset-y-0 max-lg:right-0 max-lg:z-20 max-lg:w-[min(var(--panel-width),100%)] max-lg:shadow-floating max-md:w-full max-md:border-s-0";

/** The panel in the column's place. */
const FILLS = "relative flex h-full min-w-0 flex-1 flex-col bg-background";

/**
 * The panel's place after the page's column, and what it holds: nothing while it is hidden. Beside the column, its
 * left edge drags it wider or narrower, the width kept for the device.
 */
export function PanelFrame(props: { readonly children: ReactNode }): ReactNode {
	const place = usePanelPlace();
	const { device, set } = useDevice();
	const { size: width, edge } = useDragSize(device.panel_width, PANEL_BOUNDS, (panel_width) => set({ panel_width }));
	if (place === "hidden") return null;
	const fills = place === "full";
	return (
		<aside aria-label="Panel" data-fills={fills ? "" : undefined} style={{ "--panel-width": `${String(width)}px` }} className={fills ? FILLS : BESIDE}>
			{fills ? null : edge}
			{props.children}
		</aside>
	);
}

/** The button that shows the sidebar, ⌘B, where it does not stand beside the page; nothing where it does. */
export function ShowSidebar(props: { readonly className?: string }): ReactNode {
	const sidebar = useContext(SidebarContext);
	if (sidebar.beside) return null;
	return (
		<IconButton label="Show sidebar" shortcut="⌘B" onClick={sidebar.show} className={props.className}>
			<PanelLeft className="size-4" />
		</IconButton>
	);
}

/**
 * The button that shows the sidebar, set in the panel: there where the panel stands at the page's left edge — in the
 * column's place, or over the whole of it on a phone.
 */
export function ShowSidebarFromPanel(): ReactNode {
	return (
		<span className="hidden in-data-fills:contents max-md:contents">
			<ShowSidebar />
		</span>
	);
}

/** The button that hides the sidebar, ⌘B, or closes its drawer. */
export function HideSidebar(): ReactNode {
	const sidebar = useContext(SidebarContext);
	return (
		<IconButton label="Hide sidebar" shortcut="⌘B" onClick={sidebar.hide}>
			<PanelLeft className="size-4" />
		</IconButton>
	);
}

/** The button that shows the panel, ⌘⌥B, while it is hidden; nothing while it is shown. */
export function ShowPanel(props: { readonly className?: string }): ReactNode {
	if (usePanelPlace() !== "hidden") return null;
	return (
		<IconButton label="Show panel" shortcut="⌘⌥B" onClick={() => placePanel("beside")} className={props.className}>
			<PanelRight className="size-4" />
		</IconButton>
	);
}

/** The button that hides the panel, ⌘⌥B. */
export function HidePanel(): ReactNode {
	return (
		<IconButton label="Hide panel" shortcut="⌘⌥B" onClick={() => placePanel("hidden")}>
			<PanelRight className="size-4" />
		</IconButton>
	);
}

/** The button that has the panel fill the column's place, or gives the column its place back; nothing on a phone, where the panel takes the whole of it already. */
export function FillPanel(): ReactNode {
	const fills = usePanelPlace() === "full";
	return (
		<ToggleButton
			label={fills ? "Restore panel" : "Maximize panel"}
			pressed={fills}
			onPressedChange={(on) => placePanel(on ? "full" : "beside")}
			className="max-md:hidden"
		>
			{fills ? <Minimize2 className="size-4" /> : <Maximize2 className="size-4" />}
		</ToggleButton>
	);
}
