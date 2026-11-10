/**
 * The page's appearance as the device sets it: dark where it says so, or where it follows the system and the system is
 * dark; its palette, as the variables every colour is made from; and how wide the chat grows, named on the root for
 * the stylesheet, which knows each width.
 */
import { useEffect, useSyncExternalStore } from "react";
import { type Device, isDark, paletteOf, paletteVariables } from "../../core/device.ts";

export function useAppearance(device: Device): void {
	const { theme, palette, chat_width: chatWidth } = device;
	useEffect(() => {
		const root = document.documentElement;
		const system = window.matchMedia("(prefers-color-scheme: dark)");
		const apply = (): void => {
			root.classList.toggle("dark", isDark(theme, system.matches));
		};
		apply();
		for (const [name, value] of Object.entries(paletteVariables(paletteOf(palette)))) root.style.setProperty(name, value);
		root.dataset["chatWidth"] = chatWidth;
		system.addEventListener("change", apply);
		return () => system.removeEventListener("change", apply);
	}, [theme, palette, chatWidth]);
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
