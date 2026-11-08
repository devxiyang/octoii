/**
 * Shortcuts the window answers while the component is drawn: one held with Cmd or Ctrl wherever the focus is, text
 * fields too; a key alone, such as `/` or a digit, only while no text field has the focus, which takes it as typing.
 * The latest of what they do is done, the window listening once.
 */
import { useEffect, useEffectEvent } from "react";
import { pressed, shortcutOf } from "../../core/shortcuts.ts";

/** Whether the person types in `element`: a text field, a box or what is edited in place. */
export function isTypedIn(element: EventTarget | null): boolean {
	return element instanceof HTMLElement && (element.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(element.tagName));
}

/** Answers each shortcut of `specs` with `act`, told which was pressed. */
export function useShortcuts(specs: readonly string[], act: (spec: string) => void): void {
	const answer = useEffectEvent(act);
	const asked = JSON.stringify(specs);
	useEffect(() => {
		// SAFETY: `asked` is the JSON of the specs the caller gave, so it parses back to them.
		const shortcuts = (JSON.parse(asked) as readonly string[]).map((spec) => ({ spec, shortcut: shortcutOf(spec) }));
		const down = (event: KeyboardEvent): void => {
			if (event.isComposing) return;
			const hit = shortcuts.find(({ shortcut }) => pressed(shortcut, event));
			if (hit === undefined || (!hit.shortcut.mod && isTypedIn(event.target))) return;
			event.preventDefault();
			answer(hit.spec);
		};
		document.addEventListener("keydown", down);
		return () => document.removeEventListener("keydown", down);
	}, [asked]);
}

/** Answers the shortcut `spec` with `act`. */
export function useShortcut(spec: string, act: () => void): void {
	useShortcuts([spec], act);
}
