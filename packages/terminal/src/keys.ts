/*
 * Adapted from MIT-licensed code, MIT License, Copyright (c) 2026 T3 Tools Inc.; see THIRD_PARTY_NOTICES.
 * Our changes: a key's name is derived from its W3C code and looked up in the module's own GhosttyKey, so no table of
 * keys is kept by hand.
 */

/** The parts of a keyboard event a key's encoding reads. */
export type KeyEventLike = Pick<KeyboardEvent, "code" | "key" | "shiftKey" | "ctrlKey" | "altKey" | "metaKey" | "repeat" | "isComposing" | "getModifierState">;

/** A key event as the encoder takes it. */
export interface KeyInput {
	/** GhosttyKeyAction's name. */
	readonly action: "PRESS" | "REPEAT" | "RELEASE";
	/** GhosttyKey's name, as `keyName` derives it from the event's code. */
	readonly key: string;
	readonly mods: number;
	readonly consumedMods: number;
	readonly composing: boolean;
	readonly text: string;
	readonly unshiftedCodepoint: number;
}

/** GhosttyMods' bits (key/event.h), which the manifest does not list. */
export const MODS = {
	shift: 1 << 0,
	ctrl: 1 << 1,
	alt: 1 << 2,
	super: 1 << 3,
	capsLock: 1 << 4,
	numLock: 1 << 5,
} as const;

/** A W3C key code's name in GhosttyKey: KeyA is A, Digit0 DIGIT_0, ArrowUp ARROW_UP, NumpadArrowUp NUMPAD_UP, F12 F12. */
export function keyName(code: string): string {
	if (/^Key[A-Z]$/.test(code)) return code.slice(3);
	if (/^F\d+$/.test(code)) return code;
	return code
		.replace(/^NumpadArrow/, "Numpad")
		.replace(/([a-z])([A-Z0-9])/g, "$1_$2")
		.toUpperCase();
}

/** A keyboard event as the encoder takes it, pressed or released. */
export function keyInput(event: KeyEventLike, action: "press" | "release", layout?: KeyboardLayout): KeyInput {
	const text = [...event.key].length === 1 ? event.key : "";
	return {
		action: action === "release" ? "RELEASE" : event.repeat ? "REPEAT" : "PRESS",
		// Some mobile browsers leave the code out for keys such as Backspace; the key's name stands in.
		key: keyName(event.code === "" ? event.key : event.code),
		mods: modsOf(event),
		consumedMods: consumedMods(event),
		composing: event.isComposing,
		text,
		unshiftedCodepoint: unshiftedCodepoint(event, layout),
	};
}

/** The modifiers an event holds, as GhosttyMods. */
export function modsOf(event: Pick<KeyEventLike, "shiftKey" | "ctrlKey" | "altKey" | "metaKey" | "getModifierState">): number {
	return (
		(event.shiftKey ? MODS.shift : 0) |
		(event.ctrlKey ? MODS.ctrl : 0) |
		(event.altKey ? MODS.alt : 0) |
		(event.metaKey ? MODS.super : 0) |
		(event.getModifierState("CapsLock") ? MODS.capsLock : 0) |
		(event.getModifierState("NumLock") ? MODS.numLock : 0)
	);
}

/** Browsers do not say which modifiers made the text: Shift has, for a character typed with Shift alone. */
function consumedMods(event: KeyEventLike): number {
	if (!event.shiftKey || event.ctrlKey || event.altKey || event.metaKey) return 0;
	return [...event.key].length === 1 ? MODS.shift : 0;
}

/** The keyboard's layout, which says what a key types without Shift. */
export interface KeyboardLayout {
	get(code: string): string | undefined;
}

/** The character a key types without Shift, which the Kitty protocol reports; 0 when it cannot be known. */
export function unshiftedCodepoint(event: Pick<KeyEventLike, "code" | "key" | "shiftKey">, layout?: KeyboardLayout): number {
	if ([...event.key].length !== 1) return 0;
	const typed = layout?.get(event.code);
	if (typed !== undefined && [...typed].length === 1) return typed.codePointAt(0) ?? 0;
	if (!event.shiftKey) return event.key.codePointAt(0) ?? 0;
	const lower = event.key.toLowerCase();
	if (lower !== event.key && [...lower].length === 1) return lower.codePointAt(0) ?? 0;
	// Without the layout a shifted symbol's own key is unknown, and a guess would report the wrong key.
	return 0;
}

let layoutPromise: Promise<KeyboardLayout | undefined> | undefined;

/** The keyboard's layout where the browser gives it (Chromium's Keyboard API), else undefined. */
export function keyboardLayout(): Promise<KeyboardLayout | undefined> {
	layoutPromise ??= readLayout();
	return layoutPromise;
}

interface KeyboardApi {
	readonly keyboard?: { getLayoutMap(): Promise<KeyboardLayout> };
}

async function readLayout(): Promise<KeyboardLayout | undefined> {
	// SAFETY: the Keyboard API is Chromium's alone and missing from the DOM's types; it is checked before use.
	const api = globalThis.navigator as (Navigator & KeyboardApi) | undefined;
	return api?.keyboard?.getLayoutMap().catch(() => undefined);
}
