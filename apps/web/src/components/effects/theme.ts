/**
 * The page's appearance as the device sets it: dark where it says so, or where it follows the system and the system is
 * dark; its palette; how far secondary text leans toward the text; how solid the glass is; and how wide the chat grows,
 * named on the root for the stylesheet, which knows each width.
 */
import { useEffect, useSyncExternalStore } from "react";
import { type Device, isDark } from "../../core/device.ts";

export function useAppearance(device: Device): void {
	const { theme, palette, contrast, glass_opacity: glassOpacity, chat_width: chatWidth } = device;
	useEffect(() => {
		const root = document.documentElement;
		const system = window.matchMedia("(prefers-color-scheme: dark)");
		const apply = (): void => {
			root.classList.toggle("dark", isDark(theme, system.matches));
		};
		apply();
		if (palette === "default") delete root.dataset["palette"];
		else root.dataset["palette"] = palette;
		root.style.setProperty("--contrast-boost", `${String(contrast - 100)}%`);
		root.style.setProperty("--glass-opacity", `${String(glassOpacity)}%`);
		root.dataset["chatWidth"] = chatWidth;
		system.addEventListener("change", apply);
		return () => system.removeEventListener("change", apply);
	}, [theme, palette, contrast, glassOpacity, chatWidth]);
}

/** The code views' themes — a file's and a diff's — on a light page and a dark one. */
export const CODE_THEMES = { light: "pierre-light", dark: "pierre-dark" } as const;

/** Whether the page shows dark, read again as its scheme changes: the class the appearance puts on the root. */
export function useDarkPage(): boolean {
	return useSyncExternalStore(followScheme, () => document.documentElement.classList.contains("dark"));
}

function followScheme(changed: () => void): () => void {
	const observer = new MutationObserver(changed);
	observer.observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
	return () => observer.disconnect();
}
